# The agent image: the shared base (Dockerfile.base, passed in by install.sh as BASE_IMAGE) plus one agent.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The agent to install: install.sh passes its npm package (AGENT_PKG), the version or dist-tag to install
# (AGENT_VERSION) and the name (AGENT). The base is the same for every agent, so both images share its layers.
ARG AGENT_PKG
ARG AGENT_VERSION

# install.sh resolves a dist-tag such as "latest" to a concrete version, so the version literal itself is the
# cache key and this layer caches normally. If resolution fails, install.sh passes CACHEBUST=$(date +%s)
# to force a fresh refetch.
ARG CACHEBUST=1
RUN npm install -g ${AGENT_PKG}@${AGENT_VERSION}

# Recorded for the agent-pod launcher: it only auto-updates images built from the agent's default channel
# (AGENT_CHANNEL, what the user asked for) and compares the installed version label against npm's current
# version on that channel. Declared after the install so changing them doesn't invalidate that layer.
ARG AGENT=
ARG AGENT_CHANNEL=${AGENT_VERSION}
ARG BUILD_HASH=
LABEL agent-pod.agent=${AGENT} \
      agent-pod.build=${BUILD_HASH} \
      agent-pod.channel=${AGENT_CHANNEL} \
      agent-pod.version=${AGENT_VERSION}
