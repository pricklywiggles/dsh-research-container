# Derived image: same crawl4ai, with our config baked in (binds 0.0.0.0 so the
# publish forwarder can reach it; single-file bind mounts are unreliable here).
# Digest-pinned (image verified 2026-08-24; upstream :latest last pushed
# 2026-07-15). Bump deliberately. See docs/09-updating.md.
FROM docker.io/unclecode/crawl4ai@sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690
COPY config.yml /app/config.yml
