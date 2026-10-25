# The agent image: the shared base (Dockerfile.base, passed in by install.sh as BASE_IMAGE) plus one agent.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The agent to install: install.sh passes where it comes from (AGENT_SRC: npm, or github for a static binary in the
# release assets of the repository AGENT_PKG), the version or dist-tag to install (AGENT_VERSION) and the name (AGENT). The base is the same for every agent, so both images share its layers.
ARG AGENT_SRC=npm
ARG AGENT_PKG
ARG AGENT_VERSION

# install.sh resolves a dist-tag such as "latest" to a concrete version, so the version literal itself is the
# cache key and this layer caches normally. If resolution fails, install.sh passes CACHEBUST=$(date +%s)
# to force a fresh refetch.
ARG CACHEBUST=1
ARG AGENT=
# npm can finish "successfully" with an agent that cannot start: its binary comes as a platform-specific optional
# package, and when that download fails (a slow or flaky registry) the CLI only says "no platform package found" when
# it runs. So the layer runs the agent and, if that fails, installs again (up to three tries) instead of letting a
# half-installed image reach the verification at the end of install.sh. AGENT is the name of the binary.
# A github agent is the musl build, which is statically linked (it runs on any base); a truncated download makes tar fail.
RUN for i in 1 2 3; do \
      if [ "${AGENT_SRC}" = github ]; then \
        curl -fsSL "https://github.com/${AGENT_PKG}/releases/download/v${AGENT_VERSION}/${AGENT}-$(uname -m)-unknown-linux-musl.tar.gz" \
          | tar -xz -C /usr/local/bin ./${AGENT}; \
      else \
        npm install -g ${AGENT_PKG}@${AGENT_VERSION}; \
      fi && ${AGENT} --version && exit 0; \
      echo "Attempt $i of installing ${AGENT_PKG}@${AGENT_VERSION} failed" >&2; \
      npm uninstall -g ${AGENT_PKG} >/dev/null 2>&1 || true; \
      sleep 5; \
    done; \
    exit 1

# Recorded for the agent-pod launcher: it only auto-updates images built from the agent's default channel
# (AGENT_CHANNEL, what the user asked for) and compares the installed version label against npm's current
# version on that channel. Declared after the install so changing them doesn't invalidate that layer.
ARG AGENT_CHANNEL=${AGENT_VERSION}
ARG BUILD_HASH=
LABEL agent-pod.agent=${AGENT} \
      agent-pod.build=${BUILD_HASH} \
      agent-pod.channel=${AGENT_CHANNEL} \
      agent-pod.version=${AGENT_VERSION}
