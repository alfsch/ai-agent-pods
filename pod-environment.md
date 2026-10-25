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
- `docker` is a client only; there is no daemon in the container. Client-only commands work (`docker --version`,
  `docker compose config`). Anything that needs a daemon (`build`, `run`, `ps`, `compose up`) works only if the session
  was started with `DOCKER=1`; then it talks to a throwaway rootless daemon in a sidecar, and ports published by inner
  containers are at `dind:<port>`, not `localhost`. Without `DOCKER=1` those commands fail.
- `gh` is authenticated only if the host had `GH_TOKEN` or `GITHUB_TOKEN` set: Copilot CLI sessions pass them on,
  Claude Code and goose sessions do not (`COPILOT_GITHUB_TOKEN` is for Copilot itself, not for `gh`). `gh auth login` works
  with the open network, but its login is lost when the session ends. There is no SSH key or git credential for pushes.

Tools on PATH: git, curl, less, jq, gh, yq, python3, pip, pdftotext, qpdf, tesseract, node, npm, docker

- `yq` is mikefarah's (Go) version. `docker` also has the `compose` and `buildx` plugins.
- `tesseract` has English and German language data. `pdftotext` is from poppler-utils.
- Anything else the project needs (compilers, other runtimes) is not installed.
