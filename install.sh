#!/usr/bin/env bash
set -euo pipefail

# ANSI color codes; auto-disabled when stdout isn't a TTY (e.g. piped to a logfile, run in CI).
BOLD=$'\e[1m'; BLUE=$'\e[34m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
[[ -t 1 ]] || { BOLD=; BLUE=; GREEN=; RED=; DIM=; RESET=; }
info() { printf '%s●%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n'       "$GREEN" "$RESET" "$*"; }
err()  { printf '%s✗%s %s\n'       "$RED"   "$RESET" "$*" >&2; }
# `trap - ERR` disarms the ERR trap below so the explicit `exit 1` doesn't double-report.
die()  { err "$*"; trap - ERR; exit 1; }
trap 'err "install.sh failed at line $LINENO"' ERR

# Usage: install.sh [claude|copilot|all]   (default: all)
# Pin a version with CLAUDE_CODE_VERSION=x.y.z or COPILOT_CLI_VERSION=x.y.z (for the agent named on the command
# line). The launcher calls this by itself when the image of an agent is missing or outdated.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHICH="${1:-all}"
case "$WHICH" in
  claude|copilot) AGENTS=("$WHICH") ;;
  all)            AGENTS=(claude copilot) ;;
  *)              die "Unknown agent '$WHICH'. Use claude, copilot or all." ;;
esac

command -v docker >/dev/null || die "Docker is required but not on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not running."

# Builds agent-pod:<agent>. The agent-specific values are the same ones as in the launcher's table.
install_agent() {
  local agent="$1" name pkg channel version_var requested channel_label version resolved
  case "$agent" in
    claude)  name="Claude Code"; pkg=@anthropic-ai/claude-code; channel=stable; version_var=CLAUDE_CODE_VERSION ;;
    copilot) name="Copilot CLI"; pkg=@github/copilot;           channel=latest; version_var=COPILOT_CLI_VERSION ;;
  esac
  local image="agent-pod:$agent"

  # What the user asked for (the default dist-tag, "latest", or a number); stored as an image label so the
  # launcher knows whether it may auto-update this image. Each agent reads only its own variable, so a pinned
  # CLAUDE_CODE_VERSION does not leak into Copilot.
  requested="${!version_var:-$channel}"
  channel_label="$requested"
  version="$requested"

  # Resolve a dist-tag to a concrete version from the npm registry, so the version number becomes the
  # cache key: the npm layer is reused while the tag is unchanged and rebuilt when it moves. If the
  # lookup fails, the tag stays as is and gets the CACHEBUST fallback below.
  if [[ ! "$version" =~ ^[0-9] ]]; then
    resolved="$(curl -fsSL --max-time 10 "https://registry.npmjs.org/-/package/$pkg/dist-tags" 2>/dev/null \
      | sed -n "s/.*\"$version\"[[:space:]]*:[[:space:]]*\"\([0-9][^\"]*\)\".*/\1/p" || true)"
    if [ -n "$resolved" ]; then
      version="$resolved"
    else
      printf '%s  Could not resolve "%s" from npm; building without cache for this step.%s\n' "$DIM" "$version" "$RESET"
    fi
  fi

  # For pinned versions, the version literal is itself the cache key, so the layer rebuilds whenever the pin
  # changes. For an unresolved dist-tag the literal never changes while the version it points to does, so
  # we pass CACHEBUST=$(date +%s) to force a refetch.
  local build_args=(--build-arg "AGENT=$agent" --build-arg "AGENT_PKG=$pkg"
                    --build-arg "AGENT_VERSION=$version" --build-arg "AGENT_CHANNEL=$channel_label")
  if [[ ! "$version" =~ ^[0-9] ]]; then
    build_args+=(--build-arg "CACHEBUST=$(date +%s)")
  fi

  info "Preflight ($name)"
  printf '  %sdocker:        %s %s\n' "$DIM" "$RESET" "$(docker --version)"
  printf '  %srepo:          %s %s\n' "$DIM" "$RESET" "$REPO_DIR"
  printf '  %simage:         %s %s\n' "$DIM" "$RESET" "$image"
  printf '  %s%-13s %s %s\n' "$DIM" "$agent:" "$RESET" "$version"
  echo

  # Build under a temporary tag and only move the real tag after the new image proves it works, so a
  # failed build or a broken binary never replaces a working image (this matters because the launcher
  # auto-updates on start). The tag is unique per invocation ($$ = PID) so concurrent installers can
  # never verify one image and promote another; the EXIT trap removes it on any exit (failed build,
  # failed verification, success), leaving only the promoted tag.
  local tmp_image="agent-pod:new-$agent-$$"
  # Expanded now: the variable is local and gone when the trap runs. Each agent replaces the previous trap, which
  # has removed its image by then.
  # shellcheck disable=SC2064
  trap "docker rmi '$tmp_image' >/dev/null 2>&1 || true" EXIT

  info "Building image '$image'"
  # Stream the build output dimmed and indented. `--progress=plain` disables BuildKit's animated
  # TUI (which can't be re-styled externally); the sed strips Docker's own ANSI codes so they don't
  # cancel our dim formatting; the while-read prefixes each line with dim + 2-space indent.
  docker build \
    --progress=plain \
    "${build_args[@]}" \
    -t "$tmp_image" "$REPO_DIR" 2>&1 \
    | sed $'s/\e\\[[0-9;]*m//g' \
    | while IFS= read -r line; do printf '%s  %s%s\n' "$DIM" "$line" "$RESET"; done
  ok "Image built"
  echo

  info "Verifying"
  # `<agent> --version` prints the resolved npm version. Wrapped in if/else so a failure is reported
  # with a clear message instead of tripping the ERR trap; the previous image stays untouched.
  if resolved="$(docker run --rm "$tmp_image" "$agent" --version 2>&1)"; then
    printf '  %s%-13s %s %s\n' "$DIM" "$agent:" "$RESET" "$resolved"
  else
    die "New image failed '$agent --version' ($resolved); keeping the previous '$image' image."
  fi
  docker tag "$tmp_image" "$image"
  docker rmi "$tmp_image" >/dev/null 2>&1 || true
  ok "Image '$image' installed"
  echo
}

for _agent in "${AGENTS[@]}"; do install_agent "$_agent"; done

info "Next steps"
printf '  cd into your work-in-progress project folder first, then:\n'
printf '    Open shell in pod:          %s%s/agent-pod claude%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Or run an agent directly:   %s%s/agent-pod claude claude --dangerously-skip-permissions%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '                                %s%s/agent-pod copilot copilot --yolo%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Shell with Docker:          %sDOCKER=1 %s/agent-pod claude%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Docker + image cache:       %sDOCKER=1 DOCKER_CACHE=1 %s/agent-pod claude%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Optional shell aliases:     %salias claude-pod=%s/claude-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '                                %salias copilot-pod=%s/copilot-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
