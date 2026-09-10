#!/bin/bash
# One-shot host setup for the locked-down dsh research container. Idempotent; run it again
# freely. Everything privileged is announced before it runs. Nothing here
# edits system-owned files: /etc/pf.conf, system DNS, routes, and macOS proxy
# settings are untouched. teardown-host.sh reverts all of it.
cd "$(dirname "$0")"
. lib/config.sh

# Homebrew refuses root, and root-run container/brew state lands in the wrong
# user domain. The script escalates by itself exactly where needed.
if [ "$(id -u)" -eq 0 ]; then
  echo "Run as your normal user (no sudo); it will ask for your password when needed." >&2
  exit 1
fi

if [ -z "${MODEL_HOST:-}" ]; then
  echo "MODEL_HOST is not set. Run ./setup.sh first; it finds your model server." >&2
  exit 1
fi

CONTAINER_TARGET_VERSION="1.3.1"
BREW="$BREW_PREFIX/bin/brew"
ANCHOR_DST=/etc/pf.anchors/dsh-egress
WRAPPER_DST=/usr/local/etc/pf-dsh.conf
ALLOWLIST_DST="$BREW_PREFIX/etc/squid-dsh-allowlist.txt"
SQUID_CONF="$BREW_PREFIX/etc/squid.conf"
PF_STATE_FILE=.pf-was-enabled

say() { printf '\n==> %s\n' "$*"; }

# No TTY (e.g. run from Claude Code): sudo can't prompt, so use a GUI dialog.
SUDO_FLAGS=""
if [ ! -t 0 ] && [ -z "${SUDO_ASKPASS:-}" ]; then
  askpass="$(mktemp)"
  cat > "$askpass" <<'EOF'
#!/bin/sh
exec /usr/bin/osascript -e 'text returned of (display dialog "sudo password for dsh host setup" default answer "" with hidden answer with title "dsh setup" buttons {"Cancel", "OK"} default button "OK")'
EOF
  chmod 700 "$askpass"
  export SUDO_ASKPASS="$askpass"
  SUDO_FLAGS="-A"
fi
# announce on stderr so as_root output can be piped safely
as_root() { printf '    sudo %s\n' "$*" >&2; sudo $SUDO_FLAGS "$@"; }
sudo $SUDO_FLAGS -v   # prime the sudo timestamp: one password prompt up front

say "Step 1/6: apple/container ${CONTAINER_TARGET_VERSION}"
installed="$(container --version 2>/dev/null | awk '{print $4}' || true)"
if [ "$installed" = "$CONTAINER_TARGET_VERSION" ]; then
  echo "    already at ${CONTAINER_TARGET_VERSION}"
else
  echo "    installed: ${installed:-none}, upgrading"
  pkg="$(mktemp -d)/container-installer-signed.pkg"
  url="https://github.com/apple/container/releases/download/${CONTAINER_TARGET_VERSION}/container-${CONTAINER_TARGET_VERSION}-installer-signed.pkg"
  curl -fL -o "$pkg" "$url"
  container system stop 2>/dev/null || true
  as_root installer -pkg "$pkg" -target /
  rm -f "$pkg"
  container --version
fi

say "Step 2/6: squid + socat via Homebrew (userland only)"
$BREW list squid >/dev/null 2>&1 || $BREW install squid
$BREW list socat >/dev/null 2>&1 || $BREW install socat

say "Step 3/6: secrets + rendered config"
if [ ! -f secrets.env ]; then
  echo "    generating secrets.env (never committed)"
  { echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Rotate with ./scripts/rotate-secrets.sh."
    echo "CRAWL4AI_TOKEN=$(openssl rand -hex 24)"
    echo "SEARXNG_SECRET=$(openssl rand -hex 32)"; } > secrets.env
  chmod 600 secrets.env
  set -a; . ./secrets.env; set +a
else
  echo "    secrets.env exists, keeping it"
fi

