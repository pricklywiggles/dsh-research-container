# Dev + DeepSeek Harness box, run under apple/container on the locked-down dshnet.
# Digest-pinned: the :24-bookworm tag moves. This is the image verified
# working on 2026-08-24; bump deliberately, see docs/09-updating.md.
FROM node:24-bookworm@sha256:934240a162082fd8b8a2f90cd5114446443f1eba1c5378f6687167ca405e6584

RUN apt-get update && apt-get install -y --no-install-recommends \
      bat \
      build-essential \
      curl \
      fd-find \
      git \
      jq \
      less \
      openssh-client \
      pipx \
      procps \
      python3 \
      python3-venv \
      ripgrep \
      socat \
      tmux \
      unzip \
      zip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# dsh is a developer preview with breaking changes; upgrades are a deliberate
# version bump here + rebuild, never an in-place update.
ARG DSH_VERSION=0.1.1-rc.2
# supergateway: stdio<->SSE MCP bridge, fallback if dsh's streamable-http
# transport can't speak to crawl4ai's SSE endpoint
RUN npm install -g pnpm supergateway @deepseek-ai/dsh@${DSH_VERSION}

# Plugins live in $DSH_HOME, which is a volume at runtime with no network to
# install from. Install them here into a seed home; the entrypoint syncs the
# seed's profiles/ into the volume whenever .seed-version changes.
#
# Every plugin is pinned to an immutable ref, reviewed on the date noted.
# Floating a spec means the next rebuild silently installs whatever upstream
# pushed: dsh-web-tools floated to 19 commits past its last release and
# shipped an unreleased browser-bridge WebSocket route into this box.
# Re-review before moving any pin. See docs/09-updating.md.
#
#   WEBTOOLS_SHA  = v0.2.0 release tag (2026-08-22), reviewed 2026-08-24.
#                   Deliberately the tag, not main: the bridge is unreleased WIP.
#   RESEARCH_SHA  = head of PR #5's branch (2026-08-16), reviewed 2026-08-23.
#                   Upstream main injects the removed `workflows` service and
#                   hangs the whole web profile at boot; this branch resolves
#                   the engine from the agent's scoped ctx.workflowEngine.
#   SIDEBAR_SHA   = 2026-08-24, security-reviewed the same day. Runs in-process
#                   with filesystem and pty access, so an unreviewed bump is an
#                   unreviewed shell in the box. v0.16.0 held pending quarantine.
ARG WEBTOOLS_SHA=4e319e9cea48d79a6747e9113fedf168aab2cb06
ARG RESEARCH_SHA=1108d4a8f4d9d3b127d3e86524be787861465564
ARG MCP_CLIENT_VERSION=0.0.1-rc.1
ARG SIDEBAR_SHA=4c0da8119b6ca37ce3daf5c102076154a10010de
#   BREAKER_SHA   = 2026-09-01, our own plugin, published the same day. Plain
#                   ESM, no build step, so no allowBuilds entry needed.
ARG BREAKER_SHA=8aa4ffeb0e3df25e186291be8ef8e1f9478a494a
# Pin the transitive tree too: the plugins' own ^ranges (~260 packages) would
# otherwise re-resolve to whatever is newest on every rebuild, so a pinned
# plugin could still pull a changed dependency. Regenerate with
# scripts/refresh-lockfile.sh after any pin change.
# REFRESH_LOCK=1 skips the frozen install so pnpm resolves fresh and
# scripts/refresh-lockfile.sh can extract a regenerated lockfile. Without this
# the refresh path cannot bootstrap a pin change: the frozen install would
# fail on the very lockfile it is trying to replace.
ARG REFRESH_LOCK=0
COPY profile-pnpm-lock.yaml /tmp/pinned-lock.yaml
RUN DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "github:A3Boy/dsh-web-tools#${WEBTOOLS_SHA}" \
    && DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "github:FengHuoLinShan/dsh-deep-research#${RESEARCH_SHA}" \
    && DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "@deepseek-ai/dsh-mcp-client@${MCP_CLIENT_VERSION}" \
    && printf 'allowBuilds:\n  "dsh-better-sidebar@https://codeload.github.com/omdsh-dev/DSH-better-sidebar/tar.gz/%s": true\n  node-pty: true\n' "${SIDEBAR_SHA}" >> /opt/dsh-seed/profiles/web/pnpm-workspace.yaml \
    && DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "github:omdsh-dev/DSH-better-sidebar#${SIDEBAR_SHA}" \
    && DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "github:pricklywiggles/dsh-circuit-breaker#${BREAKER_SHA}" \
    && if [ "${REFRESH_LOCK}" != "1" ]; then \
         cp /tmp/pinned-lock.yaml /opt/dsh-seed/profiles/web/pnpm-lock.yaml \
         && (cd /opt/dsh-seed/profiles/web && pnpm install --frozen-lockfile); \
       fi \
    && echo "dsh-${DSH_VERSION}+web-tools-2+research-4+sidebar-1+breaker-5+locked-2" > /opt/dsh-seed/.seed-version

# run.sh passes the invoking macOS account uid, keeping virtiofs volume files
# owned by that user; 501 is only the first-account default
ARG UID=501
RUN groupadd -g ${UID} dev \
    && useradd -m -u ${UID} -g ${UID} -s /bin/bash dev \
    && mkdir -p /workspace && chown dev:dev /workspace \
    && chown -R dev:dev /opt/dsh-seed

COPY --chmod=755 entrypoint.sh /usr/local/bin/dsh-entrypoint

ENV DSH_HOME=/home/dev/.dsh \
    NODE_USE_ENV_PROXY=1 \
    DSH_TELEMETRY_DISABLED=1 \
    PATH=/home/dev/.local/bin:$PATH

USER dev
WORKDIR /workspace

EXPOSE 3081
ENTRYPOINT ["dsh-entrypoint"]
