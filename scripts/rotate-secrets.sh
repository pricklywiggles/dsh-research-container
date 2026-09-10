#!/bin/bash
# Rotate the two generated secrets and re-render everything that embeds them.
# The new values go straight into secrets.env and are never printed.
#
# No backup of the old file is kept on purpose: a copy of a rotated secret is a
# liability, and rotating again is free if something goes wrong.
#
# Three things hold these values, so all three have to be recreated afterwards:
# searxng reads secret_key from its mounted settings.yml, crawl4ai takes its
# token as an env var set at creation, and dsh reads the Authorization header
# out of cordis.patch.yml when it boots. ./run.sh does all three.
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/config.sh

require openssl

if [ ! -f secrets.env ]; then
  echo "secrets.env not found. ./setup-host.sh generates it on a first install." >&2
  exit 1
fi

{ echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/rotate-secrets.sh."
  echo "# CRAWL4AI_TOKEN gates crawl4ai's non-loopback bind; SEARXNG_SECRET signs"
  echo "# searxng's session cookies. Both stay on this Mac and the container"
  echo "# subnet, never the LAN. Rotate with ./scripts/rotate-secrets.sh."
  echo "CRAWL4AI_TOKEN=$(openssl rand -hex 24)"
  echo "SEARXNG_SECRET=$(openssl rand -hex 32)"
} > secrets.env
chmod 600 secrets.env

# Re-read so render() substitutes the new values rather than the old ones
# lib/config.sh already loaded.
set -a; . ./secrets.env; set +a

render host/templates/searxng-settings.yml.tmpl host/rendered/searxng/settings.yml
render host/templates/cordis.patch.yml.tmpl     dsh-home/cordis.patch.yml

echo "Rotated. Nothing was printed; the values live in secrets.env (0600)."
echo "Apply them:  ./run.sh"
