# ai-agent-pods: instructions for AI coding agents

Read by Claude Code (through `CLAUDE.md`), Copilot CLI and other agents. The same rules apply to people.

Runs Claude Code, the GitHub Copilot CLI or goose in a hardened Docker container scoped to the current folder. One
launcher, `agent-pod` (symlinks `claude-pod`, `copilot-pod` and `goose-pod` select the agent by name); `install.sh` builds
`agent-pod:claude`, `agent-pod:copilot` and `agent-pod:goose` from `Dockerfile` (the agent) on top of `Dockerfile.base` (the shared tools; published by CI to GHCR),
`uninstall.sh` removes everything. User docs
are in `README.md`.

## One launcher, three agents

- Everything that differs between the agents is in the agent table (`case "$AGENT"`) at the top of `agent-pod`
  and the same values in `install.sh` (source, package or repository, default channel, version variable). Anything else that
  mentions an agent by name is a bug: the sidecar, cache and signal logic are the same for all.
- State dirs stay `~/.claude-pod` and `~/.copilot-pod` (goose: `~/.goose-pod`) so existing logins keep working; `AGENT_POD_PROFILE=<name>` adds `-<name>` to them and, through `A_KEY` (the agent, plus `-<name>`), to every other host path that is kept per agent, so a new per-agent path must use `A_KEY`, not `AGENT`; the container home is
  `/home/agent-pod` for all. The Docker cache is per project, not per agent.
- The agent's config file (`.claude.json`, `.copilot.json`) lives in `~/.config/agent-pod/<agent>.json`, never in
  the state dir: the pod can write to the state dir and could leave a symlink in place of the file. The pod gets
  the file, not its directory. Do not move it back. goose has no such file (`A_CFG_FILE` empty): its XDG config, data and
  state dirs are pointed into its state dir by `A_ENV`, so everything it writes is in the mounted dir, nothing outside.
- goose is the one agent that does not come from npm (`A_SRC=github`): its static musl binary is taken from the release
  assets (tag from the `/releases/latest` redirect, not the API). The release has no checksum file to verify; the
  keyring is off (`GOOSE_DISABLE_KEYRING=1`) because the pod has none. The pod environment file reaches it as
  `~/.agents/AGENTS.md` (baked into the base, outside the mounted dir).
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
- **Before every commit run `tests/check.sh`**: syntax (`bash -n` per file), ShellCheck (`-S warning`, pinned image)
  and the stub tests with their mutants. CI runs the same three steps (`tests/check.sh syntax|shellcheck|tests`), so
  what passes there passes in CI. `tests/check.sh tests --no-mutants` is the quick form. After a change to the
  sidecar, the image or the installer also run `tests/integration.sh` (needs Docker, see its header).

## Decisions that look like bugs but are not

Weigh an automated review finding against these before changing code. If a finding is right, the fix includes a
test that fails without it.

- The pod runs as a background job (`"${RUN_CMD[@]}" <&0 &`) and is polled with `kill -0` before a single `wait`
  (invariant 5 in the sidecar docs). Do not replace the loop with `wait`. The `<&0` is what gives the pod its stdin.
- Ctrl-C reaches the backgrounded docker client as well as `stop_pod`. That is documented; no `setsid`.
- `--help` and `-h` are handled by the launcher; the command to run in the container starts after the agent name.
- The agent's state dirs and config file are shared by all projects on purpose (one login). That lets code in one
  project leave hooks or MCP entries for the next session in another; it is documented in the README, with the way to
  separate untrusted work (another `HOME`). Do not "fix" it by silently changing what is shared.
- `node:24-slim` in `uninstall.sh` and the README is kept in sync with the Dockerfile by Renovate's regex manager.
- `install.sh` pulls the published base (`ghcr.io/alfsch/agent-pod-base:<hash of Dockerfile.base and
  pod-environment.md>`); a failed pull uses the local copy of that tag, then builds `Dockerfile.base` here (a registry
  rate limit or outage must not fail a start). Only the base is ever published: Claude Code and Copilot CLI are
  proprietary (all rights reserved / redistribution only under conditions), so never add an agent to a published
  image. Likewise the first `FROM` of `Dockerfile.base` is pulled with a local fallback before a local base build; it is
  not `docker build --pull`, which fails hard. A change to `Dockerfile.base` or `pod-environment.md` reaches users only
  after `publish-base.yaml` has run on `main`; until then the pull fails and they build it. Pull requests build it
  locally, they cannot publish.
- The published base is signed by `publish-base.yaml` (cosign, keyless) and `install.sh` verifies it with cosign
  run as a container (`COSIGN_IMAGE`, pinned by digest, kept current by Renovate; a new major is not auto-merged). Docker
  stays the one requirement: no host cosign. A failed check builds the base locally instead of using the pulled image; if
  Docker cannot run it (exit 125-127 of `docker run`: no pull, no daemon) it only warns, unless
  `AGENT_POD_REQUIRE_SIGNED_BASE=1`. Anything cosign itself fails with is a failed check, a Sigstore that cannot be
  reached included: its output is never matched against text, because it echoes fields of the signature bundle that an
  attacker controls. Pull requests build the base when it is not published, which passes with a broken invocation, so
  `integration-tests.yaml` runs `install.sh --verify-base <tag>` on a published base (the newest one that exists, `tests/published-base-tag.sh`: on a push to main the publish run is not done yet; and the same with a wrong signer
  identity, which must fail) to vouch for a cosign update. The signer identity in `install.sh`
  (`SIGNER_IDENTITY`) names the workflow file and `refs/heads/main`: renaming the workflow means changing both, and a
  base published from another branch is rightly rejected. Only the default repository is checked. After a successful
  check `BASE_IMAGE` is the verified digest, so the agent images are built from the bytes that were checked and not
  from a tag that another install could retarget meanwhile.
  The workflow signs the digest it computed from the manifest it pushed (and checked is in the registry), never the
  result of a later tag lookup: anything else writing to the package could have moved the tag, and the workflow would
  sign that with its own identity.
- The agent layer of `Dockerfile` runs `<agent> --version` and installs again (three tries) when that fails: npm can
  succeed while the agent's platform-specific optional package did not download, and the CLI then only says "no platform
  package found" when it runs (seen as a flaky integration test). Do not drop the check or the retries; `install.sh`
  verifies the finished image again on purpose.
- A symlink the user made at `~/.config/agent-pod/<agent>.json` (dotfiles) is theirs and is followed; the pod cannot
  create one there.
- There is no migration of the old `~/.claude-pod/.claude.json`; the README says how to copy it.

## Status

Current status and open items of work in progress are in the description of the open pull request, not in
this file, so they cannot go stale here.
