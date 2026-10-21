# ai-agent-pods

Runs Claude Code or the GitHub Copilot CLI in a hardened Docker container scoped to the current folder. One
launcher, `agent-pod` (symlinks `claude-pod` and `copilot-pod` select the agent by name); `install.sh` builds
`agent-pod:claude` and `agent-pod:copilot` from one `Dockerfile`, `uninstall.sh` removes everything. User docs
are in `README.md`.

## One launcher, two agents

- Everything that differs between the agents is in the agent table (`case "$AGENT"`) at the top of `agent-pod`
  and the same two values in `install.sh` (npm package, default channel, version variable). Anything else that
  mentions an agent by name is a bug: the sidecar, cache and signal logic are the same for both.
- State dirs stay `~/.claude-pod` and `~/.copilot-pod` so existing logins keep working; the container home is
  `/home/agent-pod` for both. The Docker cache is per project, not per agent.
- The agent's config file (`.claude.json`, `.copilot.json`) lives in `~/.config/agent-pod/<agent>.json`, never in
  the state dir: the pod can write to the state dir and could leave a symlink in place of the file. The pod gets
  the file, not its directory. Do not move it back.
- Without the image of an agent the launcher builds it with `install.sh` (next to the real script, symlinks resolved).

## Before changing the Docker sidecar (`DOCKER=1` / `DOCKER_CACHE=1`)

- Read [docs/docker-sidecar.md](docs/docker-sidecar.md) first: architecture, the lifecycle invariants the
  launcher must keep, the cache design and the testing approach.
- Keep it simple. Cache exclusivity is the fixed sidecar name and cache pruning uses one stamp file per
  cache; an earlier version with lock files and a shared state file produced a new race with every fix.
  Do not reintroduce locks or a shared usage file, and weigh each automated review finding against that
  before implementing it.
- Without `DOCKER=1` the launcher must keep `exec`ing docker unchanged.

## Testing

- The stub tests (`tests/stubbed-docker.sh`, run by `.github/workflows/stub-tests.yaml` on pull requests) need
  no Docker daemon, which the Claude sandbox usually lacks. They run the launcher for one agent (`AGENT=claude`
  by default) plus tests of what differs per agent. Make each test fail without the fix (see the docs).
  Anything that needs a real daemon (rootless sidecar, TLS, cache volumes, signals, both images) is covered by
  `tests/integration.sh` (`.github/workflows/integration-tests.yaml`) and, for what that does not check, by the
  checklist in `docs/docker-sidecar.md`, on a host with Docker.
- Renovate merges updates of GitHub Actions and of the tooling images (docker CLI, DIND sidecar, node base image,
  yq), majors included, as soon as the required checks pass (`renovate.json`), so those checks are the only
  review such an update gets. If a merged update breaks something the tests did not notice, the fix includes a
  new test for it. A test must not name a version Renovate bumps.
- The stub tests also run on macOS (system Bash 3.2, BSD tools): keep them portable, with no `mapfile` and no
  GNU-only flags (see the helpers in `tests/stubbed-docker.sh`).
- Rootless DinD needs unprivileged user namespaces; on Ubuntu 24.04+ that means
  `kernel.apparmor_restrict_unprivileged_userns=0` for the test (set it back to `1` afterwards).
- After every edit run `for f in agent-pod install.sh uninstall.sh tests/stubbed-docker.sh tests/integration.sh; do bash -n "$f"; done`
  (`bash -n a b c` parses only `a`); CI does that and also runs ShellCheck (`-S warning`).

## Status

Current status and open items of work in progress are in the description of the open pull request, not in
this file, so they cannot go stale here.
