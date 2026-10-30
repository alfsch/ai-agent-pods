#!/usr/bin/env bash
# Tests for the agent-pod launcher against a stubbed `docker` (no daemon needed). See "Testing" in
# docs/docker-sidecar.md. Usage: tests/stubbed-docker.sh [--no-mutants] [test-name ...]   (default: all tests + mutants)
# Everything the daemon would do (rootless sidecar, TLS, real volumes, real signals through Docker) is
# NOT covered here; use the real-Docker checklist in the docs for that.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
LAUNCHER="${LAUNCHER:-$ROOT/agent-pod}"
UNINSTALLER="${UNINSTALLER:-$ROOT/uninstall.sh}"
ITEST="${ITEST:-$ROOT/tests/integration.sh}"
PUBTAG="${PUBTAG:-$ROOT/tests/published-base-tag.sh}"   # picks the published base that integration-tests.yaml verifies
INSTALLER="${INSTALLER:-$ROOT/install.sh}"   # the installer whose --build-hash is tested
WORKFLOW="${WORKFLOW:-$ROOT/.github/workflows/publish-base.yaml}"   # the publish workflow whose create and sign steps are run in test_publish_signs_created_digest
PRUNE="${PRUNE:-$ROOT/.github/scripts/prune-base-images.sh}"   # the script that prune-base-images.yaml runs
DOCKERFILE="${DOCKERFILE:-$ROOT/Dockerfile}"   # the agent Dockerfile whose install layer is run in test_agent_install_layer
# The suite runs for one agent (the launcher takes it as its first argument); the agent differences have tests of their own.
AGENT="${AGENT-claude}"

# The stub logs every call ("$*") and is steered by STUB_* variables:
#   STUB_POD_EXIT=N       exit code of the pod (default 0)
#   STUB_POD_SLEEP=N      the pod runs N seconds or until `docker stop <pod>` (then exits 143)
#   STUB_POD_CREATE_DELAY=N  the pod is "created but not started" for N seconds first; like real Docker,
#                         `docker stop` then succeeds and does nothing (measured: rc 0, state stays created)
#   STUB_NAME_CONFLICT=1  `docker run -d` fails like a taken container name
#   STUB_SIDECAR_DEAD=1   sidecar never becomes ready and is reported as exited, with a rootlesskit log
#   STUB_READY_AFTER=N    sidecar becomes ready after N failed `exec` probes (1000 = never)
#   STUB_VOLUME_EXISTS=1  `volume inspect` succeeds (cache reuse)
#   STUB_RM_INUSE / STUB_RM_MISSING   space-separated volume names for which `volume rm` fails
#                         with the real Docker 28 wording ("volume is in use" / "no such volume")
#   STUB_NETRM_SLEEP=N    `network rm` takes N seconds (widens the cleanup window for signals)
#   STUB_UID / STUB_GID   what `id -u` / `id -g` report (default 1000, so the real host uid never matters)
#   STUB_UNAME=Darwin     what `uname -s` reports (default Linux)
#   STUB_POD_LINGER=N     after `docker stop` the container is gone ("No such container") but the client
#                         keeps running N more seconds, like a client still writing output; a second signal
#                         to it is recorded in client-killed (the real client then exits 1 and cuts the output)
#   STUB_POD_DRAIN=N      the container is already gone when the client starts (the pod ended by itself, --rm) but
#                         the client keeps writing for N seconds; like Docker's client it survives two signals
#                         and exits 1 on the third (client-killed)
#   STUB_STOP_ERROR_AT=N  the Nth `docker stop` of the pod fails with an error other than "No such container"
#   STUB_CHANNEL / STUB_VERSION / STUB_BUILD   the agent-pod.channel / .version / .build labels of the image;
#                         STUB_VERSION_OUT is what `<agent> --version` prints in it
#   STUB_POD_STDIN=1      the pod stores its stdin in $STUB_DIR/pod-stdin
#   STUB_NO_IMAGE=1       the agent image is missing until the stub install.sh ran
#   STUB_DERIVED_EXISTS=1 the derived sidecar image already exists; STUB_BUILD_FAIL=1 `docker build` fails
#   STUB_PUBLISHED="t1 t2" the tags `docker pull` finds (the others are not in the registry); STUB_UNSIGNED="t1" the tags that
#                         are there but have no signature (cosign finds none)
#   STUB_PULL_FAIL=1      `docker pull` fails like a registry rate limit
#   STUB_INDEX_JSON=x     what `buildx imagetools create --dry-run` prints (the index to be pushed); STUB_INSPECT_FAIL=1 makes
#                         `imagetools inspect <ref>@sha256:...` fail; looking a tag up gives a digest that is not the created one
#   STUB_REPO_DIGEST=x    what the pulled image's RepoDigests hold (empty by default); STUB_COSIGN_FAIL=1 `cosign verify` fails
#                         like a signature that does not match; STUB_COSIGN_NET=1 it cannot reach Sigstore; STUB_COSIGN_BUNDLE=1
#                         it rejects a malformed bundle whose field it echoes; STUB_COSIGN_RUN_FAIL=N `docker run` of the image exits N (125-127)
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
echo "$1 ${DOCKER_HOST:-}" >> "$STUB_DIR/hosts"
case "$1" in
  info)
    # STUB_ROOTLESS=1: the default daemon is rootless; STUB_ROOTFUL_SOCK=1: there is a rootful one at /var/run/docker.sock
    # a set DOCKER_CONTEXT wins over DOCKER_HOST, as in the real client: the default daemon answers
    if [ "${DOCKER_HOST:-}" = unix:///var/run/docker.sock ] && [ -z "${DOCKER_CONTEXT:-}" ]; then
      [ -n "${STUB_ROOTFUL_SOCK:-}" ] || exit 1
      # STUB_ROOTFUL_ROOTLESS=1: that socket answers, but it is a rootless daemon too
      [[ "$*" != *SecurityOptions* ]] || echo "[name=seccomp,profile=builtin${STUB_ROOTFUL_ROOTLESS:+ name=rootless} name=cgroupns]"; exit 0
    fi
    [[ "$*" != *SecurityOptions* ]] || echo "[name=seccomp,profile=builtin${STUB_ROOTLESS:+ name=rootless} name=cgroupns]"; exit 0 ;;
  image)
    # image labels, for the update check
    if [ "$2" = inspect ]; then
      case "$*" in *RepoDigests*) [ -z "${STUB_REPO_DIGEST:-}" ] || echo "$STUB_REPO_DIGEST" ;; *agent-pod.channel*) echo "${STUB_CHANNEL:-}" ;; *agent-pod.version*) echo "${STUB_VERSION:-}" ;; *agent-pod.build*) echo "${STUB_BUILD:-}" ;; esac
      exit 0
    fi
    if [[ "$*" == *agent-pod-dind* ]]; then
      { [ -n "${STUB_DERIVED_EXISTS:-}" ] || [ -e "$STUB_DIR/built" ]; } && echo derivedid; exit 0
    fi
    # the agent image: present, unless STUB_NO_IMAGE=1 and the (stub) install.sh has not run
    if [ "$2" = ls ] && { [ -z "${STUB_NO_IMAGE:-}" ] || [ -e "$STUB_DIR/installed" ]; }; then echo abc123; fi
    exit 0 ;;
  pull)
    # STUB_PUBLISHED set: only these tags are in the registry
    [ -z "${STUB_PUBLISHED+x}" ] || [[ " $STUB_PUBLISHED " == *" ${2##*:} "* ]] || { echo "Error response from daemon: manifest for $2 not found: manifest unknown" >&2; exit 1; }
    [ -z "${STUB_PULL_FAIL:-}" ] || { echo 'Error response from daemon: toomanyrequests: You have reached your pull rate limit.' >&2; exit 1; }; exit 0 ;;
  build) cat > "$STUB_DIR/dockerfile"; : > "$STUB_DIR/built"; exit "${STUB_BUILD_FAIL:-0}" ;;
  buildx)
    case "$*" in
      *"imagetools create --dry-run"*) printf '%s\n' "${STUB_INDEX_JSON:-}" ;;
      *"imagetools inspect"*"@sha256:"*) exit "${STUB_INSPECT_FAIL:-0}" ;;
      *"imagetools inspect"*) echo '{"digest":"sha256:replaced"}' ;;   # a tag: it points at something else by now
    esac
    exit 0 ;;
  network) [ "$2" = rm ] && sleep "${STUB_NETRM_SLEEP:-0}"; exit 0 ;;
  volume)
    case "$2" in
      ls) [ -z "${STUB_VOLUMES:-}" ] || echo "$STUB_VOLUMES"; exit 0 ;;   # the volumes the daemon lists (one name)
      inspect) [ -n "${STUB_VOLUME_EXISTS:-}" ]; exit ;;
      rm)
        if [[ " ${STUB_RM_INUSE:-} " == *" $3 "* ]]; then
          echo "Error response from daemon: remove $3: volume is in use - [7899c51c54fa]" >&2; exit 1
        elif [[ " ${STUB_RM_MISSING:-} " == *" $3 "* ]]; then
          echo "Error response from daemon: get $3: no such volume" >&2; exit 1
        fi ;;
    esac
    exit 0 ;;
  run)
    # the cosign container: the verification of the published base
    if [[ "$*" == *sigstore/cosign/cosign* ]]; then
      [ -z "${STUB_COSIGN_RUN_FAIL:-}" ] || { echo 'docker: Error response from daemon: Get "https://ghcr.io/v2/": net/http: request canceled' >&2; exit "$STUB_COSIGN_RUN_FAIL"; }
      [ -z "${STUB_COSIGN_NET:-}" ] || { echo 'Error: getting trust root: dial tcp: lookup tuf-repo-cdn.sigstore.dev: no such host' >&2; exit 1; }
      all="$*"; [[ -z "${STUB_UNSIGNED:-}" || " $STUB_UNSIGNED " != *" ${all##*:} "* ]] || { echo 'Error: no signatures found' >&2; exit 1; }
      [ -z "${STUB_COSIGN_BUNDLE:-}" ] || { echo 'Error: invalid kind value: "dial tcp"' >&2; exit 1; }
      [ -z "${STUB_COSIGN_FAIL:-}" ] || { echo 'Error: no matching signatures: none of the expected identities matched' >&2; exit 1; }
      exit 0
    fi
    # `<agent> --version` inside the image (the launcher reads the installed version from it)
    case "$*" in *" --version") echo "${STUB_VERSION_OUT:-}"; exit 0 ;; esac
    if [ "$2" = -d ]; then
      if [ -n "${STUB_NAME_CONFLICT:-}" ]; then
        echo 'docker: Error response from daemon: Conflict. The container name is already in use.' >&2; exit 125
      fi
      : > "$STUB_DIR/sidecar"; echo sidecarid; exit 0
    fi
    [ -z "${STUB_POD_STDIN:-}" ] || cat > "$STUB_DIR/pod-stdin"   # what the pod receives on stdin
    if [ -n "${STUB_POD_SLEEP:-}${STUB_POD_DRAIN:-}" ]; then
      : > "$STUB_DIR/pod-created"; sleep "${STUB_POD_CREATE_DELAY:-0}"
      sleep "${STUB_POD_SLEEP:-$STUB_POD_DRAIN}" & s=$!
      term() {
        if [ -n "${STUB_POD_DRAIN:-}" ]; then
          echo x >> "$STUB_DIR/client-signals"
          [ "$(wc -l < "$STUB_DIR/client-signals")" -ge 3 ] || return 0
          : > "$STUB_DIR/client-killed"; exit 1
        fi
        if [ -e "$STUB_DIR/pod-stopped" ]; then : > "$STUB_DIR/client-killed"; exit 1; fi
        kill $s 2>/dev/null
        if [ -n "${STUB_POD_LINGER:-}" ]; then : > "$STUB_DIR/pod-stopped"; sleep "$STUB_POD_LINGER" & wait $!; fi
        exit 143
      }
      trap term TERM
      echo $$ > "$STUB_DIR/pod.pid"
      echo started > "$STUB_DIR/pod-running"
      [ -z "${STUB_POD_DRAIN:-}" ] || : > "$STUB_DIR/pod-stopped"
      while kill -0 $s 2>/dev/null; do wait $s 2>/dev/null; done
    fi
    exit "${STUB_POD_EXIT:-0}" ;;
  exec)
    [[ "$*" == *"system df"* ]] && { echo 'Images|3|1.2GB'; exit 0; }
    [ -z "${STUB_SIDECAR_DEAD:-}" ] || exit 1
    n="$(cat "$STUB_DIR/probes" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUB_DIR/probes"
    [ "$n" -ge "${STUB_READY_AFTER:-0}" ]; exit ;;
  inspect) [ -n "${STUB_SIDECAR_DEAD:-}" ] && echo false || echo true; exit 0 ;;
  logs) [ -z "${STUB_SIDECAR_DEAD:-}" ] || echo '[rootlesskit:parent] error: fork/exec /proc/self/exe: operation not permitted'; exit 0 ;;
  ps) [ ! -e "$STUB_DIR/sidecar" ] || echo sidecarid; exit 0 ;;
  stop)
    # Stopping the pod ends the stub pod; its own exit code (143) is what the launcher must report.
    if [[ "$*" == *agent-pod-run-* ]]; then
      if [ -e "$STUB_DIR/pod-stopped" ]; then echo 'Error response from daemon: No such container: x' >&2; exit 1; fi
      n="$(cat "$STUB_DIR/stops" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUB_DIR/stops"
      [ "$((n + 1))" != "${STUB_STOP_ERROR_AT:-0}" ] || { echo 'Error response from daemon: connection reset by peer' >&2; exit 1; }
      if [ ! -f "$STUB_DIR/pod.pid" ]; then
        [ -f "$STUB_DIR/pod-created" ] && exit 0   # created, not started: succeeds and does nothing
        echo 'Error response from daemon: No such container' >&2; exit 1
      fi
      kill -TERM "$(cat "$STUB_DIR/pod.pid")" 2>/dev/null
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/docker"
cat >"$BIN/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -u) echo "${STUB_UID:-1000}" ;; -g) echo "${STUB_GID:-1000}" ;; *) exec /usr/bin/id "$@" ;; esac
STUB
cat >"$BIN/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -s) echo "${STUB_UNAME:-Linux}" ;; *) exec /usr/bin/uname "$@" ;; esac
STUB
# the npm registry: both channels are at 9.9.9; GitHub's /releases/latest redirects to the tag v9.9.9
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *package/aaif-goose*) exit 22 ;;   # a GitHub repository is not an npm package
  *redirect_url*) echo 'https://github.com/o/r/releases/tag/v9.9.9' ;;
  *) echo '{"latest":"9.9.9","stable":"9.9.9"}' ;;
esac
STUB
# cosign on the PATH: only the publish workflow signs with it (install.sh verifies with the cosign container, see the docker stub)
cat >"$BIN/cosign" <<'STUB'
#!/usr/bin/env bash
echo "cosign $*" >> "$STUB_LOG"
STUB
chmod +x "$BIN/id" "$BIN/uname" "$BIN/curl" "$BIN/cosign"
# macOS has no sha256sum, which the publish workflow (it runs on Linux) calls in the steps test_publish_signs_created_digest
# runs: a stand-in with the same output (hash, two spaces, name) where it is missing.
command -v sha256sum >/dev/null 2>&1 || { printf '%s\n' '#!/usr/bin/env bash' 'exec shasum -a 256 "$@"' > "$BIN/sha256sum"; chmod +x "$BIN/sha256sum"; }
# macOS has no timeout(1): a stand-in with its contract (the command's status, 124 when it ran out of time).
# It is always written (test_timeout_standin tests it on every platform) and used where timeout(1) is missing;
# STUB_TIMEOUT_STANDIN=1 uses it even where timeout exists.
cat >"$BIN/timeout-standin" <<'STUB'
#!/usr/bin/env bash
secs="$1"; shift
flag="$(mktemp)"; rm -f "$flag"
# Job control gives every background job a process group of its own (pgid = its pid). The command's group holds
# everything it starts, children started after a TERM and children whose parent has exited included, so signalling
# the group reaches them all: a hung child, one that ignores TERM, a cleanup child. The launcher defers its TERM
# trap while a foreground command runs, so signalling only its pid would not end a hung child.
set -m
"$@" &
p=$!
( sleep "$secs"; : > "$flag"; kill -TERM -- -"$p" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do   # up to 2 seconds of grace, less when everything is gone
    kill -0 -- -"$p" 2>/dev/null || break; sleep 0.2
  done
  kill -KILL -- -"$p" 2>/dev/null ) &
w=$!
wait "$p" 2>/dev/null; rc=$?
if [ -e "$flag" ]; then wait "$w" 2>/dev/null; rm -f "$flag"; exit 124; fi   # let the KILL stage finish
kill -- -"$w" 2>/dev/null; wait "$w" 2>/dev/null   # the watchdog and its timer (a lingering sleep holds a captured pipe open)
exit "$rc"
STUB
chmod +x "$BIN/timeout-standin"
{ command -v timeout >/dev/null 2>&1 && [ -z "${STUB_TIMEOUT_STANDIN:-}" ]; } || cp "$BIN/timeout-standin" "$BIN/timeout"

