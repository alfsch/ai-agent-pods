# The environment you run in

You run inside **agent-pod**, a Docker container that holds one project folder. This file is read by Claude Code,
Copilot CLI and goose alike; it is about the container, not about the project.

- The project folder is mounted at the same path as on the host, and so are the agent's login and settings from the
  host (`~/.claude` and `~/.claude.json` for Claude Code, `~/.copilot` and `~/.copilot.json` for Copilot CLI, `~/.goose` for goose). Those
  persist, and so do the global skills in `~/.agents/skills` (all agents) and, for goose, `~/.agents/plugins` and
  `~/.agents/agents`: what you put there is available in later sessions of other projects too. Everything else, the
  rest of `/home/agent-pod` included, is thrown away when the session ends (`--rm`).
- You run as a normal user with a host uid and no name, in `/home/agent-pod`. There is no `sudo`, no capabilities, and
  the system directories are read-only for you. Installing into the system fails: use a Python virtual environment
  (`python3 -m venv .venv`), a project-local `npm install`, or a binary in the project folder.
- The network is open (registries, APIs) unless the session was started with `NET=none`. A dev server must listen on
  `0.0.0.0` to be reachable from the host, and only ports published with `PORTS` are (on the host's 127.0.0.1).
- `docker` is a client; whether a daemon is behind it depends on how the session was started. **If `DOCKER_HOST` is set**
  (to `tcp://dind:2376`, with `DOCKER_TLS_VERIFY` and `DOCKER_CERT_PATH`), the session was started with `DOCKER=1` and
  `docker` talks to a throwaway rootless daemon in a sidecar: `docker info` confirms it, and `build`, `run`, `ps` and
  `compose up` work. That daemon is not the host's: the host's Docker socket is never mounted (there is no
  `/var/run/docker.sock`), the host's images and containers are not visible, and ports published by inner containers are
  at `dind:<port>`, not `localhost`. With `DOCKER_CACHE=1` its images persist between sessions of this project, which
  you cannot tell from the environment: look with `docker image ls` before you assume an image is or is not there.
  **If `DOCKER_HOST` is unset there is no daemon:** only client-only commands work (`docker --version`,
  `docker compose config`) and everything else fails. You cannot start one from inside; the user has to restart the
  session with `DOCKER=1`.
  With the sidecar, a tool this container lacks (a linter, a scanner, another shell or distro) is best run as a
  pinned image when one exists, never installed or downloaded into the pod:
  `docker run --rm -v "$PWD:$PWD" -w "$PWD" <image>:<version> ...`. The project folder is visible in inner containers at
  the same path and what they create there is yours; other paths of this container (such as `/tmp`) are not, so keep
  inputs and outputs in the project folder or pipe them through stdin and stdout.
- `gh` is authenticated only if the host had `GH_TOKEN` or `GITHUB_TOKEN` set: Copilot CLI sessions pass them on,
  Claude Code and goose sessions do not (`COPILOT_GITHUB_TOKEN` is for Copilot itself, not for `gh`). `gh auth login` works
  with the open network, but its login is lost when the session ends. There is no SSH key or git credential for pushes. `git` has an identity only if the user gave the session a git config (mounted read-only as `~/.gitconfig`); without one, commits fail with "Author identity unknown" and you can pass one per command (`git -c user.name=... -c user.email=... commit`).

Tools on PATH: git, curl, less, jq, gh, yq, python3, pip, pdftotext, qpdf, tesseract, node, npm, docker

- `yq` is mikefarah's (Go) version. `docker` also has the `compose` and `buildx` plugins.
- `tesseract` has English and German language data. `pdftotext` is from poppler-utils.
- Anything else the project needs (compilers, other runtimes) is not installed.
