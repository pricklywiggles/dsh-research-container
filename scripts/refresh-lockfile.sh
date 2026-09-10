#!/bin/bash
# Regenerate the committed profile lockfile after changing a plugin pin.
#
# The build installs the transitive npm tree from profile-pnpm-lock.yaml with
# --frozen-lockfile, so that file must be regenerated whenever a plugin pin
# changes. Otherwise the build fails with ERR_PNPM_OUTDATED_LOCKFILE.
#
# Run this, review the diff (it is a supply-chain change like any other), then
# rebuild with ./run.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# provides USER_UID for the build arg (and the dependency guard)
. lib/config.sh

# The throwaway image is a full dsh-box generation, about 4.8 GB, and nothing
# else ever removes it. The prune afterwards is a cheap sweep for whatever the
# delete leaves dangling; apple/container strands snapshots easily
# (apple/container#2164). Runs on every exit path, the build failure included.
cleanup() {
  container image delete dsh-box-lockrefresh >/dev/null 2>&1 || true
  container image prune >/dev/null 2>&1 || true
  rm -f profile-pnpm-lock.yaml.new
}
trap cleanup EXIT

echo "==> Building a throwaway image that resolves the tree fresh"
container build --dns 1.1.1.1 --no-cache \
  --build-arg REFRESH_LOCK=1 --build-arg UID="$USER_UID" -t dsh-box-lockrefresh . >/dev/null 2>&1 || {
    echo "build failed; run ./run.sh to see the error" >&2; exit 1; }

echo "==> Extracting the resolved lockfile"
container run --rm dsh-box-lockrefresh \
  cat /opt/dsh-seed/profiles/web/pnpm-lock.yaml > profile-pnpm-lock.yaml.new

if diff -q profile-pnpm-lock.yaml profile-pnpm-lock.yaml.new >/dev/null 2>&1; then
  echo "==> No change"; rm -f profile-pnpm-lock.yaml.new
else
  mv profile-pnpm-lock.yaml.new profile-pnpm-lock.yaml
  echo "==> Updated. Review the diff before committing:"
  echo "    git diff profile-pnpm-lock.yaml"
fi
