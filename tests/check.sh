#!/usr/bin/env bash
# All the checks that CI runs, in one place: tests/check.sh [syntax|shellcheck|tests] [args for the stub tests]
# Without an argument it runs all three, in this order. CI calls the same three steps, so a pull request that passes
# here passes there. The stub tests need no Docker daemon; ShellCheck runs in a pinned image (Docker) or, without
# Docker, with a local shellcheck.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
FILES=(agent-pod install.sh uninstall.sh tests/check.sh tests/stubbed-docker.sh tests/integration.sh tests/published-base-tag.sh)
# Pinned, so that a new ShellCheck version cannot fail a pull request on its own.
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.10.0

# One `bash -n` per file: with several names it parses only the first and takes the rest as arguments.
# $BASH is the shell running this script, so `/bin/bash tests/check.sh syntax` checks with the macOS Bash 3.2.
syntax() {
  local f rc=0
  for f in "${FILES[@]}"; do "$BASH" -n "$f" || rc=1; done
  return "$rc"
}

shellcheck_files() {
  if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/mnt" -w /mnt "$SHELLCHECK_IMAGE" -S warning "${FILES[@]}"
  elif command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${FILES[@]}"
  else
    echo "ShellCheck needs Docker or a local shellcheck" >&2; return 1
  fi
}

# Tests, then the mutants: each launcher with one fix removed must make a test fail. Arguments (--no-mutants, test
# names) go to the stub tests.
stub_tests() { tests/stubbed-docker.sh "$@"; }

step="${1:-all}"; [ "$#" -eq 0 ] || shift
case "$step" in
  syntax)     syntax ;;
  shellcheck) shellcheck_files ;;
  tests)      stub_tests "$@" ;;
  all)        syntax && shellcheck_files && stub_tests ;;
  *)          echo "usage: tests/check.sh [syntax|shellcheck|tests] [stub test arguments]" >&2; exit 2 ;;
esac
