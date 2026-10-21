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
trap 'err "uninstall.sh failed at line $LINENO"' ERR

# The state dirs keep the names of the single-agent tools, so existing logins carry over.
# The config files (login binding, trust state) are in the config dir.
STATE_DIRS=("$HOME/.claude-pod" "$HOME/.copilot-pod" "${XDG_CONFIG_HOME:-$HOME/.config}/agent-pod")
IMAGES=(agent-pod:claude agent-pod:copilot)
BASE_REPO="${AGENT_POD_BASE_REPO:-ghcr.io/alfsch/agent-pod-base}"   # the shared base image install.sh pulls or builds

info "Will remove"
printf '  %simages:%s %s %s(and every tag of %s)%s\n' "$DIM" "$RESET" "${IMAGES[*]}" "$DIM" "$BASE_REPO" "$RESET"
printf '  %sdirs:  %s %s %s(auth + session history)%s\n' "$DIM" "$RESET" "${STATE_DIRS[*]}" "$DIM" "$RESET"
printf '  %svolumes:%s agent-pod-docker-* %s(DOCKER_CACHE image caches, if any)%s\n' "$DIM" "$RESET" "$DIM" "$RESET"
printf '  %ssidecars:%s agent-pod-dind:* %s(DOCKER=1 sidecar images for a host uid other than 1000, if any)%s\n' "$DIM" "$RESET" "$DIM" "$RESET"
echo

info "Will NOT remove"
printf '  %snode:24-slim base image (docker rmi node:24-slim to clear)%s\n' "$DIM" "$RESET"
printf '  %sDocker build cache (docker builder prune to clear)%s\n' "$DIM" "$RESET"
printf '  %sthis repo folder (delete it yourself)%s\n' "$DIM" "$RESET"
echo

# `|| reply=""` so that EOF / non-interactive stdin (where read returns non-zero) is treated as
# a declined prompt under `set -e`, rather than tripping the ERR trap with a confusing line error.
read -r -p "Proceed? [y/N] " reply || reply=""
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

info "Removing images"
# Probe with `image ls -q`, not `image inspect`: some Docker Desktop builds have a broken
# `image inspect <name>` that false-negatives on a present image, which would make us wrongly
# report "not present" and leave the image behind. `ls -q` resolves the name like `rmi` does.
for IMAGE in "${IMAGES[@]}"; do
  if [ -n "$(docker image ls -q "$IMAGE" 2>/dev/null)" ]; then
    # Dim + indent the rmi output the same way install.sh dims `docker build` output.
    docker rmi -f "$IMAGE" 2>&1 \
      | sed $'s/\e\\[[0-9;]*m//g' \
      | while IFS= read -r line; do printf '%s  %s%s\n' "$DIM" "$line" "$RESET"; done
    ok "Image '$IMAGE' removed"
  else
    ok "Image '$IMAGE' was not present"
  fi
done
echo

# The shared base image: every tag of it (one per version of Dockerfile.base that was pulled or built here).
_bases="$(docker image ls "$BASE_REPO" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':<none>$' || true)"
if [ -n "$_bases" ]; then
  # shellcheck disable=SC2086
  if docker rmi -f $_bases >/dev/null 2>&1; then
    ok "Removed base images"
  else
    err "Could not remove the base images ($BASE_REPO:*)."
  fi
else
  ok "No base image present"
fi
echo

# Derived sidecar images the launcher builds for a host uid other than 1000.
# By repository:tag, not by image ID: removing an ID would also drop other tags the image may have.
_derived="$(docker image ls agent-pod-dind --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':<none>$' || true)"
if [ -n "$_derived" ]; then
  # shellcheck disable=SC2086
  if docker rmi -f $_derived >/dev/null 2>&1; then
    ok "Removed sidecar images"
  else
    err "Could not remove the sidecar images (agent-pod-dind:*); a session may still use them."
  fi
fi
echo

info "Removing Docker cache volumes"
if command -v docker >/dev/null; then
  # A failed listing must not look like "no caches", or the stamps would be deleted below.
  _all="$(docker volume ls -q --filter name=agent-pod-docker- 2>/dev/null)" \
    || die "Could not list Docker volumes (is the Docker daemon running?). The host directory was not removed."
  # --filter name= matches substrings, so keep only the names the launcher generates.
  _vols="$(grep -E '^agent-pod-docker-[0-9a-f]{16}$' <<<"$_all" || true)"
  if [ -n "$_vols" ]; then
    # shellcheck disable=SC2086
    docker volume rm $_vols >/dev/null 2>&1 || die "Some cache volumes are in use; close running sessions and retry. The host directory was not removed."
    ok "Removed Docker cache volumes"
  else
    ok "No Docker cache volumes present"
  fi
else
  ok "Docker is not installed; no cache volumes to remove"
fi
# The last-use stamps go regardless of volumes: they can outlive volumes that were deleted by hand.
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/agent-pod"
echo

info "Removing host directories"
for STATE_DIR in "${STATE_DIRS[@]}"; do
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    ok "Removed $STATE_DIR"
  else
    ok "$STATE_DIR was not present"
  fi
done
echo

ok "Done"
