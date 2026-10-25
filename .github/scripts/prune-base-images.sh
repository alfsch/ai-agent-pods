#!/usr/bin/env bash
# Deletes old versions of the published base image (ghcr.io/alfsch/agent-pod-base). Run by prune-base-images.yaml.
#
# Every Dockerfile.base change publishes a new tag (a hash), and each tag is more than one package version: the index, a
# manifest and an attestation per architecture (those children are untagged), and a signature (tag sha256-<hex>.sig). So
# "delete the untagged versions" would break the images that are still in use. This keeps whole images:
#   - the KEEP_TAGS newest hash tags (by the time the tag was last pushed) and every tag pushed within KEEP_DAYS days,
#     with their children and signatures;
#   - tags that are not a hash and not a signature (someone pushed them for a reason);
#   - untagged versions younger than GRACE_HOURS (the children of a publish that is still running).
# Everything else goes: older hash tags, the signatures of removed images, and untagged versions no kept image uses.
# A user whose checkout is older than that only loses a pull: install.sh then builds the base itself.
#
# Usage: prune-base-images.sh                       list the package and delete (DRY_RUN=1: only list)
#        prune-base-images.sh decide VERSIONS CHILDREN   the versions to delete as id<TAB>digest<TAB>reason (for the tests)
#        prune-base-images.sh kept-indexes VERSIONS      the index digests that are kept
# VERSIONS is the package version list of the API, CHILDREN is {"<index digest>": ["<child digest>", ...]}.
set -Eeuo pipefail

OWNER="${OWNER:-alfsch}"
PACKAGE="${PACKAGE:-agent-pod-base}"
IMAGE="${IMAGE:-ghcr.io/$OWNER/$PACKAGE}"
KEEP_TAGS="${KEEP_TAGS:-5}"
KEEP_DAYS="${KEEP_DAYS:-30}"
GRACE_HOURS="${GRACE_HOURS:-24}"
DRY_RUN="${DRY_RUN:-1}"
NOW="${NOW:-$(date -u +%s)}"

die() { echo "prune-base-images: $*" >&2; exit 1; }
for v in KEEP_TAGS KEEP_DAYS GRACE_HOURS NOW; do [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a number, not '${!v}'"; done
[ "$KEEP_TAGS" -ge 1 ] || die "KEEP_TAGS must be at least 1: the newest image is always kept"

# jq definitions shared by the two programs. Timestamps of the API look like 2026-10-21T22:11:53Z.
DEFS='
def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def tags: (.metadata.container.tags // []);
def hashtag: test("^[0-9a-f]{16}$");
def sigtag: test("^sha256-[0-9a-f]{64}\\.(sig|att|sbom)$");
def tagged: [ .[] | select(tags | any(hashtag)) ] | sort_by(.updated_at) | reverse;
def kept: tagged as $t
  | if ($t | length) == 0 then error("no tagged base image versions: refusing to delete anything") else . end
  | [ $t | to_entries[]
      | select(.key < $keepTags or ($now - (.value.updated_at | ts)) < ($keepDays * 86400))
      | .value ];
'

jqargs=(--argjson now "$NOW" --argjson keepTags "$KEEP_TAGS" --argjson keepDays "$KEEP_DAYS" --argjson graceHours "$GRACE_HOURS")

kept_indexes() { jq -r "${jqargs[@]}" "$DEFS"' kept[] | .name' "$1"; }

decide() {
  jq -r "${jqargs[@]}" --argjson children "$(cat "$2")" "$DEFS"'
    kept as $kept
    | ([ $kept[] | .name as $d | ($children[$d] // error("no manifest list for " + $d)) as $c | $d, $c[] ]) as $keep
    | ([ $kept[] | .name | ltrimstr("sha256:") | "sha256-" + . + "." ]) as $sigprefixes
    | .[]
    | . as $v | tags as $t | .name as $d
    | if ($keep | index($d)) != null then empty
      elif ($t | any(hashtag)) then [$v.id, $d, "old tag " + ($t | map(select(hashtag)) | join(","))]
      elif ($t | any(sigtag)) then
        if ($t | any(. as $tag | $sigprefixes | any(. as $p | $tag | startswith($p)))) then empty
        else [$v.id, $d, "signature of a removed image"] end
      elif ($t | length) > 0 then empty
      elif ($now - ($v.updated_at | ts)) >= ($graceHours * 3600) then [$v.id, $d, "untagged, not part of a kept image"]
      else empty end
    | @tsv' "$1"
}

main() {
  command -v jq >/dev/null || die "jq is required"
  command -v gh >/dev/null || die "gh is required"
  local versions children d raw n=0 failed=0 id digest reason
  versions="$(mktemp)"; children="$(mktemp)"
  trap 'rm -f "$versions" "$children"' EXIT
  gh api --paginate "/users/$OWNER/packages/container/$PACKAGE/versions?per_page=100" | jq -s 'add // []' > "$versions"
  echo "$(jq length "$versions") versions in $IMAGE (keeping the $KEEP_TAGS newest tags and those of the last $KEEP_DAYS days)"

  # Which untagged versions belong to a kept image is read from the image: the index lists its children.
  echo '{}' > "$children"
  for d in $(kept_indexes "$versions"); do
    raw="$(docker buildx imagetools inspect --raw "$IMAGE@$d")" || die "could not read the manifest list of $d: nothing is deleted"
    jq -c --arg d "$d" --argjson m "$raw" '. + {($d): [($m.manifests // [])[].digest]}' "$children" > "$children.new" && mv "$children.new" "$children"
    echo "keeping $d ($(jq -r --arg d "$d" '.[$d] | length' "$children") children)"
  done

  while IFS=$'\t' read -r id digest reason; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if [ "$DRY_RUN" = 1 ]; then echo "would delete $id $digest: $reason"; continue; fi
    echo "deleting $id $digest: $reason"
    gh api -X DELETE "/users/$OWNER/packages/container/$PACKAGE/versions/$id" >/dev/null || { echo "  failed" >&2; failed=$((failed + 1)); }
  done < <(decide "$versions" "$children")
  echo "$n versions $([ "$DRY_RUN" = 1 ] && echo 'would be deleted (dry run)' || echo 'selected'), $failed failed"
  [ "$failed" = 0 ]
}

case "${1:-}" in
  decide) decide "$2" "$3" ;;
  kept-indexes) kept_indexes "$2" ;;
  "") main ;;
  *) die "unknown command '$1'" ;;
esac
