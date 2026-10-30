#!/usr/bin/env bash
# Prints the tag of the newest published base image (ghcr.io/alfsch/agent-pod-base, or $AGENT_POD_BASE_REPO) that exists
# in the registry: the one of the checked-out tree if it is published, else the one of the newest commit of $REF (default
# origin/main) that changed what the base is built from and whose tag is published. On a push to main the publish
# workflow runs next to the tests, so the tag of that commit may not be there yet; an earlier one always is. Used by
# integration-tests.yaml. Run from the repository root, with enough history fetched. Exit 1 when none is found.
set -euo pipefail
REPO="${AGENT_POD_BASE_REPO:-ghcr.io/alfsch/agent-pod-base}"
REF="${REF:-origin/main}"
FILES=(install.sh Dockerfile.base pod-environment.md)

published() { docker manifest inspect "$REPO:$1" >/dev/null 2>&1; }

tag="$(./install.sh --base-hash)"
if published "$tag"; then echo "$tag"; exit 0; fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# the base's inputs, from the Dockerfile and the environment file: a commit that changed neither has the same tag
for c in $(git log --format=%H -n 30 "$REF" -- Dockerfile.base pod-environment.md); do
  rm -rf "${tmp:?}/c"; mkdir "$tmp/c"
  for f in "${FILES[@]}"; do git show "$c:$f" > "$tmp/c/$f" 2>/dev/null || continue 2; done
  chmod +x "$tmp/c/install.sh"
  tag="$("$tmp/c/install.sh" --base-hash 2>/dev/null)" || continue   # the installer of that commit knows its own hash
  if published "$tag"; then echo "$tag"; exit 0; fi
done
echo "no published base image found for the checked-out tree or the last commits of $REF" >&2
exit 1
