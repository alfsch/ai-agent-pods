# The environment you run in

You run inside **agent-pod**, a Docker container that holds one project folder. This file is read by Claude Code and
Copilot CLI alike; it is about the container, not about the project.

- The project folder is mounted at the same path as on the host. Everything else in the container is thrown away when
  the session ends (`--rm`); files written outside the project and `/home/agent-pod` are lost.
- You run as a normal user with a host uid and no name, in `/home/agent-pod`. There is no `sudo`, no capabilities, and
  the system directories are read-only for you. Installing into the system fails: use a Python virtual environment
  (`python3 -m venv .venv`), a project-local `npm install`, or a binary in the project folder.
- The network is open (registries, APIs) unless the session was started with `NET=none`. A dev server must listen on
  `0.0.0.0` to be reachable from the host, and only ports published with `PORTS` are (on the host's 127.0.0.1).
- `docker` is a client only. It works only if the session was started with `DOCKER=1`; then it talks to a throwaway
  rootless daemon in a sidecar. Ports published by inner containers are at `dind:<port>`, not `localhost`. Without
  `DOCKER=1` every `docker` command fails.
- `gh` is logged in only if a token variable was passed in (`GH_TOKEN`, `GITHUB_TOKEN`, `COPILOT_GITHUB_TOKEN`); there is
  no interactive login for it here and no SSH key or git credential for pushes.

Tools on PATH: git, curl, less, jq, gh, yq, python3, pip, pdftotext, qpdf, tesseract, node, npm, docker

- `yq` is mikefarah's (Go) version. `docker` also has the `compose` and `buildx` plugins.
- `tesseract` has English and German language data. `pdftotext` is from poppler-utils.
- Anything else the project needs (compilers, other runtimes) is not installed.
