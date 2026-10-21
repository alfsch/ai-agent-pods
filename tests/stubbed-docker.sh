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
#   STUB_CHANNEL / STUB_VERSION   the agent-pod.channel / agent-pod.version labels of the image;
#                         STUB_VERSION_OUT is what `<agent> --version` prints in it
#   STUB_POD_STDIN=1      the pod stores its stdin in $STUB_DIR/pod-stdin
#   STUB_NO_IMAGE=1       the agent image is missing until the stub install.sh ran
#   STUB_DERIVED_EXISTS=1 the derived sidecar image already exists; STUB_BUILD_FAIL=1 `docker build` fails
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  image)
    # image labels, for the update check
    if [ "$2" = inspect ]; then
      case "$*" in *agent-pod.channel*) echo "${STUB_CHANNEL:-}" ;; *agent-pod.version*) echo "${STUB_VERSION:-}" ;; esac
      exit 0
    fi
    if [[ "$*" == *agent-pod-dind* ]]; then
      { [ -n "${STUB_DERIVED_EXISTS:-}" ] || [ -e "$STUB_DIR/built" ]; } && echo derivedid; exit 0
    fi
    # the agent image: present, unless STUB_NO_IMAGE=1 and the (stub) install.sh has not run
    if [ "$2" = ls ] && { [ -z "${STUB_NO_IMAGE:-}" ] || [ -e "$STUB_DIR/installed" ]; }; then echo abc123; fi
    exit 0 ;;
  build) cat > "$STUB_DIR/dockerfile"; : > "$STUB_DIR/built"; exit "${STUB_BUILD_FAIL:-0}" ;;
  network) [ "$2" = rm ] && sleep "${STUB_NETRM_SLEEP:-0}"; exit 0 ;;
  volume)
    case "$2" in
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
# the npm registry: both channels are at 9.9.9
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"latest":"9.9.9","stable":"9.9.9"}'
STUB
chmod +x "$BIN/id" "$BIN/uname" "$BIN/curl"
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
launch_env() { cd "$PROJ" && HOME="$H" XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" AGENT_POD_NO_UPDATE=1 PATH="$BIN:$PATH" "$@"; }
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
in_out()    { cat "$CASE/out" "$CASE/err" | grep -qE -- "$1" || fail "expected output matching: $1"; }
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
  rc_is 1; in_out "docker rm -f agent-pod-dind-cache-$HASH"
  not_logged '^run --rm'; not_logged '^(stop|rm -f -v)'
  logged '^network rm '
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
  for a in claude copilot; do
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
}
test_cache_shared_between_agents() {   # one Docker cache per project, whichever agent runs in it
  local a
  for a in claude copilot; do
    setup_case; AGENT=$a launch DOCKER=1 DOCKER_CACHE=1 -- true
    rc_is 0; logged "^run -d --privileged --init --name agent-pod-dind-cache-$HASH "
    logged " -v agent-pod-docker-$HASH:/home/rootless/.local/share/docker "
  done
}
test_lazy_build() {   # a missing image is built by install.sh (next to the launcher) before the first start
  local a d
  for a in claude copilot; do
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
  # a regular file from an earlier version is copied once; an existing config is never overwritten
  setup_case; f="$H/config/agent-pod/claude.json"; mkdir -p "$H/.claude-pod"; printf '{"login":1}' > "$H/.claude-pod/.claude.json"
  AGENT=claude launch -- true; rc_is 0
  [ "$(cat "$f")" = '{"login":1}' ] || fail "the config of an earlier version was not carried over"
  printf '{"new":1}' > "$f"; AGENT=claude launch -- true; rc_is 0
  [ "$(cat "$f")" = '{"new":1}' ] || fail "an existing config was overwritten"
}

