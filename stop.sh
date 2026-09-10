#!/bin/bash
# Stop the box and hand the memory back. The inverse of run.sh.
#
#   ./stop.sh           stop the containers and the runtime
#   ./stop.sh --cache   also delete the build cache, freeing tens of GB
#
# Reads no config on purpose: shutting down has to work even when config.env is
# broken, which is one of the times you most want to stop things.
#
# The host side stays up. The relays and squid are idle daemons costing almost
# nothing, they need sudo to touch, and the pf anchor is the lockdown itself.
# teardown-host.sh is the script that removes all of that.
set -uo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  ""|--cache) ;;
  *) echo "usage: ./stop.sh [--cache]" >&2; exit 1 ;;
esac

STORE="$HOME/Library/Application Support/com.apple.container"
disk_now() { du -sh "$STORE" 2>/dev/null | awk '{print $1}'; }
# System-wide, because each container is a VM whose footprint does not show up
# as resident memory of any host process. Summing those processes reports a few
# MB while Activity Monitor shows gigabytes.
free_now() { memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2}'; }

before_disk="$(disk_now)"
before_free="$(free_now)"

for c in dsh crawl4ai searxng; do
  container stop "$c" >/dev/null 2>&1 && echo "stopped $c"
done

# Deleting the builder talks to the apiserver, so the runtime has to be up for
# it. Starting it first matters because the common case for wanting the space
# back is a box that is already stopped, where the delete would otherwise fail
# silently and report success.
if [ "${1:-}" = --cache ]; then
  container system start >/dev/null 2>&1
  if container builder delete -f >/dev/null 2>&1; then
    echo "deleted the build cache; the next ./run.sh builds cold"
  else
    echo "could not delete the build cache" >&2
  fi
fi

# Stopping containers leaves the builder VM, the apiserver and the vmnet
# services running, and those hold most of the memory. Only a system stop ends
# them, which is the step people miss.
container system stop >/dev/null 2>&1 && echo "stopped the container runtime"

sleep 3
printf '\nsystem memory free:        %s -> %s\n' "${before_free:-unknown}" "$(free_now)"
printf 'container storage on disk: %s -> %s\n' "$before_disk" "$(disk_now)"
[ "${1:-}" = --cache ] || printf '\nDisk is unchanged by design. ./stop.sh --cache frees the build cache.\n'
echo "Start it all again with ./run.sh"