# ---- harness -------------------------------------------------------------------------------------------
# Portable between GNU and BSD (macOS) userlands.
sha16() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16; }
touch_ago() { local days="$1"; shift; touch -d "$days days ago" "$@" 2>/dev/null || touch -t "$(date -v-"$days"d +%Y%m%d%H%M)" "$@"; }
fail() { echo "    FAIL: $*" >&2; [ -f "$CASE/out" ] && sed 's/^/    out| /' "$CASE/out" >&2; [ -f "$CASE/err" ] && sed 's/^/    err| /' "$CASE/err" >&2; [ -f "$STUB_LOG" ] && sed 's/^/    log| /' "$STUB_LOG" >&2; exit 1; }
setup_case() {
  CASE="$(mktemp -d "$T/case.XXXXXX")"
  PROJ="$CASE/my proj"; H="$CASE/home dir"          # spaces on purpose
  STATE="$H/state/agent-pod/caches"
  mkdir -p "$PROJ" "$H"
  export STUB_LOG="$CASE/docker.log" STUB_DIR="$CASE/stub"; mkdir -p "$STUB_DIR"; : > "$STUB_LOG"
  HASH="$(cd "$PROJ" && { pwd -P; echo 1000:1000; } | sha16)"   # the stub reports uid and gid 1000
}
launch_env() { cd "$PROJ" && unset DOCKER_HOST DOCKER_CONTEXT && HOME="$H" XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" AGENT_POD_NO_UPDATE=1 PATH="$BIN:$PATH" "$@"; }
launch() {   # launch <env VAR=...>... -- args   (foreground; sets RC)
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  RC=0; (launch_env env ${envs[@]+"${envs[@]}"} timeout 60 "$LAUNCHER" ${AGENT:+"$AGENT"} "$@" </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
}
launch_bg() { # same, background; sets LPID
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  # Job control (set -m) gives the background launcher default signal dispositions; without it a non-interactive
  # shell starts async commands with SIGINT ignored, and bash cannot trap a signal that was ignored on entry.
  set -m
  (launch_env exec env ${envs[@]+"${envs[@]}"} "$LAUNCHER" ${AGENT:+"$AGENT"} "$@" </dev/null >"$CASE/out" 2>"$CASE/err") &
  LPID=$!
  set +m
  ( sleep 45; kill -9 "$LPID" 2>/dev/null ) & WD=$!
}
finish_bg() { RC=0; wait "$LPID" || RC=$?; kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null; return 0; }
logged()    { grep -qE -- "$1" "$STUB_LOG" || fail "expected docker call matching: $1"; }
not_logged(){ ! grep -qE -- "$1" "$STUB_LOG" || fail "unexpected docker call matching: $1"; }
# No pipe from cat: with pipefail, a grep -q that stops at an early match leaves cat writing into a closed pipe, which on
# macOS ends as "cat: stdout: Broken pipe" and a failed pipeline although the text was found (a flaky test_base_image).
in_out()    { grep -qE -- "$1" "$CASE/out" "$CASE/err" || fail "expected output matching: $1"; }
not_in_out() { ! grep -qE -- "$1" "$CASE/out" "$CASE/err" || fail "unexpected output matching: $1"; }
rc_is()     { [ "$RC" = "$1" ] || fail "exit code $RC, expected $1"; }
order() {    # order <regex>... : first match of each appears in this order
  local last=0 n re; for re in "$@"; do
    n="$(grep -nE -- "$re" "$STUB_LOG" | head -n1 | cut -d: -f1)"; [ -n "$n" ] || fail "missing docker call: $re"
    [ "$n" -gt "$last" ] || fail "docker call out of order: $re"; last=$n; done
}
wait_for() { local _; for _ in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; fail "timed out waiting for $1"; }

# ---- tests ---------------------------------------------------------------------------------------------
test_timeout_standin() {   # the stand-in for a missing timeout(1): status, 124, hung and TERM-deaf descendants
  local t="$BIN/timeout-standin" s rc
  "$t" 5 true || fail "true was not passed through"
  "$t" 5 sh -c 'exit 7'; rc=$?; [ "$rc" = 7 ] || fail "exit status 7 became $rc"
  # output captured through a pipe must not wait for the watchdog's timer after the command has ended
  s=$SECONDS; out="$("$t" 30 sh -c 'echo hi')"; rc=$?
  [ "$out" = hi ] && [ "$rc" = 0 ] && [ $((SECONDS - s)) -le 3 ] || fail "captured output waited $((SECONDS - s))s for the timer (out='$out', exit $rc)"
  s=$SECONDS; "$t" 1 sleep 5; rc=$?; [ "$rc" = 124 ] && [ $((SECONDS - s)) -le 3 ] || fail "sleep: exit $rc after $((SECONDS - s))s, expected 124 within 3s"
  # the launcher defers its TERM trap while a foreground child hangs: the child must be ended, not waited for
  s=$SECONDS; "$t" 1 bash -c 'trap "exit 143" TERM; sleep 71'; rc=$?
  [ "$rc" = 124 ] && [ $((SECONDS - s)) -le 3 ] || fail "deferred TERM: exit $rc after $((SECONDS - s))s, expected 124 within 3s"
  # the parent exits on TERM but its child ignores it: the child must be gone afterwards (KILL after the grace period).
  # The child records its own pid (and becomes the sleep), so only that process is looked at and, if need be, killed.
  printf '%s\n' 'trap "" TERM; echo $$ > "$1"; exec sleep 72' > "$T/deaf.sh"
  printf '%s\n' 'bash "$1" "$2" & trap "exit 0" TERM; wait' > "$T/parent.sh"
  "$t" 1 bash "$T/parent.sh" "$T/deaf.sh" "$T/deaf.pid"; rc=$?
  [ "$rc" = 124 ] || fail "TERM-deaf child: exit $rc, expected 124"
  [ -s "$T/deaf.pid" ] || fail "the TERM-deaf fixture did not start"
  ! kill -0 "$(cat "$T/deaf.pid")" 2>/dev/null || { kill -KILL "$(cat "$T/deaf.pid")" 2>/dev/null; fail "a descendant that ignores TERM survived"; }
  # on TERM the command starts a new child that hangs, as the launcher's cleanup does: not in the snapshot, but still killed
  printf '%s\n' 'trap '"'"'sleep 73 & echo $! > "$1"; wait'"'"' TERM; sleep 74 & wait' > "$T/cleanup.sh"
  "$t" 1 bash "$T/cleanup.sh" "$T/late.pid"; rc=$?
  [ "$rc" = 124 ] || fail "late child: exit $rc, expected 124"
  [ -s "$T/late.pid" ] || fail "the late-child fixture did not start its cleanup child"
  ! kill -0 "$(cat "$T/late.pid")" 2>/dev/null || { kill -KILL "$(cat "$T/late.pid")" 2>/dev/null; fail "a child started after the TERM survived"; }
  # the same, but the command exits right after starting that child: the child is reparented and only the process
  # group still holds it
  printf '%s\n' 'trap '"'"'sleep 75 & echo $! > "$1"; exit 0'"'"' TERM; sleep 76 & wait' > "$T/orphan.sh"
  "$t" 1 bash "$T/orphan.sh" "$T/orphan.pid"; rc=$?
  [ "$rc" = 124 ] || fail "reparented late child: exit $rc, expected 124"
  [ -s "$T/orphan.pid" ] || fail "the reparenting fixture did not start its child"
  ! kill -0 "$(cat "$T/orphan.pid")" 2>/dev/null || { kill -KILL "$(cat "$T/orphan.pid")" 2>/dev/null; fail "a child whose parent had exited survived"; }
}
test_plain_exec() {   # without DOCKER=1 the launcher only execs docker run (invariant 7)
  setup_case; launch STUB_POD_EXIT=3 -- true
  rc_is 3
  [ "$(grep -c . "$STUB_LOG")" = 3 ] || fail "expected info, image ls and one run"
  not_logged 'network|volume|--init|--privileged'
  logged "^run --rm .*agent-pod:$AGENT true\$"
}
test_rootless_user() {   # rootless Docker maps the host user to container root: the pod must run as 0:0 to read its state dir
  setup_case; AGENT=claude launch STUB_UID=1001 STUB_GID=1001 --
  rc_is 0; logged '^run --rm .*--user 1001:1001 '; not_logged 'IS_SANDBOX'
  setup_case; AGENT=claude launch STUB_ROOTLESS=1 STUB_UID=1001 STUB_GID=1001 --
  rc_is 0; logged '^run --rm .*--user 0:0 '; not_logged 'user 1001'
  logged '^run --rm .* -e IS_SANDBOX=1 '   # Claude Code refuses --dangerously-skip-permissions as root, the pod is the sandbox
  setup_case; AGENT=copilot launch STUB_ROOTLESS=1 --; rc_is 0; logged '^run --rm .*--user 0:0 '; not_logged 'IS_SANDBOX'
}
test_rootless_default_daemon() {   # DOCKER=1 on a rootless default daemon: everything goes to the rootful one, or it stops
  local ok=unix:///var/run/docker.sock
  setup_case; launch DOCKER=1 STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 STUB_UID=1001 STUB_GID=1001 -- true
  rc_is 0; in_out 'rootful daemon at unix:///var/run/docker.sock'
  logged '^run -d --privileged '; logged '^run --rm .*--user 1001:1001 '; not_logged 'user 0:0'
  ! tail -n +2 "$STUB_DIR/hosts" | grep -qvE " $ok\$" || fail "a docker call did not go to the rootful daemon"
  setup_case; launch DOCKER=1 STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 DOCKER_CONTEXT=rootless -- true   # the context must not hide the rootful daemon
  rc_is 0; in_out 'rootful daemon at unix:///var/run/docker.sock'
  setup_case; launch DOCKER=1 STUB_ROOTLESS=1 -- true
  [ "$RC" != 0 ] || fail "started on a rootless daemon without a rootful one"
  in_out 'does not work on a rootless Docker daemon'; not_logged '^run '
  setup_case; launch STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 -- true     # without DOCKER=1 the default daemon stays
  rc_is 0; ! grep -q 'unix:///var/run' "$STUB_DIR/hosts" || fail "switched daemon without DOCKER=1"
  setup_case; launch DOCKER=1 STUB_ROOTFUL_SOCK=1 -- true            # rootful default daemon: nothing changes
  rc_is 0; ! grep -q 'unix:///var/run' "$STUB_DIR/hosts" || fail "switched daemon although the default is rootful"
}
test_harness_ignores_inherited_daemon() {   # the caller's DOCKER_HOST/DOCKER_CONTEXT must not steer the stub cases
  setup_case; DOCKER_HOST=unix:///var/run/docker.sock DOCKER_CONTEXT=rootless launch --
  rc_is 0; ! grep -q 'unix:///var/run' "$STUB_DIR/hosts" || fail "the launcher saw the caller's DOCKER_HOST"
}
test_uninstall_two_daemons() {   # a rootless default daemon with a rootful fallback: both lose their images and volumes
  local vol=agent-pod-docker-0123456789abcdef n
  setup_case; mkdir -p "$H/.claude-pod" "$H/state/agent-pod/caches"
  RC=0; launch_env env STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 STUB_VOLUMES=$vol "$UNINSTALLER" <<<y >"$CASE/out" 2>"$CASE/err" || RC=$?
  rc_is 0; in_out 'rootful fallback'
  grep -qxF 'volume ' "$STUB_DIR/hosts" && grep -qxF 'volume unix:///var/run/docker.sock' "$STUB_DIR/hosts" \
    || fail "volumes were not listed on both daemons"
  grep -qxF 'rmi unix:///var/run/docker.sock' "$STUB_DIR/hosts" || fail "no image removed on the rootful daemon"
  n="$(grep -cxF "volume rm $vol" "$STUB_LOG")"; [ "$n" = 2 ] || fail "the cache volume was removed $n times, expected once per daemon"
  [ ! -e "$H/.claude-pod" ] && [ ! -e "$H/state/agent-pod" ] || fail "host state was not removed"
  setup_case; RC=0; launch_env env STUB_ROOTFUL_SOCK=1 STUB_VOLUMES=$vol "$UNINSTALLER" <<<y >"$CASE/out" 2>"$CASE/err" || RC=$?   # rootful default: one daemon
  rc_is 0; ! grep -q 'unix:///var/run' "$STUB_DIR/hosts" || fail "touched a second daemon although the default is rootful"
  ! grep -q 'No rootful Docker daemon answers' "$CASE/out" "$CASE/err" || fail "warned about a missing rootful daemon on a rootful default"
  n="$(grep -cxF "volume rm $vol" "$STUB_LOG")"; [ "$n" = 1 ] || fail "rootful default: the cache volume was removed $n times, expected once"
  setup_case; RC=0; launch_env env STUB_ROOTLESS=1 STUB_VOLUMES=$vol "$UNINSTALLER" <<<y >"$CASE/out" 2>"$CASE/err" || RC=$?   # no rootful daemon
  rc_is 0; ! grep -q 'rmi unix:///var/run' "$STUB_DIR/hosts" || fail "removed images on a daemon that does not answer"
  in_out 'No rootful Docker daemon answers'   # the leftovers are reported, not silently skipped
  in_out 'run: env -u DOCKER_CONTEXT DOCKER_HOST=unix:///var/run/docker.sock ./uninstall.sh'   # a set context would win over DOCKER_HOST
  n="$(grep -cxF "volume rm $vol" "$STUB_LOG")"; [ "$n" = 1 ] || fail "no rootful daemon: the cache volume was removed $n times, expected once"
}
test_integration_daemons() {   # tests/integration.sh sends its DOCKER=1 checks to the daemon the launcher uses
  local show=(--show-daemons)
  setup_case; RC=0; launch_env env STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 "$ITEST" "${show[@]}" >"$CASE/out" 2>"$CASE/err" || RC=$?
  rc_is 0; in_out 'use: the rootful daemon at unix:///var/run/docker.sock'
  in_out 'sd runs: env -u DOCKER_CONTEXT DOCKER_HOST=unix:///var/run/docker.sock docker$'
  grep -qxF 'version unix:///var/run/docker.sock' "$STUB_DIR/hosts" || fail "an sd call did not reach the rootful daemon"
  setup_case; RC=0; launch_env env STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 STUB_ROOTFUL_ROOTLESS=1 "$ITEST" "${show[@]}" >"$CASE/out" 2>"$CASE/err" || RC=$?
  rc_is 0; in_out 'no rootful one answers'; in_out 'sd runs:  docker$'   # an answering socket that is rootless is no fallback
  setup_case; RC=0; launch_env env STUB_ROOTLESS=1 "$ITEST" "${show[@]}" >"$CASE/out" 2>"$CASE/err" || RC=$?
  rc_is 0; in_out 'no rootful one answers'
  setup_case; RC=0; launch_env env STUB_ROOTFUL_SOCK=1 "$ITEST" "${show[@]}" >"$CASE/out" 2>"$CASE/err" || RC=$?   # rootful default: one daemon
  rc_is 0; in_out 'use: the default daemon'; in_out 'sd runs:  docker$'; grep -qxF 'version ' "$STUB_DIR/hosts" || fail "an sd call did not reach the default daemon"; ! grep -q 'unix:///var/run' "$STUB_DIR/hosts" || fail "probed a second daemon although the default is rootful"
  setup_case; RC=0; launch_env env STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 DOCKER_CONTEXT=rootless "$ITEST" "${show[@]}" >"$CASE/out" 2>"$CASE/err" || RC=$?
  rc_is 0; in_out 'use: the rootful daemon'   # a context of the caller must not hide the rootful daemon
}
test_sequence() {   # DOCKER=1: command order, run-id consistency, exit code, cleanup
  setup_case; launch DOCKER=1 STUB_POD_EXIT=7 -- true
  rc_is 7
  order '^network create agent-pod-net-' '^volume create agent-pod-certs-' '^run -d --privileged --init --name agent-pod-dind-' \
        '^exec -e DOCKER_HOST=tcp://localhost:2376' '^run --rm .*--name agent-pod-run-' \
        '^rm -f agent-pod-run-' '^ps -aq --filter label=agent-pod.run=' '^stop -t 10 sidecarid' '^rm -f -v sidecarid' \
        '^network rm agent-pod-net-' '^volume rm agent-pod-certs-'
  logged '^run --rm .* --init '
  logged '^run --rm .*--network=agent-pod-net-.*DOCKER_HOST=tcp://dind:2376.*DOCKER_TLS_VERIFY=1'
  logged '^run --rm .*--cap-drop=ALL'
  local net rmnet; net="$(sed -n 's/^network create //p' "$STUB_LOG")"; rmnet="$(sed -n 's/^network rm //p' "$STUB_LOG")"
  [ -n "$net" ] && [ "$net" = "$rmnet" ] || fail "cleanup removed '$rmnet', run created '$net'"
  [ "$(sed -n 's/.*label=agent-pod.run=//p' "$STUB_LOG" | head -n1)" = "${net#agent-pod-net-}" ] || fail "run id differs between resources"
  not_logged 'volume rm agent-pod-docker-'
}
test_option_validation() {   # DOCKER=0 etc. must never start a sidecar
  local c; for c in "DOCKER=0" "DOCKER=true" "DOCKER=1 DOCKER_CACHE=false" "DOCKER_CACHE=1" "DOCKER=1 NET=none"; do
    setup_case; launch $c -- true
    rc_is 1; not_logged '^(run|network|volume)'
  done
}
test_cache_new() {   # new cache volume, fixed sidecar name, stamp
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 -- true
  rc_is 0
  in_out "created new agent-pod-docker-$HASH"
  logged "^run -d --privileged --init --name agent-pod-dind-cache-$HASH "
  logged " -v agent-pod-docker-$HASH:/home/rootless/.local/share/docker "
  [ -f "$STATE/agent-pod-docker-$HASH" ] || fail "stamp file missing"
  not_logged 'volume rm agent-pod-docker-'
}
test_cache_reuse() {
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_VOLUME_EXISTS=1 -- true
  rc_is 0; in_out "reusing agent-pod-docker-$HASH \(3 images, 1.2GB\)"
}
test_cache_conflict() {   # name already taken: refuse, point at the leftover, touch nothing of the other session
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_NAME_CONFLICT=1 -- true
  rc_is 1; in_out "docker rm -f agent-pod-dind-cache-$HASH"; ! grep -q 'DOCKER_HOST=' "$CASE/err" "$CASE/out" || fail "the hint names a daemon without a fallback"
  not_logged '^run --rm'; not_logged '^(stop|rm -f -v)'
  logged '^network rm '
  # after the fallback the command typed in the user's shell must reach the rootful daemon, not the rootless default
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_NAME_CONFLICT=1 STUB_ROOTLESS=1 STUB_ROOTFUL_SOCK=1 -- true
  rc_is 1; in_out "env -u DOCKER_CONTEXT DOCKER_HOST=unix:///var/run/docker.sock docker rm -f agent-pod-dind-cache-$HASH"
}
test_host_uid() {   # Linux, uid other than 1000: derived sidecar image for that uid, built once, before the sidecar
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_GID=1002 -- true
  rc_is 0
  logged '^build -q -t agent-pod-dind:uid1001-gid1002-[0-9a-f]{64} --build-arg BASE=docker:[0-9a-z.-]+-dind-rootless@sha256:[0-9a-f]{64} --build-arg U=1001 --build-arg G=1002 --build-arg SUB=100000 -$'
  logged '^run -d --privileged --init .* agent-pod-dind:uid1001-gid1002-[0-9a-f]{64}$'
  order '^build ' '^network create' '^run -d'
  grep -q 'rootless:x:\$U:\$G:' "$STUB_DIR/dockerfile" || fail "Dockerfile does not renumber the rootless user"
  in_out 'Building Docker sidecar image for uid 1001'
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_GID=1002 STUB_DERIVED_EXISTS=1 -- true   # already built: reused
  rc_is 0; not_logged '^build '; logged '^run -d .* agent-pod-dind:uid1001-gid1002-'
}
test_host_uid_subid_range() {   # the subordinate id range must not contain the host uid or gid (else dockerd cannot start)
  local c; for c in "1001 1002 100000" "100000 1001 200000" "1001 150000 200000" "165535 165536 200000" "165536 1001 100000" \
                    "150000 200000 300000" "200000 200000 100000" "4294960000 1000 100000" "1001 4294967293 100000"; do
    set -- $c; setup_case; launch DOCKER=1 STUB_UID=$1 STUB_GID=$2 -- true
    rc_is 0; logged " --build-arg U=$1 --build-arg G=$2 --build-arg SUB=$3 -\$"
  done
  grep -q 'rootless:\$SUB:65536' "$STUB_DIR/dockerfile" || fail "Dockerfile does not write the subordinate range"
  grep -q '/etc/subuid' "$STUB_DIR/dockerfile" && grep -q '/etc/subgid' "$STUB_DIR/dockerfile" || fail "range written to only one of subuid/subgid"
}
test_host_uid_skipped() {   # stock image: uid 1000, root, a non-Linux host, a user-set DIND_IMAGE
  local c; for c in "STUB_UID=1000" "STUB_UID=0" "STUB_UID=1001 STUB_UNAME=Darwin" "STUB_UID=1001 DIND_IMAGE=my/dind:1"; do
    setup_case; launch DOCKER=1 $c -- true
    rc_is 0; not_logged '^build '; not_logged 'agent-pod-dind:'
  done
  logged '^run -d .* my/dind:1$'
}
test_host_uid_build_fails() {   # no sidecar without its image
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_BUILD_FAIL=1 -- true
  rc_is 1; in_out 'Could not build the Docker sidecar image for uid 1001'; not_logged '^run '
}
test_host_uid_cache() {   # the cache volume of the derived image is separate from the one owned by uid 1000
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 -- true
  local h; h="$(cd "$PROJ" && { pwd -P; echo 1001:1000; } | sha16)"
  rc_is 0; in_out "created new agent-pod-docker-$h"; logged "^run -d .*--name agent-pod-dind-cache-$h "
  [ "$h" != "$HASH" ] || fail "uid not part of the hash"
  # same uid, other primary group (sg, newgrp): another derived image, so another volume
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 STUB_GID=1002 -- true
  local h2; h2="$(cd "$PROJ" && { pwd -P; echo 1001:1002; } | sha16)"
  rc_is 0; in_out "created new agent-pod-docker-$h2"; [ "$h2" != "$h" ] || fail "gid not part of the hash"
  # a user-set DIND_IMAGE keeps the stock image (uid 1000): same cache as on a uid 1000 host, not the derived one
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 DIND_IMAGE=my/dind:1 -- true
  rc_is 0; in_out "created new agent-pod-docker-$HASH"
}
test_prune() {   # old stamps pruned; young, in-use and foreign files kept; gone volumes lose only the stamp
  setup_case; mkdir -p "$STATE"
  local old=agent-pod-docker-aaaaaaaaaaaaaaaa young=agent-pod-docker-bbbbbbbbbbbbbbbb \
        inuse=agent-pod-docker-cccccccccccccccc gone=agent-pod-docker-dddddddddddddddd
  touch_ago 3 "$STATE/$old" "$STATE/$inuse" "$STATE/$gone" "$STATE/not-a-cache" "$STATE/agent-pod-docker-short"
  touch "$STATE/$young"
  launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=1 STUB_RM_INUSE="$inuse" STUB_RM_MISSING="$gone" -- true
  rc_is 0
  logged "^volume rm $old\$"; [ ! -e "$STATE/$old" ] || fail "old stamp not removed"
  in_out "Removed Docker cache $old"
  [ -e "$STATE/$young" ] || fail "young stamp removed"; not_logged "volume rm $young"
  [ -e "$STATE/$inuse" ] || fail "in-use stamp removed"
  [ ! -e "$STATE/$gone" ] || fail "stamp of an already deleted volume kept"
  ! grep -q "Removed Docker cache $gone" "$CASE/err" || fail "reported a removal that did not happen"
  not_logged 'volume rm (not-a-cache|agent-pod-docker-short)'; [ -e "$STATE/not-a-cache" ] || fail "foreign file removed"
}
test_prune_settings() {   # 0 disables, garbage is rejected before anything starts
  setup_case; mkdir -p "$STATE"; touch_ago 400 "$STATE/agent-pod-docker-aaaaaaaaaaaaaaaa"
  launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=0 -- true
  rc_is 0; not_logged 'volume rm agent-pod-docker-'
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=abc -- true
  rc_is 1; in_out 'must be a number of days'; not_logged '^run -d'
}
test_sidecar_dead() {   # exited sidecar: reported immediately with the userns hint, then cleaned up
  setup_case; local s=$SECONDS; launch DOCKER=1 STUB_SIDECAR_DEAD=1 -- true
  rc_is 1; [ $((SECONDS - s)) -lt 10 ] || fail "took the full readiness timeout"
  in_out 'exited during startup'; in_out 'unprivileged user namespaces'
  not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm agent-pod-certs-'
}
test_term_startup() {   # SIGTERM while the sidecar is starting: 143 and everything removed
  setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 -- true
  wait_for "$STUB_DIR/sidecar"; sleep 1; kill -TERM "$LPID"; finish_bg
  rc_is 143; not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm agent-pod-certs-'
}
test_double_term_startup() {   # a second SIGTERM during cleanup must not cut it short
  setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 STUB_NETRM_SLEEP=3 -- true
  wait_for "$STUB_DIR/sidecar"; sleep 1; kill -TERM "$LPID"
  wait_for_log() { local _; for _ in $(seq 1 100); do grep -q '^network rm' "$STUB_LOG" && return 0; sleep 0.1; done; fail "cleanup never started"; }
  wait_for_log; sleep 0.5; kill -TERM "$LPID" 2>/dev/null; finish_bg
  logged '^volume rm agent-pod-certs-'
}
test_term_running() {   # SIGTERM while the pod runs: pod is stopped first, its status (143) is reported, then cleanup
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 -- sleep 60
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 143; order '^stop -t 10 agent-pod-run-' '^rm -f agent-pod-run-' '^rm -f -v sidecarid' '^network rm' '^volume rm agent-pod-certs-'
}
test_int_hup_startup() {   # INT/HUP while the sidecar starts: 130/129, everything removed
  local sig code; for sig in INT:130 HUP:129; do code=${sig#*:}; sig=${sig%:*}
    setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 -- true
    wait_for "$STUB_DIR/sidecar"; sleep 1; kill -"$sig" "$LPID"; finish_bg
    rc_is "$code"; not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm agent-pod-certs-'
  done
}
test_int_hup_running() {   # INT/HUP while the pod runs: pod stopped first, then cleanup (same path as SIGTERM)
  local sig; for sig in INT HUP; do
    setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 -- sleep 60
    wait_for "$STUB_DIR/pod-running"; kill -"$sig" "$LPID"; finish_bg
    rc_is 143; order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm' '^volume rm agent-pod-certs-'
  done
}
test_stop_signal() {   # only the default (interactive) shell is stopped with SIGHUP; see the comment in the launcher
  setup_case; launch DOCKER=1 --
  rc_is 0; logged '^run --rm .*--init --stop-signal=SIGHUP '
  setup_case; launch DOCKER=1 -- bash
  rc_is 0; logged "^run --rm .*--init --stop-signal=SIGHUP .* agent-pod:$AGENT bash\$"
  local c; for c in "true" "bash -c true" "bash script.sh" "copilot --version"; do
    setup_case; launch DOCKER=1 -- $c
    rc_is 0; not_logged 'stop-signal'
  done
  setup_case; launch -- ; rc_is 0; not_logged 'stop-signal'   # plain path unchanged (invariant 7)
}
test_term_during_pod_creation() {   # a stop that hits the created-but-not-started pod is a no-op in Docker: retry it
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=8 STUB_POD_CREATE_DELAY=3 -- sleep 8
  wait_for "$STUB_DIR/pod-created"; kill -TERM "$LPID"; finish_bg
  rc_is 143; order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_stop_while_client_drains() {   # the container is gone but its client is still finishing: leave it alone
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 STUB_POD_LINGER=3 -- sleep 60
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 143; [ ! -e "$STUB_DIR/client-killed" ] || fail "the client was signalled again while it was finishing its output"
  [ "$(grep -c '^stop -t 10 agent-pod-run-' "$STUB_LOG")" -le 2 ] || fail "stop was retried after the container was gone"
  order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_stop_after_natural_exit() {   # the pod ended by itself and its client is still writing: a stop request must not cut it
  setup_case; launch_bg DOCKER=1 STUB_POD_DRAIN=4 -- true
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 0; [ ! -e "$STUB_DIR/client-killed" ] || fail "the client was signalled until it gave up while it was still writing"
  [ "$(wc -l < "$STUB_DIR/client-signals")" -le 1 ] || fail "the client was signalled more than once"
  order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_stop_error_is_retried() {   # a stop that fails for another reason than "no such container" must not end the retries
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=8 STUB_POD_CREATE_DELAY=3 STUB_STOP_ERROR_AT=2 -- sleep 8
  wait_for "$STUB_DIR/pod-created"; kill -TERM "$LPID"; finish_bg
  rc_is 143; [ "$(cat "$STUB_DIR/stops")" -ge 3 ] || fail "stop was not retried after the error"
  order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_term_before_pod_pid() {   # a stop request in the gap before POD_PID is known must not be lost
  setup_case
  # The gap is microseconds wide, so inject the signal into a copy of the launcher right before the pod starts.
  local src hook; src="$(cat "$LAUNCHER"; echo x)"; src="${src%x}"
  hook=$'"${RUN_CMD[@]}" <&0 &\n'
  [[ "$src" == *"$hook"* ]] || fail "launcher layout changed: pod start line not found"
  printf '%s%s%s%s' "${src%%"$hook"*}" 'kill -TERM $$'$'\n' "$hook" "${src#*"$hook"}" > "$CASE/injected"; chmod +x "$CASE/injected"
  LAUNCHER="$CASE/injected" launch_bg DOCKER=1 STUB_POD_SLEEP=8 -- sleep 8; finish_bg
  rc_is 143; order '^stop -t 10 agent-pod-run-' '^rm -f -v sidecarid' '^network rm'
}

test_agent_selection() {   # the agent comes from the name the launcher was called by, or from its first argument
  local a n d
  for a in claude copilot goose; do
    setup_case; d="$CASE/links"; mkdir -p "$d"; ln -s "$LAUNCHER" "$d/$a-pod"
    AGENT='' LAUNCHER="$d/$a-pod" launch -- true
    rc_is 0; logged "^run --rm .*agent-pod:$a true\$"
    setup_case; AGENT=$a launch -- true
    rc_is 0; logged "^run --rm .*agent-pod:$a true\$"
  done
  # a symlink chain through another directory still finds the launcher's own directory
  setup_case; d="$CASE/chain"; mkdir -p "$d"; ln -s "$LAUNCHER" "$d/first"; ln -s "$d/first" "$d/claude-pod"
  AGENT='' LAUNCHER="$d/claude-pod" launch -- true; rc_is 0; logged "^run --rm .*agent-pod:claude true\$"
  # --help names the directory of the real script, behind the symlinks (where install.sh is)
  AGENT='' LAUNCHER="$d/claude-pod" launch -- --help; rc_is 0; in_out "$(dirname "$LAUNCHER")/agent-pod claude"
  # no agent, or one that does not exist: usage and an error, no container
  for n in "" "gemini"; do
    setup_case; AGENT='' launch -- $n
    rc_is 1; in_out 'Which agent\?'; not_logged '^run '
  done
  # --help works without Docker work
  setup_case; AGENT='' launch -- --help; rc_is 0; in_out 'agent-pod claude'; [ ! -s "$STUB_LOG" ] || fail "--help talked to docker"
}
test_agent_flags() {   # per agent: its state dir and config file, its self-updater switch, forwarded token variables
  setup_case; AGENT=claude launch -- true
  rc_is 0
  logged " -e DISABLE_AUTOUPDATER=1 "; not_logged 'COPILOT_'; not_logged 'GITHUB_TOKEN'
  logged " -v $H/.claude-pod:/home/agent-pod/.claude "; logged " -v $H/config/agent-pod/claude.json:/home/agent-pod/.claude.json "
  [ -s "$H/config/agent-pod/claude.json" ] && [ ! -e "$H/.copilot-pod" ] || fail "state dir of the wrong agent"
  setup_case; AGENT=copilot launch -- true
  rc_is 0
  logged " -e COPILOT_AUTO_UPDATE=false -e COPILOT_GITHUB_TOKEN -e GH_TOKEN -e GITHUB_TOKEN "; not_logged 'DISABLE_AUTOUPDATER'
  logged " -v $H/.copilot-pod:/home/agent-pod/.copilot "; logged " -v $H/config/agent-pod/copilot.json:/home/agent-pod/.copilot.json "
  [ -s "$H/config/agent-pod/copilot.json" ] && [ ! -e "$H/.claude-pod" ] || fail "state dir of the wrong agent"
  logged " -e HOME=/home/agent-pod "
  # goose: everything inside one mounted dir (XDG dirs pointed into it, no keyring), no self-updater switch, no config
  # file and so no mount of one, the provider keys forwarded, no token for gh
  setup_case; AGENT=goose launch -- true
  rc_is 0
  logged " -v $H/.goose-pod:/home/agent-pod/.goose "
  logged " -e XDG_CONFIG_HOME=/home/agent-pod/.goose/config -e XDG_DATA_HOME=/home/agent-pod/.goose/data -e XDG_STATE_HOME=/home/agent-pod/.goose/state -e GOOSE_DISABLE_KEYRING=1 -e GH_CONFIG_DIR=/home/agent-pod/.config/gh -e GOOSE_PROVIDER -e GOOSE_MODEL -e ANTHROPIC_API_KEY "
  not_logged 'DISABLE_AUTOUPDATER'; not_logged 'COPILOT_'; not_logged 'GITHUB_TOKEN'; not_logged 'GH_TOKEN'; not_logged 'goose\.json'; not_logged ' -e  '
  [ ! -e "$H/config/agent-pod/goose.json" ] && [ -d "$H/.goose-pod" ] && [ ! -e "$H/.claude-pod" ] || fail "state of the wrong agent, or a config file for goose"
  # ~/.agents is read-only in the image, so what goose writes there (skills, plugins) is mounted from outside the
  # pod-writable state dir
  logged " -v $H/config/agent-pod/goose-skills:/home/agent-pod/.agents/skills -v $H/config/agent-pod/goose-plugins:/home/agent-pod/.agents/plugins -v $H/config/agent-pod/goose-agents:/home/agent-pod/.agents/agents "
  [ -d "$H/config/agent-pod/goose-skills" ] && [ -d "$H/config/agent-pod/goose-plugins" ] && [ -d "$H/config/agent-pod/goose-agents" ] || fail "the skills or plugins dir of goose was not created on the host"
  # the other agents read global skills from there too, but have no plugins there
  setup_case; AGENT=claude launch -- true
  logged " -v $H/config/agent-pod/claude-skills:/home/agent-pod/.agents/skills "; not_logged 'plugins'; not_logged '\.agents/agents'
  [ -d "$H/config/agent-pod/claude-skills" ] && [ ! -e "$H/config/agent-pod/goose-skills" ] || fail "the skills dir of the wrong agent"
  setup_case; AGENT=copilot launch -- true
  logged " -v $H/config/agent-pod/copilot-skills:/home/agent-pod/.agents/skills "; not_logged 'plugins'
}
test_git_identity() {   # a git config of the user is the pod's global one: read-only, by override, agent file or shared file
  local C P
  # the launcher mounts the physical path (macOS: /var is /private/var), so the expectations use it too
  gi() { setup_case; mkdir -p "$H/config/agent-pod"; C="$(cd "$H/config/agent-pod" && pwd -P)"; P="$(cd "$CASE" && pwd -P)"; }
  # none: no mount at all (Docker would create a directory)
  gi; launch -- true; rc_is 0; not_logged 'gitconfig'
  gi; echo a > "$C/gitconfig"; launch -- true; rc_is 0; logged " -v $C/gitconfig:/home/agent-pod/.gitconfig:ro "
  # the agent's own file wins over the shared one, and another agent's file is not used
  gi; echo a > "$C/gitconfig"; echo b > "$C/$AGENT.gitconfig"; echo c > "$C/other.gitconfig"; launch -- true; rc_is 0
  logged " -v $C/$AGENT.gitconfig:/home/agent-pod/.gitconfig:ro "; not_logged "$C/gitconfig:"; not_logged 'other\.gitconfig'
  gi; echo c > "$C/other.gitconfig"; launch -- true; rc_is 0; not_logged 'gitconfig'
  # the override wins over both
  gi; echo a > "$C/gitconfig"; echo b > "$C/$AGENT.gitconfig"; echo w > "$CASE/work"; launch AGENT_POD_GITCONFIG="$CASE/work" -- true; rc_is 0
  logged " -v $P/work:/home/agent-pod/.gitconfig:ro "
  [ "$(grep -o 'gitconfig:ro' "$STUB_LOG" | wc -l | tr -d ' ')" = 1 ] || fail "the override was not the only git config mounted"
  # a relative override (the launcher runs in the project folder) reaches Docker as an absolute path: a relative source is a volume name
  gi; echo w > "$CASE/work"; launch AGENT_POD_GITCONFIG=../work -- true; rc_is 0
  logged " -v $P/work:/home/agent-pod/.gitconfig:ro "; not_logged ' -v \.\./work'
  # an override that is not a file is an error, not a fallback to another identity, and nothing is started
  gi; echo a > "$C/gitconfig"; launch AGENT_POD_GITCONFIG="$CASE/missing" -- true; [ "$RC" != 0 ] || fail "a missing AGENT_POD_GITCONFIG was accepted"
  in_out 'AGENT_POD_GITCONFIG='; not_logged '^run '
  # a file the pod can write to (project folder, the agent's state dir) could be replaced by a symlink to a host key: refused
  gi; echo w > "$PROJ/gc"; launch AGENT_POD_GITCONFIG="$PROJ/gc" -- true; [ "$RC" != 0 ] || fail "a git config in the project folder was accepted"
  in_out 'can write'; not_logged '^run '
  gi; mkdir -p "$H/.claude-pod/sub" "$H/.copilot-pod/sub" "$H/.goose-pod/sub"; echo w > "$H/.claude-pod/sub/gc"; echo w > "$H/.copilot-pod/sub/gc"; echo w > "$H/.goose-pod/sub/gc"
  launch AGENT_POD_GITCONFIG="$H/.${AGENT:-claude}-pod/sub/gc" -- true; [ "$RC" != 0 ] || fail "a git config in the state dir was accepted"
  not_logged '^run '
  gi; mkdir -p "$H/config/agent-pod/${AGENT:-claude}-skills"; echo w > "$H/config/agent-pod/${AGENT:-claude}-skills/gc"
  launch AGENT_POD_GITCONFIG="$H/config/agent-pod/${AGENT:-claude}-skills/gc" -- true; [ "$RC" != 0 ] || fail "a git config in a mounted skills dir was accepted"
  # but a neighbouring directory with a similar name is fine
  gi; mkdir -p "$PROJ-other"; echo w > "$PROJ-other/gc"; launch AGENT_POD_GITCONFIG="$PROJ-other/gc" -- true; rc_is 0
}
test_skills_dir() {   # AGENT_POD_SKILLS_DIR: one read-only mount per skill of a host folder, at the skills dir of each agent
  local S
  sk() { setup_case; S="$(cd "$CASE" && pwd -P)/skills"; mkdir -p "$S/audit" "$S/review" "$S/not-a-skill"; echo a > "$S/audit/SKILL.md"; echo r > "$S/review/SKILL.md"; echo x > "$S/not-a-skill/notes.md"; echo f > "$S/file.md"; }
  # unset: nothing is mounted there
  sk; AGENT=claude launch -- true; rc_is 0; not_logged ':ro'; not_logged '\.claude/skills/'
  # every folder with a SKILL.md, read-only, at the agent's skills dir; folders without one and plain files are left out
  sk; AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; rc_is 0
  logged " -v $S/audit:/home/agent-pod/.claude/skills/audit:ro "; logged " -v $S/review:/home/agent-pod/.claude/skills/review:ro "
  [ -d "$H/.claude-pod/skills" ] || fail "the skills dir in the state dir was not created by the launcher"
  not_logged 'not-a-skill'; not_logged 'file\.md'
  # the state dir stays mounted as a whole, so the synced skills of the account are still there
  logged " -v $H/.claude-pod:/home/agent-pod/.claude "
  # a relative path (the launcher runs in the project folder) reaches Docker as an absolute one: a relative source is a volume name
  sk; AGENT=claude launch AGENT_POD_SKILLS_DIR=../skills -- true; rc_is 0
  logged " -v $S/audit:/home/agent-pod/.claude/skills/audit:ro "; not_logged ' -v \.\./'
  # a path that is not a directory, or a folder without any skill, stops the launcher before anything is started
  sk; AGENT=claude launch AGENT_POD_SKILLS_DIR="$S/missing" -- true; [ "$RC" != 0 ] || fail "a missing AGENT_POD_SKILLS_DIR was accepted"
  in_out 'is not a directory'; not_logged '^run '
  sk; AGENT=claude launch AGENT_POD_SKILLS_DIR="$S/file.md" -- true; [ "$RC" != 0 ] || fail "a file as AGENT_POD_SKILLS_DIR was accepted"
  in_out 'is not a directory'; not_logged '^run '
  sk; AGENT=claude launch AGENT_POD_SKILLS_DIR="$S/not-a-skill" -- true; [ "$RC" != 0 ] || fail "a folder without skills was accepted"
  in_out 'no skill'; not_logged '^run '
  # a skill the pod can write through another mount is refused, as is one that contains such a dir: :ro covers one path only
  sk; mkdir -p "$PROJ/skills/audit"; echo a > "$PROJ/skills/audit/SKILL.md"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$PROJ/skills" -- true; [ "$RC" != 0 ] || fail "skills inside the project folder were accepted"
  in_out 'can write'; not_logged '^run '
  sk; mkdir -p "$H/.claude-pod/mine/audit"; echo a > "$H/.claude-pod/mine/audit/SKILL.md"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$H/.claude-pod/mine" -- true; [ "$RC" != 0 ] || fail "skills inside the state dir were accepted"
  in_out 'can write'; not_logged '^run '
  sk; mkdir -p "$H/config/agent-pod/claude-skills/mine/audit"; echo a > "$H/config/agent-pod/claude-skills/mine/audit/SKILL.md"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$H/config/agent-pod/claude-skills/mine" -- true; [ "$RC" != 0 ] || fail "skills inside a mounted skills dir were accepted"
  in_out 'can write'; not_logged '^run '
  # the project folder itself is a skill, or inside one
  sk; echo a > "$PROJ/SKILL.md"; AGENT=claude launch AGENT_POD_SKILLS_DIR="$CASE" -- true; [ "$RC" != 0 ] || fail "the project folder as a skill was accepted"
  in_out 'can write'; not_logged '^run '
  sk; PROJ="$CASE/outer/proj"; mkdir -p "$PROJ"; echo a > "$CASE/outer/SKILL.md"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$CASE" -- true; [ "$RC" != 0 ] || fail "a project folder inside a skill was accepted"
  in_out 'contains'; not_logged '^run '
  # a skill dir that is a symlink counts by where it really is
  sk; mkdir -p "$PROJ/real"; echo a > "$PROJ/real/SKILL.md"; ln -s "$PROJ/real" "$S/linked"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; [ "$RC" != 0 ] || fail "a skill symlinked into the project folder was accepted"
  in_out 'can write'; not_logged '^run '
  # but a symlink to a folder elsewhere is mounted from its real path, and a neighbouring dir with a similar name is fine
  sk; mkdir -p "$CASE/elsewhere/linked" "$PROJ-other/skills/near"; echo a > "$CASE/elsewhere/linked/SKILL.md"; echo a > "$PROJ-other/skills/near/SKILL.md"
  ln -s "$CASE/elsewhere/linked" "$S/linked"; AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; rc_is 0
  logged " -v $(cd "$CASE/elsewhere/linked" && pwd -P):/home/agent-pod/.claude/skills/linked:ro "
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$PROJ-other/skills" -- true; rc_is 0; logged "skills/near:/home/agent-pod/.claude/skills/near:ro "
  # the skills folder itself counts too: the pod could add or swap entries in it, e.g. a symlink to any host dir with a SKILL.md
  sk; mkdir -p "$PROJ/skills" "$CASE/elsewhere/x"; echo a > "$CASE/elsewhere/x/SKILL.md"; ln -s "$CASE/elsewhere/x" "$PROJ/skills/x"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$PROJ/skills" -- true; [ "$RC" != 0 ] || fail "a skills folder in the project with an outward symlink was accepted"
  in_out 'AGENT_POD_SKILLS_DIR .* is in'; not_logged '^run '
  ln -s "$PROJ/skills" "$CASE/lnk0"   # the same through a symlink: only the resolved folder shows where it is
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$CASE/lnk0" -- true; [ "$RC" != 0 ] || fail "a symlink to a skills folder in the project, with outward skills, was accepted"
  in_out 'AGENT_POD_SKILLS_DIR .* is in'; not_logged '^run '
  sk; mkdir -p "$PROJ/skills/audit"; echo a > "$PROJ/skills/audit/SKILL.md"; ln -s "$PROJ/skills" "$CASE/lnk"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$CASE/lnk" -- true; [ "$RC" != 0 ] || fail "a symlink to a skills folder in the project was accepted"
  in_out 'can write'; not_logged '^run '
  sk; PROJ="$CASE/top/proj"; mkdir -p "$PROJ" "$CASE/top/ok"; echo a > "$CASE/top/ok/SKILL.md"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$CASE/top" -- true; [ "$RC" != 0 ] || fail "a skills folder containing the project was accepted"
  in_out 'AGENT_POD_SKILLS_DIR .* contains'; not_logged '^run '
  # the config file is a writable mount too, and a symlink the user made for it is followed
  sk; echo '{}' > "$S/audit/cfg.json"; mkdir -p "$H/config/agent-pod"; ln -s "$S/audit/cfg.json" "$H/config/agent-pod/claude.json"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; [ "$RC" != 0 ] || fail "a skill containing the symlinked config file was accepted"
  in_out 'AGENT_POD_SKILLS_DIR .* contains'; not_logged '^run '
  # a chain of config file links is followed up to 10 hops; a longer one cannot be checked and is refused, not half-checked
  sk; echo '{}' > "$CASE/cfg.json"; mkdir -p "$H/config/agent-pod"; ln -s "$CASE/cfg.json" "$H/config/agent-pod/l11"
  for i in 10 9 8 7 6 5 4 3 2; do ln -s "$H/config/agent-pod/l$((i + 1))" "$H/config/agent-pod/l$i"; done
  ln -s "$H/config/agent-pod/l2" "$H/config/agent-pod/claude.json"
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; [ "$RC" != 0 ] || fail "a config file behind 11 symlinks was accepted"
  in_out 'more than 10 symlinks'; not_logged '^run '
  rm "$H/config/agent-pod/claude.json"; ln -s "$H/config/agent-pod/l3" "$H/config/agent-pod/claude.json"   # 10 links: followed to the end
  AGENT=claude launch AGENT_POD_SKILLS_DIR="$S" -- true; rc_is 0
  # each agent gets them where it reads its personal skills; goose's dir is one the launcher already mounts from the host
  sk; AGENT=copilot launch AGENT_POD_SKILLS_DIR="$S" -- true; rc_is 0
  logged " -v $S/audit:/home/agent-pod/.copilot/skills/audit:ro "; not_logged '\.claude/skills/'
  # the dir above the mount points is made on the host by the launcher, not by Docker (as root)
  [ -d "$H/.copilot-pod/skills" ] || fail "the skills dir in the state dir was not created by the launcher"
  sk; AGENT=goose launch AGENT_POD_SKILLS_DIR="$S" -- true; rc_is 0
  logged " -v $S/audit:/home/agent-pod/.agents/skills/audit:ro "; logged " -v $H/config/agent-pod/goose-skills:/home/agent-pod/.agents/skills "
  not_logged '\.claude/skills/'
}
test_profile() {   # AGENT_POD_PROFILE: a second login of an agent, kept apart by a name added to every per-agent host path
  local a v C
  pf() { setup_case; mkdir -p "$H/config/agent-pod"; C="$(cd "$H/config/agent-pod" && pwd -P)"; }
  # claude and copilot: the state dir and the account file carry the name, the mounted skills dir too; the defaults are not touched
  for a in claude copilot; do
    pf; AGENT=$a launch AGENT_POD_PROFILE=work -- true; rc_is 0
    logged " -v $H/.$a-pod-work:/home/agent-pod/.$a "; logged " -v $H/config/agent-pod/$a-work.json:/home/agent-pod/.$a.json "
    logged " -v $H/config/agent-pod/$a-work-skills:/home/agent-pod/.agents/skills "
    not_logged " -v $H/\.$a-pod:"; not_logged "agent-pod/$a\.json:"; not_logged "$a-skills:"
    [ -d "$H/.$a-pod-work" ] && [ -s "$H/config/agent-pod/$a-work.json" ] && [ -d "$H/config/agent-pod/$a-work-skills" ] || fail "$a: the profile dirs were not made"
    [ ! -e "$H/.$a-pod" ] && [ ! -e "$H/config/agent-pod/$a.json" ] && [ ! -e "$H/config/agent-pod/$a-skills" ] || fail "$a: the default dirs were made for a profile"
  done
  # goose keeps its config in the state dir, and has three mounted dirs
  pf; AGENT=goose launch AGENT_POD_PROFILE=work -- true; rc_is 0
  logged " -v $H/.goose-pod-work:/home/agent-pod/.goose "
  for v in skills:.agents/skills plugins:.agents/plugins agents:.agents/agents; do logged " -v $H/config/agent-pod/goose-work-${v%%:*}:/home/agent-pod/${v#*:} "; done
  not_logged " -v $H/\.goose-pod:"; not_logged 'goose-skills'; [ ! -e "$H/.goose-pod" ] || fail "goose: the default state dir was made for a profile"
  # two profiles of one agent share nothing, and neither shares with the default login
  pf; AGENT=claude launch AGENT_POD_PROFILE=private -- true; rc_is 0; logged " -v $H/.claude-pod-private:/home/agent-pod/.claude "; not_logged 'claude-pod-work'
  AGENT=claude launch -- true; rc_is 0; logged " -v $H/.claude-pod:/home/agent-pod/.claude "; logged " -v $H/config/agent-pod/claude.json:"
  # an empty name is no profile
  pf; AGENT=claude launch AGENT_POD_PROFILE= -- true; rc_is 0; logged " -v $H/.claude-pod:/home/agent-pod/.claude "; not_logged 'claude-pod-'
  # names that would leave the dir, hide a file, or need quoting are refused before anything starts; the longest valid one is not
  for v in 'a/b' '../x' '-x' '_x' '.h' 'a b' 'a*' 'é' "$(printf 'a%.0s' $(seq 33))"; do
    pf; AGENT=claude launch AGENT_POD_PROFILE="$v" -- true; [ "$RC" != 0 ] || fail "the profile name '$v' was accepted"
    in_out 'AGENT_POD_PROFILE='; not_logged '^run '; [ ! -e "$H/.claude-pod" ] || fail "the default state dir was made for the bad name '$v'"
  done
  for v in W-0_k "$(printf 'a%.0s' $(seq 32))" 0; do pf; AGENT=claude launch AGENT_POD_PROFILE="$v" -- true; rc_is 0; logged " -v $H/.claude-pod-$v:/home/agent-pod/.claude "; done
  # the git identity: the profile's file wins over the agent's and the shared one, which are the fallbacks; another profile's is not used
  pf; echo a > "$C/gitconfig"; echo b > "$C/claude.gitconfig"; echo c > "$C/claude-work.gitconfig"; echo d > "$C/claude-other.gitconfig"
  AGENT=claude launch AGENT_POD_PROFILE=work -- true; rc_is 0; logged " -v $C/claude-work.gitconfig:/home/agent-pod/.gitconfig:ro "; not_logged 'claude-other'
  pf; echo a > "$C/gitconfig"; echo b > "$C/claude.gitconfig"; echo d > "$C/claude-other.gitconfig"
  AGENT=claude launch AGENT_POD_PROFILE=work -- true; rc_is 0; logged " -v $C/claude.gitconfig:/home/agent-pod/.gitconfig:ro "
  pf; echo a > "$C/gitconfig"; echo c > "$C/claude-work.gitconfig"
  AGENT=claude launch -- true; rc_is 0; logged " -v $C/gitconfig:/home/agent-pod/.gitconfig:ro "; not_logged 'claude-work'
  # what the pod can write follows the profile: a git config or a skill in the dir mounted for it is refused, in the default dir it is not
  pf; mkdir -p "$C/claude-work-skills" "$C/claude-skills"; echo w > "$C/claude-work-skills/gc"; echo w > "$C/claude-skills/gc"
  AGENT=claude launch AGENT_POD_PROFILE=work AGENT_POD_GITCONFIG="$C/claude-work-skills/gc" -- true; [ "$RC" != 0 ] || fail "a git config in the profile's mounted dir was accepted"
  AGENT=claude launch AGENT_POD_PROFILE=work AGENT_POD_GITCONFIG="$C/claude-skills/gc" -- true; rc_is 0
  pf; mkdir -p "$C/claude-work-skills/mine/audit" "$C/claude-skills/mine/audit"; echo a > "$C/claude-work-skills/mine/audit/SKILL.md"; echo a > "$C/claude-skills/mine/audit/SKILL.md"
  AGENT=claude launch AGENT_POD_PROFILE=work AGENT_POD_SKILLS_DIR="$C/claude-work-skills/mine" -- true; [ "$RC" != 0 ] || fail "skills in the profile's mounted dir were accepted"
  AGENT=claude launch AGENT_POD_PROFILE=work AGENT_POD_SKILLS_DIR="$C/claude-skills/mine" -- true; rc_is 0
  # the uninstaller takes the state dirs of profiles too, and nothing that only looks like one
  setup_case; mkdir -p "$H/.claude-pod" "$H/.claude-pod-work" "$H/.copilot-pod-W-0_k" "$H/.goose-pod-y" "$H/.claude-pod-_x" "$H/.claude-pod-a b" "$H/.claude-pod-"
  # as long as the launcher takes (32) is removed, one more is not; a newline at the end of a name or a letter outside A-Z is not a profile
  mkdir -p "$H/.goose-pod-$(printf 'a%.0s' $(seq 32))" "$H/.goose-pod-$(printf 'a%.0s' $(seq 33))" "$H/.claude-pod-work"$'\n' "$H/.claude-pod-é"
  : > "$H/.copilot-pod-file"; mkdir -p "$H/.claude-podwork" "$H/keep-pod-work"
  RC=0; launch_env env STUB_ROOTFUL_SOCK=1 "$UNINSTALLER" <<<y >"$CASE/out" 2>"$CASE/err" || RC=$?; rc_is 0
  [ ! -e "$H/.claude-pod" ] && [ ! -e "$H/.claude-pod-work" ] && [ ! -e "$H/.copilot-pod-W-0_k" ] && [ ! -e "$H/.goose-pod-y" ] || fail "a state dir of a profile was not removed"
  [ ! -e "$H/.goose-pod-$(printf 'a%.0s' $(seq 32))" ] || fail "a profile name of 32 characters was not removed"
  [ -d "$H/.goose-pod-$(printf 'a%.0s' $(seq 33))" ] && [ -d "$H/.claude-pod-work"$'\n' ] && [ -d "$H/.claude-pod-é" ] || fail "a name the launcher rejects was removed (33 characters, a trailing newline, or a letter outside A-Z)"
  ! grep -q 'copilot-pod-file' "$CASE/out" || fail "a file named like a state dir was listed for removal"
  [ -d "$H/.claude-pod-_x" ] && [ -d "$H/.claude-pod-a b" ] && [ -d "$H/.claude-pod-" ] && [ -f "$H/.copilot-pod-file" ] && [ -d "$H/.claude-podwork" ] && [ -d "$H/keep-pod-work" ] \
    || fail "the uninstaller removed something that is not the state dir of a profile"
  # a home dir whose own path has -pod- in it: only the name of the dir is judged
  setup_case; H="$CASE/my-pod-home"; mkdir -p "$H/.claude-pod-work"
  RC=0; launch_env env STUB_ROOTFUL_SOCK=1 "$UNINSTALLER" <<<y >"$CASE/out" 2>"$CASE/err" || RC=$?; rc_is 0
  [ ! -e "$H/.claude-pod-work" ] || fail "a profile state dir was not removed from a home dir with -pod- in its path"
}
test_cache_shared_between_agents() {   # one Docker cache per project, whichever agent runs in it
  local a
  for a in claude copilot goose; do
    setup_case; AGENT=$a launch DOCKER=1 DOCKER_CACHE=1 -- true
    rc_is 0; logged "^run -d --privileged --init --name agent-pod-dind-cache-$HASH "
    logged " -v agent-pod-docker-$HASH:/home/rootless/.local/share/docker "
  done
}
test_lazy_build() {   # a missing image is built by install.sh (next to the launcher) before the first start
  local a d
  for a in claude copilot goose; do
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "install.sh $*" >> "$STUB_LOG"; : > "$STUB_DIR/installed"' > "$d/install.sh"; chmod +x "$d/install.sh"
    AGENT=$a LAUNCHER="$d/agent-pod" launch STUB_NO_IMAGE=1 -- true
    rc_is 0; in_out 'building it'; order "^install.sh $a\$" "^run --rm .*agent-pod:$a true\$"
  done
  # present image: install.sh is not called
  setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "install.sh $*" >> "$STUB_LOG"' > "$d/install.sh"; chmod +x "$d/install.sh"
  LAUNCHER="$d/agent-pod" launch -- true; rc_is 0; not_logged '^install.sh'
  # a failed build: no container, a pointer to the installer
  setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$d/install.sh"; chmod +x "$d/install.sh"
  LAUNCHER="$d/agent-pod" launch STUB_NO_IMAGE=1 -- true; rc_is 1; in_out 'Could not build the image'; not_logged '^run '
}

test_stdin_attached() {   # piped or redirected input reaches the pod: -i always, -t only with a terminal on both ends
  setup_case; launch DOCKER=1 -- true
  rc_is 0; logged '^run --rm -i '; not_logged '^run --rm .* -t '
  setup_case; launch -- true
  rc_is 0; logged '^run --rm -i '
}
test_config_file_outside_state_dir() {   # the config file is host-owned, in the config dir: the pod cannot swap it for a symlink
  local f
  setup_case; f="$H/config/agent-pod/claude.json"; mkdir -p "$H/.claude-pod"; printf 'secret' > "$CASE/secret"; chmod 644 "$CASE/secret"
  ln -s "$CASE/secret" "$H/.claude-pod/.claude.json"   # what a pod could leave behind in the state dir
  AGENT=claude launch -- true
  rc_is 0; logged " -v $f:/home/agent-pod/.claude.json "; not_logged "$H/.claude-pod/.claude.json"
  [ "$(ls -l "$CASE/secret" | cut -c1-10)" = "-rw-r--r--" ] || fail "the host file behind the symlink was chmodded"
  [ "$(cat "$f")" = '{}' ] || fail "a symlink in the state dir was copied as the config"
  # an existing config is never overwritten
  setup_case; f="$H/config/agent-pod/claude.json"; mkdir -p "$H/config/agent-pod"
  printf '{"new":1}' > "$f"; AGENT=claude launch -- true; rc_is 0
  [ "$(cat "$f")" = '{"new":1}' ] || fail "an existing config was overwritten"
}

test_update_check() {   # a newer release on the image's channel rebuilds it; the opt-outs skip that, each for its own agent
  local a d v
  upd() {   # upd <agent> <label version> <VAR=value>... : sets UPD=update when install.sh was run, else UPD=no
    # (not printed and captured: a fail() inside $(...) would only end that subshell and the check would still pass)
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "install.sh $*" >> "$STUB_LOG"' > "$d/install.sh"; chmod +x "$d/install.sh"
    local a="$1" v="$2" ch=latest; shift 2; [ "$a" = claude ] || [ "$a" = copilot ] || [ "$a" = goose ] || return 1
    [ "$a" = claude ] && ch=stable
    AGENT=$a LAUNCHER="$d/agent-pod" launch AGENT_POD_NO_UPDATE= STUB_CHANNEL=$ch STUB_VERSION="$v" "$@" -- true
    [ "$RC" = 0 ] || fail "launcher exit $RC"
    if grep -q "^install.sh $a\$" "$STUB_LOG"; then UPD=update; else UPD=no; fi
  }
  for a in claude copilot goose; do
    upd $a 1.0.0; [ "$UPD" = update ] || fail "$a: an outdated image was not updated"
    upd $a 9.9.9; [ "$UPD" != update ] || fail "$a: an image at the newest version was rebuilt"
    upd $a 1.0.0 AGENT_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "$a: AGENT_POD_NO_UPDATE did not skip the update"
  done
  # the old variable of one agent says nothing about the other
  upd claude 1.0.0 CLAUDE_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "CLAUDE_POD_NO_UPDATE did not skip Claude"
  upd copilot 1.0.0 COPILOT_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "COPILOT_POD_NO_UPDATE did not skip Copilot"
  upd goose 1.0.0 CLAUDE_POD_NO_UPDATE=1; [ "$UPD" = update ] || fail "CLAUDE_POD_NO_UPDATE skipped the update of goose"
  upd copilot 1.0.0 CLAUDE_POD_NO_UPDATE=1; [ "$UPD" = update ] || fail "CLAUDE_POD_NO_UPDATE skipped the update of Copilot"
  upd claude 1.0.0 COPILOT_POD_NO_UPDATE=1; [ "$UPD" = update ] || fail "COPILOT_POD_NO_UPDATE skipped the update of Claude"
  # an image built while npm was unreachable has the tag as its version label: the real version comes from the image,
  # whatever text surrounds the number
  for v in "GitHub Copilot CLI 9.9.9." "9.9.9 (Claude Code)"; do
    upd copilot latest STUB_VERSION_OUT="$v"; [ "$UPD" != update ] || fail "'$v' was not recognised as the newest version"
  done
  upd copilot latest STUB_VERSION_OUT="GitHub Copilot CLI 1.0.1."; [ "$UPD" = update ] || fail "an outdated image with a tag label was not updated"
}

test_stdin_reaches_pod() {   # piped input arrives in the pod, also from the background job of the DOCKER=1 path
  local c
  for c in "" "DOCKER=1"; do
    setup_case
    printf 'hello\n' | launch_env env $c STUB_POD_STDIN=1 timeout 60 "$LAUNCHER" "$AGENT" true >"$CASE/out" 2>"$CASE/err"
    [ "$(cat "$STUB_DIR/pod-stdin" 2>/dev/null)" = hello ] || fail "the pod did not receive the piped input ($c)"
  done
}

test_rebuild_on_repo_change() {   # an image built from another Dockerfile (hash label) is rebuilt on the next start, keeping its pin
  local d
  rb() {   # rb <agent> <VAR=value>... : runs the launcher with a stub install.sh that answers --build-hash with "new"
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
    printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = --build-hash ]; then echo new; exit 0; fi' \
      'echo "install.sh $*" >> "$STUB_LOG"; echo "pin ${CLAUDE_CODE_VERSION:-}${COPILOT_CLI_VERSION:-}${GOOSE_VERSION:-}" >> "$STUB_LOG"; exit "${STUB_INSTALL_EXIT:-0}"' > "$d/install.sh"
    chmod +x "$d/install.sh"
    local a="$1"; shift
    AGENT=$a LAUNCHER="$d/agent-pod" launch AGENT_POD_NO_UPDATE= "$@" -- true
  }
  # a different hash: rebuilt once, before the pod starts, with the channel the image was built from
  rb claude STUB_BUILD=old STUB_CHANNEL=stable; rc_is 0
  [ "$(grep -c '^install.sh claude$' "$STUB_LOG")" = 1 ] || fail "the image was not rebuilt exactly once"
  order '^install.sh claude$' '^run --rm .*agent-pod:claude true$'; logged '^pin stable$'; in_out 'repository changed'
  # an image without the label (built before it existed) is rebuilt too
  rb copilot STUB_BUILD= STUB_CHANNEL=latest; rc_is 0; logged '^install.sh copilot$'
  # a pinned image keeps its version
  rb copilot STUB_BUILD=old STUB_CHANNEL=1.2.3; rc_is 0; logged '^pin 1.2.3$'
  rb goose STUB_BUILD=old STUB_CHANNEL=1.2.3; rc_is 0; logged '^install.sh goose$'; logged '^pin 1.2.3$'
  # the same hash: nothing is rebuilt
  rb claude STUB_BUILD=new STUB_CHANNEL=stable STUB_VERSION=9.9.9; rc_is 0; not_logged '^install.sh'
  # opt-out
  rb claude STUB_BUILD=old AGENT_POD_NO_UPDATE=1; rc_is 0; not_logged '^install.sh'
  # a failed rebuild does not stop the start
  rb claude STUB_BUILD=old STUB_CHANNEL=stable STUB_VERSION=9.9.9 STUB_INSTALL_EXIT=1; rc_is 0
  in_out 'Rebuild failed'; logged '^run --rm .*agent-pod:claude true$'
  # ... and the release check does not repeat it, although a newer release exists (installed version is outdated)
  rb claude STUB_BUILD=old STUB_CHANNEL=stable STUB_VERSION=1.0.0 STUB_INSTALL_EXIT=1; rc_is 0
  [ "$(grep -c '^install.sh claude$' "$STUB_LOG")" = 1 ] || fail "a failed rebuild was tried a second time by the release check"
  logged '^run --rm .*agent-pod:claude true$'
  # after a rebuild the release check does not run (it would rebuild a second time)
  rb claude STUB_BUILD=old STUB_CHANNEL=stable STUB_VERSION=1.0.0; rc_is 0
  [ "$(grep -c '^install.sh claude$' "$STUB_LOG")" = 1 ] || fail "rebuilt twice: once for the repository, once for a release"
}

test_build_hash() {   # the hashes install.sh uses change with each of their inputs and with nothing else
  local d b0 h0 h1 h2 h3 b1 b2 h
  setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"
  printf 'FROM x\n' > "$d/Dockerfile"; printf 'FROM base\n' > "$d/Dockerfile.base"; printf 'a\n' > "$d/pod-environment.md"
  h0="$("$d/install.sh" --build-hash)" || fail "--build-hash failed"
  b0="$("$d/install.sh" --base-hash)" || fail "--base-hash failed"
  [[ "$h0" =~ ^[0-9a-f]{16}$ ]] || fail "not 16 hex characters: '$h0'"
  [[ "$b0" =~ ^[0-9a-f]{16}$ ]] || fail "not 16 hex characters: '$b0'"
  [ "$h0" != "$b0" ] || fail "the two hashes are the same"
  [ "$("$d/install.sh" --build-hash)" = "$h0" ] || fail "the hash is not stable for the same inputs"
  # the agent Dockerfile: the agent image changes, the base does not
  printf 'FROM y\n' > "$d/Dockerfile"; h1="$("$d/install.sh" --build-hash)"
  [ -n "$h1" ] && [ "$h1" != "$h0" ] || fail "a changed Dockerfile did not change the hash"
  [ "$("$d/install.sh" --base-hash)" = "$b0" ] || fail "a changed agent Dockerfile changed the base hash"
  # the base Dockerfile: both change
  printf 'FROM x\n' > "$d/Dockerfile"; printf 'FROM base2\n' > "$d/Dockerfile.base"; h2="$("$d/install.sh" --build-hash)"; b1="$("$d/install.sh" --base-hash)"
  [ -n "$h2" ] && [ "$h2" != "$h0" ] && [ "$h2" != "$h1" ] || fail "a changed Dockerfile.base did not change the hash"
  [ -n "$b1" ] && [ "$b1" != "$b0" ] || fail "a changed Dockerfile.base did not change the base hash"
  # pod-environment.md: both change
  printf 'FROM base\n' > "$d/Dockerfile.base"; printf 'b\n' > "$d/pod-environment.md"; h3="$("$d/install.sh" --build-hash)"; b2="$("$d/install.sh" --base-hash)"
  [ -n "$h3" ] && [ "$h3" != "$h0" ] && [ "$h3" != "$h1" ] && [ "$h3" != "$h2" ] || fail "a changed pod-environment.md did not change the hash"
  [ -n "$b2" ] && [ "$b2" != "$b0" ] && [ "$b2" != "$b1" ] || fail "a changed pod-environment.md did not change the base hash"
  printf 'a\n' > "$d/pod-environment.md"; h="$("$d/install.sh" --build-hash)"
  [ "$h" = "$h0" ] || fail "restoring the inputs did not restore the hash"
  [ "$("$d/install.sh" --base-hash)" = "$b0" ] || fail "restoring the inputs did not restore the base hash"
}

test_base_image() {   # install.sh pulls the published base; a failed pull uses the local copy, then builds it; the agent builds on it
  local d
  inst() {   # inst <VAR=value>... : runs a copy of install.sh next to Dockerfiles whose first FROM is node:9-slim
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"
    printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' > "$d/Dockerfile"; printf 'FROM node:9-slim AS first\nFROM other:2\n' > "$d/Dockerfile.base"
    printf 'a\n' > "$d/pod-environment.md"
    TAG="test.invalid/base:$("$d/install.sh" --base-hash)"
    RC=0; (cd "$d" && env HOME="$H" PATH="$BIN:$PATH" AGENT_POD_BASE_REPO=test.invalid/base "$@" ./install.sh claude </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
  }
  # the published tag is pulled, nothing is built for the base, and the agent image is built on it
  inst; rc_is 0; logged "^pull $TAG\$"; not_logged 'node:9-slim'; not_logged 'other:2'; not_logged '-f .*Dockerfile.base'
  logged "--build-arg BASE_IMAGE=$TAG "; order "^pull $TAG\$" '^build .*BASE_IMAGE'
  # a failed pull (a rate limit) with a local copy: that copy is used, the install goes on and says why
  inst STUB_PULL_FAIL=1; rc_is 0; in_out 'toomanyrequests'; in_out 'using the local copy'; not_logged '-f .*Dockerfile.base'; logged '^tag '
  # no local copy either: the base is built here from Dockerfile.base, after pulling the image it is built from (the first FROM only)
  inst STUB_PULL_FAIL=1 STUB_NO_IMAGE=1; rc_is 0; in_out 'building it here'
  logged "^build .*-f .*Dockerfile.base -t $TAG "; logged '^pull node:9-slim$'; not_logged 'other:2'
  order "^pull $TAG\$" '^pull node:9-slim$' '^build .*-f .*Dockerfile.base' '^build .*BASE_IMAGE'
  # the image the base is built from cannot be pulled, but a local copy exists: the base is built on it
  inst AGENT_POD_BUILD_BASE=1 STUB_PULL_FAIL=1; rc_is 0; in_out 'building on the local copy'; logged '^build .*-f .*Dockerfile.base'
  # AGENT_POD_BUILD_BASE=1: the base is always built here, the published tag is not even pulled
  inst AGENT_POD_BUILD_BASE=1; rc_is 0; not_logged "^pull $TAG\$"; logged '^pull node:9-slim$'; logged '^build .*-f .*Dockerfile.base'
}

test_install_agent_source() {   # install.sh tells the Dockerfile where each agent comes from; goose's "latest" is the GitHub release
  local d
  inst() {   # inst <agent> <VAR=value>... : runs a copy of install.sh next to stub Dockerfiles
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"
    printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' > "$d/Dockerfile"; printf 'FROM node:9-slim\n' > "$d/Dockerfile.base"; printf 'a\n' > "$d/pod-environment.md"
    local a="$1"; shift
    RC=0; (cd "$d" && env HOME="$H" PATH="$BIN:$PATH" AGENT_POD_BASE_REPO=test.invalid/base ${1+"$@"} ./install.sh "$a" </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
  }
  inst claude; rc_is 0; logged '--build-arg AGENT_SRC=npm --build-arg AGENT_PKG=@anthropic-ai/claude-code --build-arg AGENT_VERSION=9.9.9 '
  inst goose; rc_is 0; logged '--build-arg AGENT=goose --build-arg AGENT_SRC=github --build-arg AGENT_PKG=aaif-goose/goose --build-arg AGENT_VERSION=9.9.9 --build-arg AGENT_CHANNEL=latest '
  not_logged 'CACHEBUST'; logged '^tag agent-pod:new-goose-[0-9]* agent-pod:goose$'
  # a pin is used as it is, without the "v" of the release tag, and is the channel label (so the image is not auto-updated)
  inst goose GOOSE_VERSION=v1.2.3; rc_is 0; logged '--build-arg AGENT_VERSION=1.2.3 --build-arg AGENT_CHANNEL=1.2.3 '
  inst goose GOOSE_VERSION=1.2.3; rc_is 0; logged '--build-arg AGENT_VERSION=1.2.3 --build-arg AGENT_CHANNEL=1.2.3 '
  # a pin of another agent does not reach goose
  inst goose CLAUDE_CODE_VERSION=1.0.0; rc_is 0; logged '--build-arg AGENT_VERSION=9.9.9 '
}

test_base_signature() {   # a pulled base is verified with the cosign container; a failed check means building it here
  local d H0 ID IMG DEF=ghcr.io/alfsch/agent-pod-base RUN='^run --rm --read-only --tmpfs /tmp -e HOME=/tmp '
  IMG="$(sed -n 's/^COSIGN_IMAGE=//p' "$INSTALLER")"
  sig() {   # sig <VAR=value>... : install.sh with the default repository (the only one that is checked)
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"
    printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' > "$d/Dockerfile"; printf 'FROM node:9-slim\n' > "$d/Dockerfile.base"
    printf 'a\n' > "$d/pod-environment.md"
    H0="$("$d/install.sh" --base-hash)"
    RC=0; (cd "$d" && env HOME="$H" PATH="$BIN:$PATH" "$@" ./install.sh claude </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
  }
  # the image is pinned by digest (a tag could be moved) and is cosign's own
  case "$IMG" in ghcr.io/sigstore/cosign/cosign:v*@sha256:????????????????????????????????????????????????????????????????) ;; *) fail "the cosign image is not pinned by digest: $IMG" ;; esac
  # verified: the signer is the publish workflow on main, and the base is used as pulled
  sig; rc_is 0; in_out 'signature verified'; not_logged '-f .*Dockerfile.base'
  # the whole command, character for character: the pinned image, the issuer, and an identity anchored to this repository,
  # this workflow and main (a looser pattern would accept a signature from another repository, workflow or branch)
  ID='^https://github.com/alfsch/ai-agent-pods/\.github/workflows/publish-base\.yaml@refs/heads/main$'
  grep -qxF -- "run --rm --read-only --tmpfs /tmp -e HOME=/tmp $IMG verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp $ID $DEF:$H0" "$STUB_LOG" \
    || fail "cosign was not run with the pinned image, the exact issuer and the signer identity"
  # by digest when Docker knows it
  sig STUB_REPO_DIGEST="$DEF@sha256:abc"; rc_is 0; logged " $DEF@sha256:abc\$"; not_logged "verify .* $DEF:$H0"
  # and the agent image is built from that digest, not from the tag that could be retargeted after the check
  logged "^build .*--build-arg BASE_IMAGE=$DEF@sha256:abc "; not_logged "BASE_IMAGE=$DEF:$H0"
  # without a digest the tag is all there is
  sig; rc_is 0; logged "^build .*--build-arg BASE_IMAGE=$DEF:$H0 "
  # another repository's digest is not taken for ours
  sig STUB_REPO_DIGEST="other/repo@sha256:abc"; rc_is 0; logged "verify .* $DEF:$H0\$"
  # a signature that does not match: the pulled image is not used, the base is built here, also when signatures are required
  sig STUB_COSIGN_FAIL=1; rc_is 0; in_out 'Signature check failed'; in_out 'building it here'; logged "^build .*-f .*Dockerfile.base -t $DEF:$H0 "
  sig STUB_COSIGN_FAIL=1 AGENT_POD_REQUIRE_SIGNED_BASE=1; rc_is 0; in_out 'Signature check failed'; logged '^build .*-f .*Dockerfile.base'
  # Docker cannot run cosign (no pull of its image): the base is used, unverified, and it says so; with
  # AGENT_POD_REQUIRE_SIGNED_BASE=1 it is not used
  local n
  for n in 125 126 127; do
    sig STUB_COSIGN_RUN_FAIL=$n; rc_is 0; in_out 'cosign could not run'; not_in_out 'Signature check failed'; not_logged '-f .*Dockerfile.base'
    logged "^build .*--build-arg BASE_IMAGE=$DEF:$H0 "
  done
  sig STUB_COSIGN_RUN_FAIL=125 AGENT_POD_REQUIRE_SIGNED_BASE=1; rc_is 0; in_out 'Not using the pulled image'; logged '^build .*-f .*Dockerfile.base'
  # cosign itself failing is never "could not run", whatever it prints: a Sigstore that cannot be reached, and a malformed
  # bundle whose error repeats a field of it (text such as "dial tcp" that an attacker could put there) are failed checks
  sig STUB_COSIGN_NET=1; rc_is 0; in_out 'Signature check failed'; not_in_out 'cosign could not run'; logged '^build .*-f .*Dockerfile.base'
  sig STUB_COSIGN_BUNDLE=1; rc_is 0; in_out 'Signature check failed'; not_in_out 'cosign could not run'; logged '^build .*-f .*Dockerfile.base'
  # another repository (a fork): not checked, used unless signatures are required
  sig AGENT_POD_BASE_REPO=test.invalid/base; rc_is 0; in_out 'not the default repository'; not_logged "$RUN"; not_logged '-f .*Dockerfile.base'
  sig AGENT_POD_BASE_REPO=test.invalid/base AGENT_POD_REQUIRE_SIGNED_BASE=1; rc_is 0; logged '^build .*-f .*Dockerfile.base'
  # a base that is built here (AGENT_POD_BUILD_BASE=1) or kept after a failed pull is not pulled, so not verified
  sig AGENT_POD_BUILD_BASE=1; rc_is 0; not_logged "$RUN"
  sig STUB_PULL_FAIL=1; rc_is 0; not_logged "$RUN"
}

test_verify_base_mode() {   # install.sh --verify-base <tag>: only the check, and a check that could not run fails too
  local d H0 DEF=ghcr.io/alfsch/agent-pod-base
  vb() {   # vb [args] [VAR=value]... : the mode (it is given the tag unless the first argument is --)
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"
    printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' > "$d/Dockerfile"; printf 'FROM node:9-slim\n' > "$d/Dockerfile.base"; printf 'a\n' > "$d/pod-environment.md"
    local args=(--verify-base tag1); [ "${1:-}" != -- ] || { args=(--verify-base); shift; }
    RC=0; (cd "$d" && env HOME="$H" PATH="$BIN:$PATH" "$@" ./install.sh ${args[@]+"${args[@]}"} </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
  }
  vb; rc_is 0; in_out 'signature verified'; logged "^pull $DEF:tag1\$"; logged "^run .*sigstore/cosign/cosign.* verify .* $DEF:tag1\$"
  not_logged '^build'   # nothing is built, no agent image either
  vb STUB_COSIGN_FAIL=1; rc_is 1; in_out 'Signature check failed'; not_logged '^build'
  # a check that could not run is not a pass here, however the normal install treats it
  vb STUB_COSIGN_RUN_FAIL=125; rc_is 1; in_out 'cosign could not run'; not_logged '^build'
  vb STUB_PULL_FAIL=1; rc_is 1; in_out 'Could not pull'; not_logged '^run .*cosign'
  vb --; rc_is 1; in_out 'needs the tag'; not_logged '^pull'
}

test_published_base_tag() {   # the base that is verified in CI exists in the registry, also right after a push to main
  local d t_tree t_c2 t_c1 t_head
  pt() {   # pt <VAR=value>... : the script in the repository of the case, with the tags in STUB_PUBLISHED published
    RC=0; (cd "$d" && env HOME="$H" PATH="$BIN:$PATH" REF=HEAD "$@" "$PUBTAG" >"$CASE/out" 2>"$CASE/err") || RC=$?
  }
  setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$INSTALLER" "$d/install.sh"; chmod +x "$d/install.sh"
  git_() { git -C "$d" -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false "$@"; }
  git_ init -q
  local n=0 tag
  for n in 1 2; do   # two commits that change the base, one that does not, then the one that has just been pushed
    printf 'FROM node:%s-slim\n' "$n" > "$d/Dockerfile.base"; printf 'env\n' > "$d/pod-environment.md"
    git_ add -A; git_ commit -q -m "base $n"; eval "t_c$n=$(cd "$d" && ./install.sh --base-hash)"
  done
  # many commits that do not touch the base (the history that is looked at is limited, so they must not count)
  for n in $(seq 1 31); do git_ commit -q --allow-empty -m "unrelated $n"; done
  printf 'FROM node:3-slim\n' > "$d/Dockerfile.base"; git_ add -A; git_ commit -q -m "base 3"; t_head="$(cd "$d" && ./install.sh --base-hash)"
  # published: used as it is
  pt STUB_PUBLISHED="$t_head $t_c2 $t_c1"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_head" ] || fail "not the tag of the tree: $(cat "$CASE/out")"
  # the tag is there but not its signature yet (the workflow signs after it pushes): the newest one that verifies
  pt STUB_PUBLISHED="$t_head $t_c2 $t_c1" STUB_UNSIGNED="$t_head"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_c2" ] || fail "an unsigned tag was chosen: $(cat "$CASE/out")"
  in_out 'skipping'
  # not yet published (the publish workflow runs next to the tests): the newest earlier one that is, not an older one
  pt STUB_PUBLISHED="$t_c2 $t_c1"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_c2" ] || fail "not the newest published tag: $(cat "$CASE/out")"
  pt STUB_PUBLISHED="$t_c1"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_c1" ] || fail "not the older published tag: $(cat "$CASE/out")"
  # the checked-out tree (a pull request) comes before anything of the branch
  printf 'FROM node:4-slim\n' > "$d/Dockerfile.base"; t_tree="$(cd "$d" && ./install.sh --base-hash)"
  pt STUB_PUBLISHED="$t_tree $t_head"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_tree" ] || fail "not the tag of the checked-out tree: $(cat "$CASE/out")"
  pt STUB_PUBLISHED="$t_head"; rc_is 0; [ "$(cat "$CASE/out")" = "$t_head" ] || fail "an unpublished tree did not fall back: $(cat "$CASE/out")"
  # nothing published
  pt STUB_PUBLISHED=; rc_is 1; in_out 'no published base image'
  tag="$(cat "$CASE/out")"; [ -z "$tag" ] || fail "a tag was printed although none is published: $tag"
}

test_agent_install_layer() {   # the install layer of Dockerfile runs the agent and reinstalls when it does not start
  local d body
  # the RUN instruction that installs the agent, as one shell command (its lines end with a backslash)
  body="$(awk '/^RUN for i in/ { f = 1 } f { print } f && !/\\$/ { exit }' "$DOCKERFILE" | sed 's/^RUN //; s/\\$//' | tr '\n' ' ')"
  [ -n "$body" ] || fail "no install layer found in $DOCKERFILE"
  layer() {   # layer <VAR=value>... : runs it with a stub npm, a stub agent that fails AGENT_FAILS times and no waiting
    setup_case; d="$CASE/stubs"; mkdir -p "$d"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "npm $*" >> "$STUB_LOG"' '[ "$1" != install ] || { n="$(cat "$STUB_DIR/npm-installs" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUB_DIR/npm-installs"; [ "$((n + 1))" -gt "${NPM_FAILS:-0}" ]; }' > "$d/npm"
    printf '%s\n' '#!/usr/bin/env bash' 'n="$(cat "$STUB_DIR/agent-runs" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUB_DIR/agent-runs"' \
      'echo "agent $*" >> "$STUB_LOG"; [ "$((n + 1))" -gt "${AGENT_FAILS:-0}" ] || { echo "no platform package found" >&2; exit 1; }' > "$d/claude"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "sleep $*" >> "$STUB_LOG"' > "$d/sleep"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "curl $*" >> "$STUB_LOG"; [ "${CURL_FAILS:-0}" != 0 ] || echo tarball' > "$d/curl"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "tar $*" >> "$STUB_LOG"; [ -n "$(cat)" ]' > "$d/tar"
    printf '%s\n' '#!/usr/bin/env bash' 'echo x86_64' > "$d/uname"
    chmod +x "$d/npm" "$d/claude" "$d/sleep" "$d/curl" "$d/tar" "$d/uname"
    RC=0; env PATH="$d:$PATH" AGENT_PKG=pkg AGENT_VERSION=1.2.3 AGENT=claude "$@" sh -c "$body" >"$CASE/out" 2>"$CASE/err" || RC=$?
  }
  installs() { grep -c '^npm install' "$STUB_LOG" || true; }
  # a healthy install: once, no reinstall
  layer; rc_is 0; [ "$(installs)" = 1 ] || fail "a healthy install ran npm install $(installs) times"; not_logged '^npm uninstall'; not_logged '^sleep'
  logged '^npm install -g pkg@1.2.3$'; logged '^agent --version$'
  # the agent does not start the first time: the package is removed and installed again, then it works
  layer AGENT_FAILS=1; rc_is 0; [ "$(installs)" = 2 ] || fail "expected 2 installs, got $(installs)"; logged '^npm uninstall -g pkg$'; in_out 'Attempt 1 of installing pkg@1.2.3 failed'
  [ "$(grep -v '^sleep' "$STUB_LOG" | tr '\n' ',')" = 'npm install -g pkg@1.2.3,agent --version,npm uninstall -g pkg,npm install -g pkg@1.2.3,agent --version,' ] \
    || fail "the calls were not install, run, uninstall, install, run"
  # npm itself fails the first time: also tried again
  layer NPM_FAILS=1; rc_is 0; [ "$(installs)" = 2 ] || fail "expected 2 installs after an npm failure, got $(installs)"
  # a github agent comes from the musl release tarball of its repository, not from npm
  layer AGENT_SRC=github AGENT_PKG=o/r AGENT_VERSION=1.2.3 AGENT=claude; rc_is 0; not_logged '^npm'
  logged '^curl -fsSL https://github.com/o/r/releases/download/v1.2.3/claude-x86_64-unknown-linux-musl.tar.gz$'; logged '^tar -xz -C /usr/local/bin ./claude$'
  # a version that install.sh could not resolve stays "latest" and must not become a tag "vlatest"
  layer AGENT_SRC=github AGENT_PKG=o/r AGENT_VERSION=latest AGENT=claude; rc_is 0
  logged '^curl -fsSL https://github.com/o/r/releases/latest/download/claude-x86_64-unknown-linux-musl.tar.gz$'; not_logged 'vlatest'
  layer AGENT_SRC=github AGENT_FAILS=1; rc_is 0; [ "$(grep -c '^curl' "$STUB_LOG")" = 2 ] || fail "a github install that did not start was not repeated"
  layer AGENT_SRC=github CURL_FAILS=99; [ "$RC" != 0 ] || fail "a github install whose download fails succeeded"
  # it never starts: three tries, then the build fails
  layer AGENT_FAILS=99; [ "$RC" != 0 ] || fail "a build with an agent that never starts succeeded"
  [ "$(installs)" = 3 ] || fail "expected 3 installs, got $(installs)"; in_out 'Attempt 3 of installing pkg@1.2.3 failed'
}

test_publish_signs_created_digest() {   # the workflow signs the digest of the manifest it created, never what the tag points at later
  local d create sign index want
  step_body() {   # step_body <step name>: the run: block of that step of the workflow
    awk -v name="$1" '
      $0 ~ "- name: " name "$" { f = 1; next }
      f && /^        run: \|$/ { r = 1; next }
      f && r && /^          / { sub(/^          /, ""); print; next }
      f && r { exit }' "$WORKFLOW"
  }
  create="$(step_body 'Create the multi-arch tag')"; sign="$(step_body 'Sign the image')"
  [ -n "$create" ] && [ -n "$sign" ] || fail "the create or the sign step was not found in $WORKFLOW"
  index='{"schemaVersion":2,"manifests":["a","b"]}'
  want="sha256:$(printf '%s' "$index" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
  run_steps() {   # run_steps <VAR=value>... : the steps as GitHub runs them (bash -e), the second one with the first one's output
    setup_case; d="$CASE/wf"; mkdir -p "$d/digests"; : > "$d/digests/aaa"; : > "$d/digests/bbb"; : > "$d/output"
    RC=0; env PATH="$BIN:$PATH" IMAGE=img TAG=t RUNNER_TEMP="$d" GITHUB_OUTPUT="$d/output" STUB_INDEX_JSON="$index" "$@" bash -e -c "$create" >"$CASE/out" 2>"$CASE/err" || RC=$?
    SIGNED=; [ "$RC" != 0 ] || { DIGEST="$(sed -n 's/^digest=//p' "$d/output")"; env PATH="$BIN:$PATH" IMAGE=img DIGEST="$DIGEST" bash -e -c "$sign" >>"$CASE/out" 2>>"$CASE/err" && SIGNED=1; }
  }
  run_steps; rc_is 0; [ -n "$SIGNED" ] || fail "the sign step failed"
  [ "$(cat "$d/output")" = "digest=$want" ] || fail "the digest was not the sha256 of the manifest that is pushed ($(cat "$d/output"), expected digest=$want)"
  logged '^buildx imagetools create --dry-run -t img:t img@sha256:aaa img@sha256:bbb$'
  order '^buildx imagetools create --dry-run' '^buildx imagetools create -t img:t img@sha256:aaa img@sha256:bbb$' "^buildx imagetools inspect img@$want\$" "^cosign sign --yes img@$want\$"
  # the tag is not looked up (it is the one thing that can have moved), so what is signed cannot be anything else
  not_logged 'imagetools inspect img:t'; not_logged 'sha256:replaced'
  # the pushed manifest is not the one that was computed: nothing is signed
  run_steps STUB_INSPECT_FAIL=1; [ "$RC" != 0 ] || fail "a digest that is not in the registry did not fail the create step"
  [ ! -s "$d/output" ] || fail "a digest was handed on although the manifest was not in the registry"; not_logged '^cosign'
}

# The world of the prune tests: img <n> <age in hours> <child digest numbers>... registers the image with the hash tag
# H<n> (index digest n; PRUNE_TAG=<tag> gives it that tag instead), its signature version (tag SIG<n>) and the children it lists; untagged <id> <age> adds a
# version nobody tags (a child, or an orphan). PRUNE_TOUCH_ID=<id> PRUNE_TOUCH_H=<hours> make that version's updated_at that
# many hours old while its created_at stays as it is (a tag that was pushed again). Ids of the untagged versions are their digest numbers.
prune_world() { SPEC=; CH='{}'; NOWV=2000000000; command -v jq >/dev/null 2>&1 || fail "the prune tests need jq"; }
prune_dg() { printf 'sha256:%064d' "$1"; }
prune_sig() { printf 'sha256-%064d.sig' "$1"; }
prune_img() {
  local n="$1" age="$2" k kids='[]'; shift 2
  SPEC="$SPEC$n $(prune_dg "$n") ${PRUNE_TAG:-H$n} $age"$'\n'"$((100 + n)) $(prune_dg $((5000 + n))) SIG$n $age"$'\n'
  for k in "$@"; do kids="$(jq -c --arg x "$(prune_dg "$k")" '. + [$x]' <<<"$kids")"; done
  CH="$(jq -c --arg i "$(prune_dg "$n")" --argjson k "$kids" '. + {($i): $k}' <<<"$CH")"
}
prune_untagged() { SPEC="$SPEC$1 $(prune_dg "$1") - $2"$'\n'; }
prune_tagged() { SPEC="$SPEC$1 $(prune_dg "$1") $2 $3"$'\n'; }   # prune_tagged <id> <tag> <age>: a version with a tag of its own
prune_versions() {   # the package versions as the API returns them, from SPEC
  local id dg tags age out=
  while read -r id dg tags age; do
    [ -n "$id" ] || continue
    case "$tags" in
      -) tags= ;;
      H[0-9]*) tags="$(printf '%016x' "${tags#H}")" ;;
      SIG[0-9]*) tags="$(prune_sig "${tags#SIG}")" ;;
    esac
    out="$out$id	$dg	$age	$tags"$'\n'
  done <<<"$SPEC"
  printf '%s' "$out" | jq -Rn --argjson now "$NOWV" --arg touch_id "${PRUNE_TOUCH_ID:-}" --argjson touch_h "${PRUNE_TOUCH_H:-0}" '[inputs | split("\t") | {id: (.[0] | tonumber), name: .[1],
    created_at: ($now - (.[2] | tonumber) * 3600 | todate), updated_at: ($now - (.[2] | tonumber) * 3600 | todate), metadata: {container: {tags: (.[3] | split(" ") | map(select(length > 0)))}}}]
    | map(if (.id | tostring) == $touch_id then .updated_at = ($now - $touch_h * 3600 | todate) else . end)'
}
prune_decide() {   # prune_decide <VAR=value>... : the plan for the world, in OUT; RC is the exit code
  RC=0; OUT="$(jq -n --argjson v "$(prune_versions)" --argjson c "$CH" '{versions: $v, children: $c}' | env NOW="$NOWV" "$@" "$PRUNE" decide 2>"$CASE/err")" || RC=$?
  printf '%s\n' "$OUT" > "$CASE/out"
}
prune_is() {   # prune_is <keep|delete> <id>...
  local want="$1" id got; shift
  for id in "$@"; do
    got="$(awk -F'\t' -v i="$id" '$2 == i { print $1 }' <<<"$OUT")"
    [ "$got" = "$want" ] || fail "version $id: ${got:-no verdict}, expected $want"
  done
}

test_prune_decide() {   # whole images are kept or removed: the children, the signature, a child that two images share
  setup_case
  # A: two tags are kept (KEEP_TAGS=2), the older ones go with their signatures and their children
  prune_world
  prune_img 1 24 1001 1002; prune_img 2 240 2001 2002; prune_img 3 960 2002 3001; prune_img 4 2160 4001 4002
  prune_untagged 1001 24; prune_untagged 1002 24; prune_untagged 2001 240; prune_untagged 2002 240; prune_untagged 3001 960
  prune_untagged 4001 2160; prune_untagged 4002 2160
  PRUNE_TAG=latest prune_img 5 3000 5001; prune_untagged 5001 3000   # a tag the workflow does not make: kept whole
  prune_untagged 6 2; prune_untagged 7 48          # an orphan inside and one outside the grace period
  prune_tagged 108 "$(prune_sig 99)" 100           # the signature of an index that is not there
  prune_decide KEEP_TAGS=2 KEEP_DAYS=30 GRACE_HOURS=24; rc_is 0
  prune_is keep 1 101 1001 1002 2 102 2001 2002     # the newest two images, whole
  prune_is delete 3 103 3001 4 104 4001 4002        # the older ones, whole, except what a kept image shares: 2002 above
  prune_is keep 5 105 5001                          # nobody removes a tag somebody pushed on purpose, nor its signature or children
  prune_is keep 6; prune_is delete 7                # the grace period
  prune_is delete 108                               # a signature of an image that is gone
  # B: a tag beyond KEEP_TAGS stays while it is younger than KEEP_DAYS
  prune_world; prune_img 1 24; prune_img 2 120; prune_img 3 960
  prune_decide KEEP_TAGS=1 KEEP_DAYS=30; rc_is 0; prune_is keep 1 2 101 102; prune_is delete 3 103
  # C: the newest tag stays whatever its age
  prune_world; prune_img 1 2160; prune_img 2 2880
  prune_decide KEEP_TAGS=1 KEEP_DAYS=30; rc_is 0; prune_is keep 1 101; prune_is delete 2 102
  # H: a tag pushed again is as young as that push, not as old as the version it points at
  prune_world; prune_img 1 24; prune_img 2 2880; prune_img 3 2880
  PRUNE_TOUCH_ID=2 PRUNE_TOUCH_H=48 prune_decide KEEP_TAGS=1 KEEP_DAYS=30; rc_is 0; prune_is keep 1 2 101; prune_is delete 3 103
  # D: nothing is decided without a hash-tagged version (a listing that failed must not delete the lot)
  prune_world; prune_untagged 7 48; prune_tagged 108 "$(prune_sig 99)" 100
  prune_decide; [ "$RC" != 0 ] || fail "a package without a hash-tagged version was decided on"
  ! grep -q delete "$CASE/out" || fail "a plan was printed for a package without a hash-tagged version"
  # E: nor when the children of a kept index are unknown; those of an index that goes do not matter
  prune_world; prune_img 1 24 1001; prune_img 2 2160 2001; prune_untagged 1001 24; prune_untagged 2001 2160
  CH="$(jq -c --arg i "$(prune_dg 1)" 'del(.[$i])' <<<"$CH")"
  prune_decide KEEP_TAGS=1 KEEP_DAYS=30; [ "$RC" != 0 ] || fail "the children of a kept index were unknown and a plan was made"
  CH="$(jq -c --arg i "$(prune_dg 2)" 'del(.[$i])' <<<"$CH")"; prune_img 1 24 1001; prune_decide KEEP_TAGS=1 KEEP_DAYS=30
  rc_is 0; prune_is keep 1001; prune_is delete 2 2001
  # G: nor when the children of a custom-tagged image are unknown: it is kept, and so are they
  prune_world; prune_img 1 24 1001; PRUNE_TAG=latest prune_img 5 3000 5001; prune_untagged 1001 24; prune_untagged 5001 3000
  CH="$(jq -c --arg i "$(prune_dg 5)" 'del(.[$i])' <<<"$CH")"
  prune_decide KEEP_TAGS=1 KEEP_DAYS=30; [ "$RC" != 0 ] || fail "the children of a custom-tagged image were unknown and a plan was made"
  # F: at least one tag is kept
  prune_world; prune_img 1 2160 1001; prune_untagged 1001 2160
  prune_decide KEEP_TAGS=0 KEEP_DAYS=30; [ "$RC" != 0 ] || fail "KEEP_TAGS=0 was accepted"
}

test_prune_run() {   # the script lists, decides, and deletes only when DRY_RUN is exactly false
  local d bin leaf
  setup_case; d="$CASE/prune"; bin="$d/bin"; mkdir -p "$bin" "$d/manifests"
  prune_world; prune_img 1 24 1001; prune_img 2 2880 2001; prune_untagged 1001 24; prune_untagged 2001 2880
  PRUNE_TAG=latest prune_img 3 2880 3001; prune_untagged 3001 2880; prune_untagged 3002 2880   # a custom-tagged image with old children, nested: kept whole
  local versions; versions="$(prune_versions)"
  jq -c '.[:3]' <<<"$versions" > "$d/page1.json"; jq -c '.[3:]' <<<"$versions" > "$d/page2.json"   # two pages, as --paginate prints them
  printf '{"manifests":[{"digest":"%s"}]}' "$(prune_dg 1001)" > "$d/manifests/$(prune_dg 1)"
  printf '{"manifests":[{"digest":"%s"}]}' "$(prune_dg 2001)" > "$d/manifests/$(prune_dg 2)"
  printf '{"manifests":[{"digest":"%s"}]}' "$(prune_dg 3001)" > "$d/manifests/$(prune_dg 3)"
  printf '{"manifests":[{"digest":"%s"}]}' "$(prune_dg 3002)" > "$d/manifests/$(prune_dg 3001)"   # an index below an index
  for leaf in 1001 2001 3002; do printf '{"schemaVersion":2}' > "$d/manifests/$(prune_dg "$leaf")"; done
  cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  *"-X DELETE"*) last="${!#}"; [ "${STUB_DELETE_FAIL:-}" = "${last##*/}" ] && exit 1; exit 0 ;;
  *--paginate*) cat "$STUB_DIR/page1.json" "$STUB_DIR/page2.json" ;;
  *) exit 1 ;;
esac
STUB
  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.log"
[ "$1 $2 $3" = "buildx imagetools inspect" ] || exit 1
ref="${!#}"; digest="${ref##*@}"; [ "${STUB_MANIFEST_FAIL:-}" != "$digest" ] || exit 1
cat "$STUB_DIR/manifests/$digest"
STUB
  chmod +x "$bin/gh" "$bin/docker"
  pr() {   # pr <VAR=value>... : the script as the workflow runs it, with a stubbed gh and docker; DELETE calls are in gh.log
    : > "$d/gh.log"; : > "$d/docker.log"; RC=0
    env PATH="$bin:$PATH" STUB_DIR="$d" GITHUB_REPOSITORY_OWNER=Owner NOW="$NOWV" KEEP_TAGS=1 KEEP_DAYS=30 "$@" "$PRUNE" >"$CASE/out" 2>"$CASE/err" || RC=$?
  }
  deletes() { grep -c -- '-X DELETE' "$d/gh.log" || true; }
  # no DRY_RUN: the safe default, the plan is printed and nothing is deleted
  pr; rc_is 0; [ "$(deletes)" = 0 ] || fail "a run without DRY_RUN deleted"
  in_out 'delete +2 '; in_out 'keep +1 '; in_out 'dry run: nothing deleted'
  grep -q 'ghcr.io/owner/agent-pod-base@sha256:' "$d/docker.log" || fail "the manifest was not read from the image of the lower-cased owner"
  # anything but exactly false is a dry run
  pr DRY_RUN=true; rc_is 0; [ "$(deletes)" = 0 ] || fail "DRY_RUN=true deleted"
  pr DRY_RUN=no; rc_is 0; [ "$(deletes)" = 0 ] || fail "DRY_RUN=no deleted"
  # false deletes what the plan says, the old image whole, over the API path of the owner, and nothing else
  pr DRY_RUN=false; rc_is 0
  [ "$(deletes)" = 3 ] || fail "expected 3 deletions, got $(deletes)"
  for id in 2 102 2001; do grep -q -- "-X DELETE /users/Owner/packages/container/agent-pod-base/versions/$id\$" "$d/gh.log" || fail "version $id was not deleted"; done
  for id in 3 103 3001 3002; do ! grep -q -- "-X DELETE .*/versions/$id\$" "$d/gh.log" || fail "version $id of the custom-tagged image was deleted"; done
  # the manifest list of a kept index cannot be read: nothing is deleted
  pr DRY_RUN=false STUB_MANIFEST_FAIL="$(prune_dg 1)"; [ "$RC" != 0 ] || fail "a kept index with an unreadable manifest list did not stop the run"
  [ "$(deletes)" = 0 ] || fail "something was deleted although the children of a kept index were unknown"
  # nor when the manifest list of the custom-tagged image cannot be read
  pr DRY_RUN=false STUB_MANIFEST_FAIL="$(prune_dg 3)"; [ "$RC" != 0 ] || fail "a custom-tagged image with an unreadable manifest list did not stop the run"
  [ "$(deletes)" = 0 ] || fail "something was deleted although the children of a custom-tagged image were unknown"
  # nor when something below it cannot be read
  pr DRY_RUN=false STUB_MANIFEST_FAIL="$(prune_dg 3002)"; [ "$RC" != 0 ] || fail "an unreadable manifest below a custom-tagged image did not stop the run"
  [ "$(deletes)" = 0 ] || fail "something was deleted although a manifest below a custom-tagged image was unknown"
  # one deletion fails: the others are still tried, and the run fails
  pr DRY_RUN=false STUB_DELETE_FAIL=102; rc_is 1; [ "$(deletes)" = 3 ] || fail "a failed deletion stopped the others"
}

# ---- mutants: each must make its test fail, proving the test discriminates -----------------------------
mutate() {   # mutate <test> <old> <new> [install.sh]   (literal replacement in a copy of the launcher, or of install.sh)
  local test="$1" old="$2" new="$3" file="${4:-agent-pod}" src var=LAUNCHER; src="$(cat "$ROOT/$file"; echo x)"; src="${src%x}"
  case "$file" in install.sh) var=INSTALLER ;; uninstall.sh) var=UNINSTALLER ;; tests/integration.sh) var=ITEST ;; tests/published-base-tag.sh) var=PUBTAG ;; .github/scripts/prune-base-images.sh) var=PRUNE ;; Dockerfile) var=DOCKERFILE ;; .github/workflows/publish-base.yaml) var=WORKFLOW ;; esac
  declare -F "$test" >/dev/null || { echo "  ERROR  mutant names an unknown test: $test"; return 1; }
  [[ "$src" == *"$old"* ]] || { echo "  ERROR  mutant for $test does not apply: $old"; return 1; }
  # the replacement is quoted: in Bash 5.2 an unquoted & in it stands for the text that was matched
  printf '%s' "${src/"$old"/"$new"}" > "$T/mutant"; chmod +x "$T/mutant"
  if ( export "$var=$T/mutant"; "$0" --inner "$test" >/dev/null 2>&1 ); then
    echo "  SURVIVED  $test passes without: ${old%%$'\n'*}"; return 1
  fi
  echo "  killed    $test fails without: ${old%%$'\n'*}"
}
run_mutants() {
  local rc=0
  mutate test_sequence      $'  ${DOCKER:+--init} \\\n' '' || rc=1
  mutate test_rootless_user 'POD_USER=0:0' 'POD_USER="$(id -u):$(id -g)"' || rc=1
  mutate test_rootless_user '[ "${POD_USER%%:*}" != 0 ] || [ -z "$A_ROOT_ENV" ]' 'true' || rc=1
  mutate test_rootless_user 'A_FORWARD=; A_ROOT_ENV=IS_SANDBOX=1' 'A_FORWARD=; A_ROOT_ENV=' || rc=1
  mutate test_rootless_user 'A_FORWARD="COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN"; A_ROOT_ENV=' 'A_FORWARD="COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN"; A_ROOT_ENV=IS_SANDBOX=1' || rc=1
  mutate test_rootless_default_daemon 'export DOCKER_HOST="$ROOTFUL_HOST"; ' '' || rc=1
  mutate test_rootless_default_daemon $'  unset DOCKER_CONTEXT ' ' #' || rc=1
  mutate test_uninstall_two_daemons 'DAEMONS+=(unix:///var/run/docker.sock)' 'true' uninstall.sh || rc=1
  mutate test_uninstall_two_daemons '  if [[ "$_sec2" == *name=rootless* ]]; then' '  if false; then' uninstall.sh || rc=1
  mutate test_uninstall_two_daemons 'if [[ "$_sec" == *name=rootless* ]]; then' 'if true; then' uninstall.sh || rc=1
  mutate test_uninstall_two_daemons 'docker volume rm $_vols >/dev/null 2>&1 ||' 'true ||' uninstall.sh || rc=1
  mutate test_uninstall_two_daemons 'No rootful Docker daemon answers at' 'Rootful daemon missing at' uninstall.sh || rc=1
  mutate test_uninstall_two_daemons 'run: env -u DOCKER_CONTEXT DOCKER_HOST=' 'run: DOCKER_HOST=' uninstall.sh || rc=1
  mutate test_integration_daemons 'SD_ENV=(env -u DOCKER_CONTEXT DOCKER_HOST="$_sdhost"); ' 'true; ' tests/integration.sh || rc=1
  mutate test_integration_daemons 'sd() { ${SD_ENV[@]+"${SD_ENV[@]}"} docker "$@"; }' 'sd() { docker "$@"; }' tests/integration.sh || rc=1
  mutate test_cache_conflict 'a leftover from a killed session: $DOCKER_HINT rm -f $DIND_NAME}"' 'a leftover from a killed session: docker rm -f $DIND_NAME}"' || rc=1
  mutate test_cache_conflict '  DOCKER_HINT="env -u DOCKER_CONTEXT DOCKER_HOST=$ROOTFUL_HOST docker"' '  DOCKER_HINT=docker' || rc=1
  mutate test_integration_daemons 'env -u DOCKER_CONTEXT DOCKER_HOST="$_sdhost" docker info' 'DOCKER_HOST="$_sdhost" docker info' tests/integration.sh || rc=1
  mutate test_integration_daemons '&& ! grep -q name=rootless <<<"$_sdsec"' '&& true' tests/integration.sh || rc=1
  mutate test_integration_daemons "if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q name=rootless; then" 'if true; then' tests/integration.sh || rc=1
  mutate test_rootless_default_daemon 'if [ -n "${DOCKER:-}" ]; then case "$_sec" in *name=rootless*)' 'if true; then case "$_sec" in *name=rootless*)' || rc=1
  mutate test_rootless_default_daemon '*name=rootless*) die "DOCKER=1 does not work' '*name=nothing*) die "DOCKER=1 does not work' || rc=1
  mutate test_rootless_user '*name=rootless*) POD_USER=0:0' '*name=nothing*) POD_USER=0:0' || rc=1
  mutate test_sequence      'docker run -d --privileged --init \' 'docker run -d --privileged \' || rc=1
  mutate test_sequence      $'  docker network rm "$DIND_NET" >/dev/null 2>&1 || true\n' '' || rc=1
  mutate test_option_validation 'die "$_v must be 1 (or unset), not '"'"'${!_v}'"'"'."' 'true' || rc=1
  mutate test_cache_new     'DIND_NAME="agent-pod-dind-cache-$_hash"' 'DIND_NAME="agent-pod-dind-$RUN_ID"' || rc=1
  mutate test_host_uid_skipped '[ "$(id -u)" != 1000 ] && [ "$(id -u)" != 0 ]' '[ "$(id -u)" != 0 ]' || rc=1
  mutate test_host_uid_skipped ' && [ "$(id -u)" != 0 ]; then' '; then' || rc=1
  mutate test_host_uid_skipped '[ -z "$_dind_image_set" ] && ' '' || rc=1
  mutate test_host_uid_skipped '[ "$(uname -s)" = Linux ] && ' '' || rc=1
  mutate test_host_uid      'if [ -z "$(docker image ls -q "$DIND_IMAGE" 2>/dev/null)" ]; then' 'if true; then' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo "$(id -u):$(id -g)"' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo 1000:1000' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo "${DIND_UID:-1000}:1000"' || rc=1
  mutate test_host_uid_subid_range '(DIND_UID >= _sub && DIND_UID < _sub + 65536)' '0' || rc=1
  mutate test_host_uid_subid_range '(DIND_GID >= _sub && DIND_GID < _sub + 65536)' '0' || rc=1
  mutate test_host_uid_subid_range 'DIND_UID < _sub + 65536' 'DIND_UID < _sub + 1' || rc=1
  mutate test_host_uid_subid_range 'DIND_GID < _sub + 65536' 'DIND_GID < _sub + 1' || rc=1
  mutate test_host_uid_subid_range ' | tee /etc/subuid > /etc/subgid' ' > /etc/subuid' || rc=1
  mutate test_prune         '-mmin +$(( max_days * 1440 ))' '-mmin +0' || rc=1
  mutate test_prune         'elif grep -qi '"'"'no such volume'"'"' <<<"$out"; then' 'elif false; then' || rc=1
  mutate test_double_term_startup $'  trap \'\' INT TERM HUP\n' '' || rc=1
  mutate test_stop_signal   'STOP_FLAGS=(--stop-signal=SIGHUP)' 'STOP_FLAGS=()' || rc=1
  mutate test_stop_signal   '[ "$#" -eq 0 ] || {' 'true || {' || rc=1
  mutate test_stop_signal   '[ "$#" -eq 1 ] && [ "$1" = bash ]' '[ "$1" = bash ]' || rc=1
  mutate test_term_before_pod_pid $'  [ -z "$STOP_REQUESTED" ] || stop_pod\n' '' || rc=1
  mutate test_term_during_pod_creation $'  [ -z "$STOP_REQUESTED" ] || stop_pod\n' '' || rc=1
  mutate test_term_before_pod_pid $'  STOP_REQUESTED=1\n' '' || rc=1
  mutate test_stop_while_client_drains 'elif [ -n "$POD_SEEN" ]; then POD_GONE=1' 'elif false; then POD_GONE=1' || rc=1
  mutate test_stop_while_client_drains $'  [ -z "$POD_GONE" ] || return 0\n' '' || rc=1
  mutate test_stop_error_is_retried "elif ! grep -qi 'no such container' <<<\"\$_out\"; then :" 'elif false; then :' || rc=1
  mutate test_stop_after_natural_exit '[ -n "$POD_PID" ] && [ -z "$POD_KILLED" ]; then POD_KILLED=1;' '[ -n "$POD_PID" ]; then' || rc=1
  mutate test_term_running  'trap stop_pod TERM INT HUP' 'trap "" TERM INT HUP' || rc=1
  mutate test_int_hup_running 'trap stop_pod TERM INT HUP' 'trap stop_pod TERM' || rc=1
  mutate test_int_hup_startup "trap 'exit 130' INT" "trap 'exit 1' INT" || rc=1
  mutate test_int_hup_startup "trap 'exit 129' HUP" "trap 'exit 1' HUP" || rc=1
  mutate test_agent_selection 'case "$SELF" in claude-pod) AGENT=claude ;; copilot-pod) AGENT=copilot ;; goose-pod) AGENT=goose ;; esac' ':' || rc=1
  mutate test_agent_selection ' goose-pod) AGENT=goose ;;' '' || rc=1
  mutate test_agent_selection 'claude|copilot|goose) AGENT="$1"' 'claude|copilot) AGENT="$1"' || rc=1
  mutate test_agent_selection '[ -L "$_src" ]' 'false' || rc=1
  mutate test_agent_flags   'A_NOUPDATE=COPILOT_AUTO_UPDATE=false' 'A_NOUPDATE=DISABLE_AUTOUPDATER=1' || rc=1
  mutate test_agent_flags   'A_FORWARD="COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN"' 'A_FORWARD=' || rc=1
  mutate test_agent_flags   'A_STATE_DIR="$HOME/.copilot-pod"' 'A_STATE_DIR="$HOME/.claude-pod"' || rc=1
  mutate test_agent_flags   ' GOOSE_DISABLE_KEYRING=1 GH_CONFIG_DIR=/home/agent-pod/.config/gh"' ' GH_CONFIG_DIR=/home/agent-pod/.config/gh"' || rc=1
  mutate test_agent_flags   ' GH_CONFIG_DIR=/home/agent-pod/.config/gh"' '"' || rc=1
  mutate test_agent_flags   'A_FORWARD="GOOSE_PROVIDER ' 'A_FORWARD="' || rc=1
  mutate test_agent_flags   '${A_CFG_FILE:+-v "$A_CFG_PATH:/home/agent-pod/$A_CFG_FILE"}' '-v "$A_CFG_PATH:/home/agent-pod/$A_CFG_FILE"' || rc=1
  mutate test_agent_flags   '${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}' '' || rc=1
  mutate test_profile       '  A_KEY="$AGENT-$AGENT_POD_PROFILE"; A_STATE_DIR="$A_STATE_DIR-$AGENT_POD_PROFILE"' '  A_KEY="$AGENT"; A_STATE_DIR="$A_STATE_DIR-$AGENT_POD_PROFILE"' || rc=1
  mutate test_profile       '  A_KEY="$AGENT-$AGENT_POD_PROFILE"; A_STATE_DIR="$A_STATE_DIR-$AGENT_POD_PROFILE"' '  A_KEY="$AGENT-$AGENT_POD_PROFILE"; A_STATE_DIR="$A_STATE_DIR"' || rc=1
  mutate test_profile       'if [ -n "${AGENT_POD_PROFILE:-}" ]; then' 'if false; then' || rc=1
  mutate test_profile       'A_CFG_PATH="$A_CFG_HOME/$A_KEY.json"' 'A_CFG_PATH="$A_CFG_HOME/$AGENT.json"' || rc=1
  mutate test_profile       '  mkdir -p "$A_CFG_HOME/$A_KEY-${_d##*/}"; chmod' '  mkdir -p "$A_CFG_HOME/$AGENT-${_d##*/}"; chmod' || rc=1
  mutate test_profile       '  EXTRA_MOUNTS+=(-v "$A_CFG_HOME/$A_KEY-' '  EXTRA_MOUNTS+=(-v "$A_CFG_HOME/$AGENT-' || rc=1
  mutate test_profile       'elif [ -f "$A_CFG_HOME/$A_KEY.gitconfig" ]; then' 'elif false; then' || rc=1
  mutate test_profile       'elif [ -f "$A_CFG_HOME/$AGENT.gitconfig" ]; then' 'elif false; then' || rc=1
  mutate test_profile       '_writable=("$PWD" "$A_STATE_DIR"); for _d in $A_EXTRA_DIRS; do _writable+=("$A_CFG_HOME/$A_KEY-' '_writable=("$PWD" "$A_STATE_DIR"); for _d in $A_EXTRA_DIRS; do _writable+=("$A_CFG_HOME/$AGENT-' || rc=1
  mutate test_profile       '  for _d in $A_EXTRA_DIRS; do _wr+=("$(cd "$A_CFG_HOME/$A_KEY-' '  for _d in $A_EXTRA_DIRS; do _wr+=("$(cd "$A_CFG_HOME/$AGENT-' || rc=1
  mutate test_profile       '""|*[!A-Za-z0-9_-]*|[!A-Za-z0-9]*) return 1' '""|[!A-Za-z0-9]*) return 1' || rc=1
  mutate test_profile       '""|*[!A-Za-z0-9_-]*|[!A-Za-z0-9]*) return 1' '""|*[!A-Za-z0-9_-]*) return 1' || rc=1
  mutate test_profile       '[ "${#1}" -le 32 ]' '[ "${#1}" -le 3200 ]' || rc=1
  mutate test_profile       '[ "${#1}" -le 32 ]' '[ "${#1}" -le 31 ]' || rc=1
  mutate test_profile       '""|*[!A-Za-z0-9_-]*|[!A-Za-z0-9]*) return 1' '""|[!A-Za-z0-9]*) return 1' uninstall.sh || rc=1
  mutate test_profile       '""|*[!A-Za-z0-9_-]*|[!A-Za-z0-9]*) return 1' '""|*[!A-Za-z0-9_-]*) return 1' uninstall.sh || rc=1
  mutate test_profile       'case "$1" in ""|' 'case "$1" in ' uninstall.sh || rc=1
  mutate test_profile       '[ "${#1}" -le 32 ]' '[ "${#1}" -le 3200 ]' uninstall.sh || rc=1
  mutate test_profile       '[ "${#1}" -le 32 ]' '[ "${#1}" -le 31 ]' uninstall.sh || rc=1
  mutate test_profile       'valid_profile_name "$AGENT_POD_PROFILE" || die' 'true || die' || rc=1
  mutate test_profile       'valid_profile_name "${_n#*-pod-}" || continue' 'true || continue' uninstall.sh || rc=1
  mutate test_profile       '_n="${_d##*/}"' '_n="$(basename "$_d")"' uninstall.sh || rc=1
  mutate test_profile       '"$HOME"/.claude-pod-* "$HOME"/.copilot-pod-* "$HOME"/.goose-pod-*; do' '"$HOME"/.copilot-pod-* "$HOME"/.goose-pod-*; do' uninstall.sh || rc=1
  mutate test_profile       '"$HOME"/.claude-pod-* "$HOME"/.copilot-pod-* "$HOME"/.goose-pod-*; do' '"$HOME"/.claude-pod-* "$HOME"/.goose-pod-*; do' uninstall.sh || rc=1
  mutate test_profile       '"$HOME"/.claude-pod-* "$HOME"/.copilot-pod-* "$HOME"/.goose-pod-*; do' '"$HOME"/.claude-pod-* "$HOME"/.copilot-pod-*; do' uninstall.sh || rc=1
  mutate test_profile       '  [ -d "$_d" ] || continue' '  : || continue' uninstall.sh || rc=1
  mutate test_skills_dir    '${SKILLS_MOUNT[@]+"${SKILLS_MOUNT[@]}"}' '' || rc=1
  mutate test_skills_dir    '$(basename "$_k"):ro")' '$(basename "$_k")")' || rc=1
  mutate test_skills_dir    '    _r="$(cd "$_k" && pwd -P)" || continue' '    _r="${_k%/}"' || rc=1
  mutate test_skills_dir    '    [ -f "${_k}SKILL.md" ] || continue' '    :' || rc=1
  mutate test_skills_dir    '  [ -d "$AGENT_POD_SKILLS_DIR" ] || die' '  : || die' || rc=1
  mutate test_skills_dir    '  [ "${#SKILLS_MOUNT[@]}" -gt 0 ] || die' '  : || die' || rc=1
  mutate test_skills_dir    '  case "$A_SKILLS_TARGET" in "$A_CFG_DIR"/*) mkdir -p "$A_STATE_DIR/${A_SKILLS_TARGET#"$A_CFG_DIR"/}" ;; esac' '  :' || rc=1
  mutate test_skills_dir    '      case "$1/" in "$w"/*) die' '      case "$1/" in "$w"/_never_) die' || rc=1
  mutate test_skills_dir    '      case "$w/" in "$1"/*) die' '      case "$w/" in "$1"/_never_) die' || rc=1
  mutate test_skills_dir    '_wr=(); for _w in "$PWD" "$A_STATE_DIR"; do' '_wr=(); for _w in "$A_STATE_DIR"; do' || rc=1
  mutate test_skills_dir    '_wr=(); for _w in "$PWD" "$A_STATE_DIR"; do' '_wr=(); for _w in "$PWD"; do' || rc=1
  mutate test_skills_dir    '  for _d in $A_EXTRA_DIRS; do _wr+=(' '  for _d in; do _wr+=(' || rc=1
  mutate test_skills_dir    '    while [ -L "$_f" ] && [ "$_n" -lt 10 ]; do' '    while false; do' || rc=1
  mutate test_skills_dir    '    [ ! -L "$_f" ] || die "The config file' '    : || die "The config file' || rc=1
  mutate test_skills_dir    '    _p="$(cd "$(dirname "$_f")" && pwd -P)" && _wr+=(' '    false && _wr+=(' || rc=1
  mutate test_skills_dir    '  skills_overlap "$_s" "AGENT_POD_SKILLS_DIR"' '  :' || rc=1
  mutate test_skills_dir    '  _s="$(cd "$AGENT_POD_SKILLS_DIR" && pwd -P)" ||' '  _s="$AGENT_POD_SKILLS_DIR"; true ||' || rc=1
  mutate test_skills_dir    '    skills_overlap "$_r" "The skill"' '    :' || rc=1
  mutate test_skills_dir    'A_SKILLS_TARGET=.copilot/skills' 'A_SKILLS_TARGET=.claude/skills' || rc=1
  mutate test_skills_dir    'A_SKILLS_TARGET=.agents/skills' 'A_SKILLS_TARGET=.claude/skills' || rc=1
  mutate test_skills_dir    'A_SKILLS_TARGET=.claude/skills' 'A_SKILLS_TARGET=.claude/other' || rc=1
  mutate test_skills_dir    'if [ -n "${AGENT_POD_SKILLS_DIR:-}" ]; then' 'if false; then' || rc=1
  mutate test_git_identity  '${GIT_MOUNT[@]+"${GIT_MOUNT[@]}"}' '' || rc=1
  mutate test_git_identity  '  _g="$_gd/$(basename "$_g")"' '  :' || rc=1
  mutate test_git_identity  '_writable=("$PWD" "$A_STATE_DIR");' '_writable=("$A_STATE_DIR");' || rc=1
  mutate test_git_identity  '_writable=("$PWD" "$A_STATE_DIR");' '_writable=("$PWD");' || rc=1
  mutate test_git_identity  'for _d in $A_EXTRA_DIRS; do _writable+=' 'for _d in; do _writable+=' || rc=1
  mutate test_git_identity  'case "$_gd/" in "$_w"/*)' 'case "$_gd/" in "$_w")' || rc=1
  mutate test_git_identity  '/home/agent-pod/.gitconfig:ro' '/home/agent-pod/.gitconfig' || rc=1
  mutate test_git_identity  'elif [ -f "$A_CFG_HOME/gitconfig" ]; then' 'elif false; then' || rc=1
  mutate test_profile       '"$A_CFG_HOME/$AGENT.gitconfig" ]; then _g="$A_CFG_HOME/$AGENT.gitconfig"' '"$A_CFG_HOME/$AGENT.gitconfig" ]; then _g="$A_CFG_HOME/gitconfig"' || rc=1
  mutate test_profile       '"$A_CFG_HOME/$A_KEY.gitconfig" ]; then _g="$A_CFG_HOME/$A_KEY.gitconfig"' '"$A_CFG_HOME/$A_KEY.gitconfig" ]; then _g="$A_CFG_HOME/gitconfig"' || rc=1
  mutate test_git_identity  '  [ -f "$AGENT_POD_GITCONFIG" ] || die "AGENT_POD_GITCONFIG=$AGENT_POD_GITCONFIG is not a file."' '  :' || rc=1
  mutate test_git_identity  'if [ -n "${AGENT_POD_GITCONFIG:-}" ]; then' 'if false; then' || rc=1
  mutate test_agent_flags   'mkdir -p "$A_CFG_HOME/$A_KEY-${_d##*/}"; ' '' || rc=1
  mutate test_agent_flags   'A_CFG_FILE=.claude.json; A_EXTRA_DIRS=.agents/skills' 'A_CFG_FILE=.claude.json; A_EXTRA_DIRS=' || rc=1
  mutate test_agent_flags   'A_CFG_FILE=.copilot.json; A_EXTRA_DIRS=.agents/skills' 'A_CFG_FILE=.copilot.json; A_EXTRA_DIRS=' || rc=1
  mutate test_agent_flags   'A_EXTRA_DIRS=".agents/skills .agents/plugins .agents/agents"' 'A_EXTRA_DIRS=".agents/skills .agents/plugins"' || rc=1
  mutate test_agent_flags   $'if [ -n "$A_CFG_FILE" ]; then\n  mkdir' $'if true; then\n  mkdir' || rc=1
  mutate test_agent_flags   '[ -z "$A_NOUPDATE" ] || AGENT_ENV' 'true; AGENT_ENV' || rc=1
  mutate test_cache_shared_between_agents '_hash="$(' '_hash="$AGENT$(' || rc=1
  mutate test_lazy_build    '"$HERE/install.sh" "$AGENT" >&2 || die' 'true || die' || rc=1
  mutate test_lazy_build    'if [ -z "$(docker image ls -q "$IMAGE" 2>/dev/null)" ]; then
  printf' 'if true; then
  printf' || rc=1
  mutate test_stdin_attached 'DOCKER_FLAGS=("--rm" "-i")' 'DOCKER_FLAGS=("--rm")' || rc=1
  mutate test_config_file_outside_state_dir 'A_CFG_PATH="$A_CFG_HOME/$A_KEY.json"' 'A_CFG_PATH="$A_STATE_DIR/$A_CFG_FILE"' || rc=1
  mutate test_config_file_outside_state_dir '[ -s "$A_CFG_PATH" ] || printf' 'printf' || rc=1
  mutate test_update_check  '"$_newest" != "$_installed"' 'false' || rc=1
  mutate test_update_check  $'if [ "$A_SRC" = github ]; then\n      # the redirect' $'if false; then\n      # the redirect' || rc=1
  mutate test_update_check  '${AGENT_POD_NO_UPDATE:-${!A_LEGACY_NO_UPDATE:-}}' '${AGENT_POD_NO_UPDATE:-${CLAUDE_POD_NO_UPDATE:-${COPILOT_POD_NO_UPDATE:-}}}' || rc=1
  mutate test_update_check  "grep -oE -m1 '[0-9]+\\.[0-9]+\\.[0-9]+'" "sed -n 's/^\\([0-9][0-9.]*\\).*/\\1/p'" || rc=1
  mutate test_stdin_reaches_pod '"${RUN_CMD[@]}" <&0 &' '"${RUN_CMD[@]}" &' || rc=1
  mutate test_rebuild_on_repo_change '"$(_label agent-pod.build)" != "$_want"' '"$(_label agent-pod.build)" = "$_want"' || rc=1
  mutate test_rebuild_on_repo_change '"$A_VERSION_VAR=${_asked:-$A_CHANNEL}"' '"$A_VERSION_VAR=$A_CHANNEL"' || rc=1
  mutate test_rebuild_on_repo_change 'if [ -z "$_tried" ] && command -v curl' 'if command -v curl' || rc=1
  mutate test_rebuild_on_repo_change '_tried=1   # whatever the outcome' ': # whatever the outcome' || rc=1
  mutate test_build_hash 'cat "$REPO_DIR/Dockerfile" "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md"' 'cat "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md"' install.sh || rc=1
  mutate test_build_hash 'cat "$REPO_DIR/Dockerfile" "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md"' 'cat "$REPO_DIR/Dockerfile" "$REPO_DIR/pod-environment.md"' install.sh || rc=1
  mutate test_build_hash 'cat "$REPO_DIR/Dockerfile" "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md"' 'cat "$REPO_DIR/Dockerfile" "$REPO_DIR/Dockerfile.base"' install.sh || rc=1
  mutate test_build_hash 'base_hash() { cat "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md" | hash16; }' 'base_hash() { cat "$REPO_DIR/Dockerfile" "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md" | hash16; }' install.sh || rc=1
  mutate test_build_hash 'base_hash() { cat "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md" | hash16; }' 'base_hash() { cat "$REPO_DIR/pod-environment.md" | hash16; }' install.sh || rc=1
  mutate test_build_hash 'base_hash() { cat "$REPO_DIR/Dockerfile.base" "$REPO_DIR/pod-environment.md" | hash16; }' 'base_hash() { cat "$REPO_DIR/Dockerfile.base" | hash16; }' install.sh || rc=1
  mutate test_build_hash '{ sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16' "{ sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16 | sed 's/.*/0123456789abcdef/'" install.sh || rc=1
  mutate test_base_image '  if out="$(docker pull "$BASE_IMAGE" 2>&1)"; then' '  out="$(docker pull "$BASE_IMAGE" 2>&1)"; if true; then' install.sh || rc=1
  mutate test_base_image '  elif [ -n "$(docker image ls -q "$BASE_IMAGE" 2>/dev/null)" ]; then' '  elif false; then' install.sh || rc=1
  mutate test_base_image '  if [ -n "${AGENT_POD_BUILD_BASE:-}" ]; then build_base; return; fi' '  :' install.sh || rc=1
  mutate test_base_image '--build-arg "BASE_IMAGE=$BASE_IMAGE" ' '' install.sh || rc=1
  mutate test_base_image '  if out="$(docker pull "$from" 2>&1)"; then' '  out="$(docker pull "$from" 2>&1)"; if true; then' install.sh || rc=1
  mutate test_base_image '  elif [ -n "$(docker image ls -q "$from" 2>/dev/null)" ]; then' '  elif false; then' install.sh || rc=1
  mutate test_base_image '{ print $2; exit }' '{ print $2 }' install.sh || rc=1
  mutate test_base_image '  refresh_from
  info "Building' '  info "Building' install.sh || rc=1
  mutate test_base_image $'\nensure_base\n' $'\n:\n' install.sh || rc=1
  mutate test_base_signature '    if ! verify_base; then' '    if false; then' install.sh || rc=1
  mutate test_base_signature '--certificate-identity-regexp "$SIGNER_IDENTITY"' '--certificate-identity-regexp ".*"' install.sh || rc=1
  mutate test_base_signature '--certificate-oidc-issuer "$SIGNER_ISSUER"' '--certificate-oidc-issuer ""' install.sh || rc=1
  mutate test_base_signature 'github.com/alfsch/ai-agent-pods/' 'github.com/[^/]*/[^/]*/' install.sh || rc=1
  mutate test_base_signature '\.github/workflows/publish-base\.yaml@' '\.github/workflows/[^@]*@' install.sh || rc=1
  mutate test_base_signature '@refs/heads/main$'"'"'' '@refs/heads/.*$'"'"'' install.sh || rc=1
  mutate test_base_signature "SIGNER_IDENTITY='^https" "SIGNER_IDENTITY='https" install.sh || rc=1
  mutate test_base_signature 'publish-base\.yaml@refs/heads/main$'"'"'' 'publish-base\.yaml@refs/heads/main'"'"'' install.sh || rc=1
  mutate test_base_signature '"${ref:-$BASE_IMAGE}"' '"$BASE_IMAGE"' install.sh || rc=1
  mutate test_base_signature '    [ -z "$ref" ] || BASE_IMAGE="$ref"' '    :' install.sh || rc=1
  mutate test_base_signature "index(\$0, repo) == 1 { print; exit }" "{ print; exit }" install.sh || rc=1
  mutate test_base_signature '      [ -z "${AGENT_POD_REQUIRE_SIGNED_BASE:-}" ]; return ;;' '      return 0 ;;' install.sh || rc=1
  mutate test_base_signature '    125|126|127)' '    125|126|127|1)' install.sh || rc=1
  mutate test_base_signature '    125|126|127)' '    125|126)' install.sh || rc=1
  mutate test_base_signature '    125|126|127)' '    125|127)' install.sh || rc=1
  mutate test_base_signature 'cosign/cosign:' 'cosign/cosign#' install.sh || rc=1
  mutate test_published_base_tag 'if published "$tag"; then echo "$tag"; exit 0; fi

tmp=' 'tmp=' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag '(yet)" >&2; return 1; }' '(yet)" >&2; return 0; }' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag 'published() { ./install.sh --verify-base "$1"' 'published() { ./install.sh --base-hash' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag '  if published "$tag"; then echo "$tag"; exit 0; fi
done' '  echo "$tag"; exit 0
done' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag 'git log --format=%H -n 30 "$REF"' 'git log --reverse --format=%H -n 30 "$REF"' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag 'exit 1' 'exit 0' tests/published-base-tag.sh || rc=1
  mutate test_published_base_tag ' -- Dockerfile.base pod-environment.md)' ')' tests/published-base-tag.sh || rc=1
  mutate test_verify_base_mode '  BASE_IMAGE="$BASE_REPO:$2"; AGENT_POD_REQUIRE_SIGNED_BASE=1' '  BASE_IMAGE="$BASE_REPO:$2"' install.sh || rc=1
  mutate test_verify_base_mode '  verify_base || exit 1
  exit 0' '  verify_base || true
  exit 0' install.sh || rc=1
  mutate test_verify_base_mode '  [ -n "${2:-}" ] || die "--verify-base needs the tag of the base image."' '  :' install.sh || rc=1
  mutate test_verify_base_mode '  docker pull "$BASE_IMAGE" >/dev/null || die "Could not pull $BASE_IMAGE."' '  :' install.sh || rc=1
  mutate test_verify_base_mode '  --verify-base)        AGENTS=() ;;
' '' install.sh || rc=1
  mutate test_base_signature 'docker run --rm --read-only --tmpfs /tmp -e HOME=/tmp "$COSIGN_IMAGE" verify' 'docker run --rm --read-only --tmpfs /tmp -e HOME=/tmp "$COSIGN_IMAGE" version; true' install.sh || rc=1
  mutate test_base_signature '    printf '"'"'%s  Not verified: %s is not the default repository.%s\n'"'"' "$DIM" "$BASE_REPO" "$RESET"
    [ -z "${AGENT_POD_REQUIRE_SIGNED_BASE:-}" ]; return' '    return 0' install.sh || rc=1
  mutate test_base_signature 'if [ "$BASE_REPO" != "$DEFAULT_BASE_REPO" ]; then' 'if false; then' install.sh || rc=1
  mutate test_install_agent_source 'if [ "$src" = github ]; then version="${version#v}"; channel_label="${channel_label#v}"; fi' ':' install.sh || rc=1
  mutate test_install_agent_source '--build-arg "AGENT_SRC=$src" ' '' install.sh || rc=1
  mutate test_install_agent_source $'if [ "$src" = github ]; then\n      resolved=' $'if false; then\n      resolved=' install.sh || rc=1
  mutate test_agent_install_layer '[0-9]*) rel="download/v${AGENT_VERSION}" ;; *) rel="latest/download" ;;' '*) rel="download/v${AGENT_VERSION}" ;;' Dockerfile || rc=1
  mutate test_agent_install_layer 'if [ "${AGENT_SRC}" = github ]; then' 'if false; then' Dockerfile || rc=1
  mutate test_agent_install_layer ' && ${AGENT} --version && exit 0;' ' && exit 0;' Dockerfile || rc=1
  mutate test_agent_install_layer 'for i in 1 2 3; do' 'for i in 1; do' Dockerfile || rc=1
  mutate test_agent_install_layer $'    done; \\\n    exit 1' $'    done; \\\n    exit 0' Dockerfile || rc=1
  mutate test_agent_install_layer ' && ${AGENT} --version && exit 0;' ' && ${AGENT} --version;' Dockerfile || rc=1
  mutate test_agent_install_layer 'npm uninstall -g ${AGENT_PKG} >/dev/null 2>&1 || true;' 'true;' Dockerfile || rc=1
  mutate test_publish_signs_created_digest '          cosign sign --yes "$IMAGE@$DIGEST"' '          cosign sign --yes "$IMAGE@$(docker buildx imagetools inspect "$IMAGE:$TAG" --format '"'"'{{json .Manifest}}'"'"' | sed '"'"'s/.*"digest":"\([^"]*\)".*/\1/'"'"')"' .github/workflows/publish-base.yaml || rc=1
  mutate test_publish_signs_created_digest "digest=\"sha256:\$(printf '%s' \"\$manifest\"" "digest=\"sha256:\$(printf '%s' \"\$sources\"" .github/workflows/publish-base.yaml || rc=1
  mutate test_publish_signs_created_digest '          docker buildx imagetools inspect "$IMAGE@$digest"' '          true' .github/workflows/publish-base.yaml || rc=1
  mutate test_publish_signs_created_digest '          echo "digest=$digest" >> "$GITHUB_OUTPUT"' '          true' .github/workflows/publish-base.yaml || rc=1
  mutate test_prune_decide '([$kept[], $others[]] | map($ch[.name][]?)) as $protected' '[] as $protected' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'elif ts >= $grace then ["keep", "younger than the grace period"]' 'elif false then ["keep", "younger than the grace period"]' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'map(select(.key < $keep_tags or (.value | ts) >= $cutoff))' 'map(select(.key < $keep_tags))' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'map(select(.key < $keep_tags or (.value | ts) >= $cutoff))' 'map(select((.value | ts) >= $cutoff))' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'if ($unknown | length) > 0 then' 'if false then' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'if ($hashed | length) == 0 then error(' 'if false then error(' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'if $keep_tags < 1 then error(' 'if false then error(' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide '["delete", "signature of a removed image"]' '["keep", "signature of a removed image"]' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide 'then ["keep", "tag not set by the publish workflow: "' 'then ["delete", "tag not set by the publish workflow: "' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide '["delete", "untagged and not part of a kept image"]' '["keep", "untagged and not part of a kept image"]' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run 'DRY_RUN="${DRY_RUN:-true}"' 'DRY_RUN="${DRY_RUN:-false}"' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run 'if [ "$DRY_RUN" != false ]; then' 'if [ "$DRY_RUN" = true ]; then' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run '[ "$failed" = 0 ] || { echo "$failed deletions failed" >&2; exit 1; }' '[ "$failed" = 0 ] || true' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run "tr '[:upper:]' '[:lower:]'" 'cat' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run "jq -s 'add // []'" "jq -s '.[0] // []'" .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide '([$kept[], $others[]] | map(.name | sig_of)) as $kept_sigs' '($kept | map(.name | sig_of)) as $kept_sigs' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide '([$kept[], $others[]] | map(select($ch[.name] == null) | .name)) as $unknown' '($kept | map(select($ch[.name] == null) | .name)) as $unknown' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run 'length > 0 and any(test("^sha256-[0-9a-f]{64}\\.sig$") | not)' 'any(test("^[0-9a-f]{16}$"))' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_decide '    def ts: ([.created_at, (.updated_at // .created_at)] | map(fromdateiso8601) | max);' '    def ts: (.created_at | fromdateiso8601);' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run '  for k in $kids; do echo "$k"; descend "$k" || return 1; done' '  for k in $kids; do echo "$k"; done' .github/scripts/prune-base-images.sh || rc=1
  mutate test_prune_run '  for k in $kids; do echo "$k"; descend "$k" || return 1; done' '  for k in $kids; do echo "$k"; descend "$k" || true; done' .github/scripts/prune-base-images.sh || rc=1
  return $rc
}

# ---- main ----------------------------------------------------------------------------------------------
if [ "${1:-}" = --inner ]; then "$2"; exit $?; fi
# --no-mutants: all tests, but not the mutants (which test the launcher's logic, not the platform).
NO_MUTANTS=; if [ "${1:-}" = --no-mutants ]; then NO_MUTANTS=1; shift; fi
# No mapfile (not in Bash 3.2) and no silent empty run: an empty list would skip the baseline and let every
# mutant count as killed.
tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
  # shellcheck disable=SC2207  # the words are test names, and mapfile is what must be avoided
  tests=($(declare -F | awk '$3 ~ /^test_/ {print $3}'))
fi
[ ${#tests[@]} -gt 0 ] || { echo "  ERROR     no tests found" >&2; exit 1; }
failed=0
for t in "${tests[@]}"; do
  if ( "$t" ); then echo "  ok        $t"; else echo "  FAILED    $t"; failed=1; fi
done
if [ $# -eq 0 ] && [ -z "$NO_MUTANTS" ] && [ "$LAUNCHER" = "$ROOT/agent-pod" ]; then echo "mutants:"; run_mutants || failed=1; fi
exit $failed