test_update_check() {   # a newer release on the image's channel rebuilds it; the opt-outs skip that, each for its own agent
  local a d v
  upd() {   # upd <agent> <label version> <VAR=value>... : sets UPD=update when install.sh was run, else UPD=no
    # (not printed and captured: a fail() inside $(...) would only end that subshell and the check would still pass)
    setup_case; d="$CASE/repo"; mkdir -p "$d"; cp "$LAUNCHER" "$d/agent-pod"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "install.sh $*" >> "$STUB_LOG"' > "$d/install.sh"; chmod +x "$d/install.sh"
    local a="$1" v="$2" ch=latest; shift 2; [ "$a" = claude ] || [ "$a" = copilot ] || return 1
    [ "$a" = claude ] && ch=stable
    AGENT=$a LAUNCHER="$d/agent-pod" launch AGENT_POD_NO_UPDATE= STUB_CHANNEL=$ch STUB_VERSION="$v" "$@" -- true
    [ "$RC" = 0 ] || fail "launcher exit $RC"
    if grep -q "^install.sh $a\$" "$STUB_LOG"; then UPD=update; else UPD=no; fi
  }
  for a in claude copilot; do
    upd $a 1.0.0; [ "$UPD" = update ] || fail "$a: an outdated image was not updated"
    upd $a 9.9.9; [ "$UPD" != update ] || fail "$a: an image at the newest version was rebuilt"
    upd $a 1.0.0 AGENT_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "$a: AGENT_POD_NO_UPDATE did not skip the update"
  done
  # the old variable of one agent says nothing about the other
  upd claude 1.0.0 CLAUDE_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "CLAUDE_POD_NO_UPDATE did not skip Claude"
  upd copilot 1.0.0 COPILOT_POD_NO_UPDATE=1; [ "$UPD" != update ] || fail "COPILOT_POD_NO_UPDATE did not skip Copilot"
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

# ---- mutants: each must make its test fail, proving the test discriminates -----------------------------
mutate() {   # mutate <test> <old> <new>   (literal replacement in a copy of the launcher)
  local test="$1" old="$2" new="$3" src; src="$(cat "$ROOT/agent-pod"; echo x)"; src="${src%x}"
  declare -F "$test" >/dev/null || { echo "  ERROR  mutant names an unknown test: $test"; return 1; }
  [[ "$src" == *"$old"* ]] || { echo "  ERROR  mutant for $test does not apply: $old"; return 1; }
  # the replacement is quoted: in Bash 5.2 an unquoted & in it stands for the text that was matched
  printf '%s' "${src/"$old"/"$new"}" > "$T/mutant"; chmod +x "$T/mutant"
  if ( LAUNCHER="$T/mutant" "$0" --inner "$test" >/dev/null 2>&1 ); then
    echo "  SURVIVED  $test passes without: ${old%%$'\n'*}"; return 1
  fi
  echo "  killed    $test fails without: ${old%%$'\n'*}"
}
run_mutants() {
  local rc=0
  mutate test_sequence      $'  ${DOCKER:+--init} \\\n' '' || rc=1
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
  mutate test_agent_selection 'case "$SELF" in claude-pod) AGENT=claude ;; copilot-pod) AGENT=copilot ;; esac' ':' || rc=1
  mutate test_agent_selection '[ -L "$_src" ]' 'false' || rc=1
  mutate test_agent_flags   'A_NOUPDATE=COPILOT_AUTO_UPDATE=false' 'A_NOUPDATE=DISABLE_AUTOUPDATER=1' || rc=1
  mutate test_agent_flags   'A_FORWARD="COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN"' 'A_FORWARD=' || rc=1
  mutate test_agent_flags   'A_STATE_DIR="$HOME/.copilot-pod"' 'A_STATE_DIR="$HOME/.claude-pod"' || rc=1
  mutate test_cache_shared_between_agents '_hash="$(' '_hash="$AGENT$(' || rc=1
  mutate test_lazy_build    '"$HERE/install.sh" "$AGENT" >&2 || die' 'true || die' || rc=1
  mutate test_lazy_build    'if [ -z "$(docker image ls -q "$IMAGE" 2>/dev/null)" ]; then
  printf' 'if true; then
  printf' || rc=1
  mutate test_stdin_attached 'DOCKER_FLAGS=("--rm" "-i")' 'DOCKER_FLAGS=("--rm")' || rc=1
  mutate test_config_file_outside_state_dir 'A_CFG_PATH="$A_CFG_HOME/$AGENT.json"' 'A_CFG_PATH="$A_STATE_DIR/$A_CFG_FILE"' || rc=1
  mutate test_config_file_outside_state_dir ' && [ ! -L "$A_STATE_DIR/$A_CFG_FILE" ]; then' '; then' || rc=1
  mutate test_config_file_outside_state_dir 'if [ ! -e "$A_CFG_PATH" ] && ' 'if ' || rc=1
  mutate test_update_check  '"$_newest" != "$_installed"' 'false' || rc=1
  mutate test_update_check  '${AGENT_POD_NO_UPDATE:-${!A_LEGACY_NO_UPDATE:-}}' '${AGENT_POD_NO_UPDATE:-${CLAUDE_POD_NO_UPDATE:-${COPILOT_POD_NO_UPDATE:-}}}' || rc=1
  mutate test_update_check  "grep -oE -m1 '[0-9]+\\.[0-9]+\\.[0-9]+'" "sed -n 's/^\\([0-9][0-9.]*\\).*/\\1/p'" || rc=1
  mutate test_stdin_reaches_pod '"${RUN_CMD[@]}" <&0 &' '"${RUN_CMD[@]}" &' || rc=1
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