echo "    rendering templates for this machine"
render host/templates/dsh-egress.pf.conf.tmpl   host/rendered/dsh-egress
render host/templates/squid.conf.tmpl           host/rendered/squid.conf
render host/templates/searxng-settings.yml.tmpl host/rendered/searxng/settings.yml
render host/templates/cordis.patch.yml.tmpl     dsh-home/cordis.patch.yml
render host/templates/pf.plist.tmpl             "host/rendered/${LABEL_PREFIX}.pf.plist"
relay_plist() {
  # bash substitution, not sed: __TARGET__ carries user input ($MODEL_HOST)
  local content
  content="$(cat host/templates/relay.plist.tmpl)"
  content=${content//__LABEL__/$1}
  content=${content//__LISTEN_PORT__/$2}
  content=${content//__TARGET__/$3}
  printf '%s\n' "$content" > "host/rendered/.relay.tmpl"
  render "host/rendered/.relay.tmpl" "host/rendered/$1.plist"
  rm -f "host/rendered/.relay.tmpl"
}
relay_plist "${LABEL_PREFIX}.dsh-model-relay"    "$MODEL_RELAY_PORT" "$MODEL_HOST"
relay_plist "${LABEL_PREFIX}.dsh-searxng-relay"  "$SEARXNG_PORT"     "127.0.0.1:$SEARXNG_PORT"
relay_plist "${LABEL_PREFIX}.dsh-crawl4ai-relay" "$CRAWL4AI_PORT"    "127.0.0.1:$CRAWL4AI_PORT"

say "Step 4/6: squid config + allowlist"
# the allowlist is user-edited state: install once, never clobber
[ -f "$ALLOWLIST_DST" ] || cp host/allowlist.txt "$ALLOWLIST_DST"
[ -f "$SQUID_CONF" ] && [ ! -f "$SQUID_CONF.pre-dsh" ] && cp "$SQUID_CONF" "$SQUID_CONF.pre-dsh"
cp host/rendered/squid.conf "$SQUID_CONF"
mkdir -p "$LOG_DIR"
$BREW services restart squid

say "Step 5/6: recording pf's current state (for teardown)"
if [ ! -f "$PF_STATE_FILE" ]; then
  if as_root pfctl -s info 2>/dev/null | head -1 | grep -q Enabled; then
    echo yes > "$PF_STATE_FILE"
  else
    echo no > "$PF_STATE_FILE"
  fi
fi
echo "    pf was enabled before setup: $(cat "$PF_STATE_FILE")"

say "Step 6/6: pf anchor + launchd jobs"

# A LABEL_PREFIX change would otherwise orphan the previous generation of
# root daemons, which keep crash-looping against the same ports forever.
# Discover ours by content (only dsh plists mention these strings) and remove
# any whose label does not match the current prefix.
for old_plist in $(grep -lE 'pf-dsh\.conf|dsh-(model|searxng|crawl4ai)-relay' /Library/LaunchDaemons/*.plist 2>/dev/null); do
  old_label="$(basename "$old_plist" .plist)"
  case "$old_label" in "${LABEL_PREFIX}".*) continue ;; esac
  echo "    removing daemon left by a previous LABEL_PREFIX: $old_label"
  sudo $SUDO_FLAGS launchctl bootout "system/${old_label}" 2>/dev/null || true
  as_root rm -f "$old_plist"
done

as_root mkdir -p /etc/pf.anchors /usr/local/etc
as_root cp host/rendered/dsh-egress "$ANCHOR_DST"
as_root cp host/pf-dsh.conf "$WRAPPER_DST"
as_root pfctl -n -f "$WRAPPER_DST"   # parse check before anything is loaded
as_root pfctl -E -f "$WRAPPER_DST"

for plist in "${LABEL_PREFIX}.pf" "${LABEL_PREFIX}.dsh-model-relay" "${LABEL_PREFIX}.dsh-searxng-relay" "${LABEL_PREFIX}.dsh-crawl4ai-relay"; do
  as_root cp "host/rendered/${plist}.plist" "/Library/LaunchDaemons/${plist}.plist"
  as_root chown root:wheel "/Library/LaunchDaemons/${plist}.plist"
  as_root chmod 644 "/Library/LaunchDaemons/${plist}.plist"
  sudo $SUDO_FLAGS launchctl bootout "system/${plist}" 2>/dev/null || true
  as_root launchctl bootstrap system "/Library/LaunchDaemons/${plist}.plist"
done

say "Done. Active dsh-egress rules:"
sudo $SUDO_FLAGS pfctl -a dsh-egress -sr

# The pf reload above flushed the vmnet NAT that apple/container injects at
# runtime into the com.apple anchor. That kills egress on the open network
# (searxng, crawl4ai) while the locked network is unaffected, so verify.sh
# still passes and the breakage is invisible. Bouncing the container system
# re-injects the NAT. App containers stop here; ./run.sh brings them back.
if container system status >/dev/null 2>&1; then
  say "Re-injecting container NAT that the pf reload flushed"
  container system stop 2>/dev/null || true
  container system start 2>/dev/null || true
fi

echo
echo "Next: ./run.sh (rebuilds and starts the box), then ./verify.sh."
echo "The model relay logs bind retries to $LOG_DIR/${LABEL_PREFIX}.dsh-model-relay.log"
echo "until the dshnet bridge exists (i.e. until the container is running)."
