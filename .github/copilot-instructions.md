# Instructions for Copilot

The rules for changing this repository are in `AGENTS.md`. Read it first. Run `tests/check.sh` before proposing a
change as done.

## Code review

This is a Bash launcher (`agent-pod`) for a hardened Docker container. It must run under macOS Bash 3.2 (no
`mapfile`, no `${var,,}`, guard empty arrays under `set -u`). Dependency updates are merged automatically once the
required checks pass, so a missing test is the main risk: ask for a test that fails without the fix.

Do not report these, they are decided (details in `AGENTS.md`):
- the background job with `<&0` and the `kill -0` polling loop before one `wait`
- Ctrl-C reaching the docker client twice in the `DOCKER=1` path
- state dirs and the config file shared by all projects (documented trade-off)
- no locks or shared state file for the Docker cache
- `node:24-slim` literals in `uninstall.sh` and the README (kept in sync by Renovate)
- `--help` and `-h` handled by the launcher

Do report: ways for the pod to reach host files (mounts, symlinks, env forwarding, certificates), leftover Docker
resources after exit or a signal, and tests that pass without the code they claim to test.
