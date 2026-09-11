#!/bin/bash
# Full rollback of setup-host.sh: machine returns to its pre-setup state,
# including whether pf was enabled. Does not touch the container/image/network
# (use `container rm` / `container network rm` for those) or Homebrew packages.
cd "$(dirname "$0")"
. lib/config.sh

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as your normal user (no sudo); it will ask for your password when needed." >&2
  exit 1
fi

PF_STATE_FILE=.pf-was-enabled
SQUID_CONF="$BREW_PREFIX/etc/squid.conf"

say() { printf '\n==> %s\n' "$*"; }

# No TTY (e.g. run from Claude Code): sudo can't prompt, so use a GUI dialog.
# -A is needed whenever there is no TTY, including when the caller exported
# its own SUDO_ASKPASS: without it sudo ignores the helper and dies with
# "a terminal is required to read the password".
SUDO_FLAGS=""
if [ ! -t 0 ]; then
  if [ -z "${SUDO_ASKPASS:-}" ]; then
    askpass="$(mktemp)"
    cat > "$askpass" <<'EOF'
#!/bin/sh
exec /usr/bin/osascript -e 'text returned of (display dialog "sudo password for dsh host teardown" default answer "" with hidden answer with title "dsh teardown" buttons {"Cancel", "OK"} default button "OK")'
EOF
    chmod 700 "$askpass"
    export SUDO_ASKPASS="$askpass"
  fi
  SUDO_FLAGS="-A"
fi
as_root() { printf '    sudo %s\n' "$*" >&2; sudo $SUDO_FLAGS "$@"; }
sudo $SUDO_FLAGS -v

say "Removing launchd jobs"
# Discovered by content rather than built from LABEL_PREFIX, so daemons
# installed under an earlier prefix are torn down too.
for plist_file in $(grep -lE 'pf-dsh\.conf|dsh-(model|searxng|crawl4ai)-relay' /Library/LaunchDaemons/*.plist 2>/dev/null); do
  label="$(basename "$plist_file" .plist)"
  sudo $SUDO_FLAGS launchctl bootout "system/${label}" 2>/dev/null || true
  as_root rm -f "$plist_file"
done

say "Restoring stock pf ruleset from /etc/pf.conf"
as_root pfctl -f /etc/pf.conf
if [ -f "$PF_STATE_FILE" ] && [ "$(cat "$PF_STATE_FILE")" = no ]; then
  echo "    pf was disabled before setup; disabling again"
  as_root pfctl -d
fi
as_root rm -f /etc/pf.anchors/dsh-egress /usr/local/etc/pf-dsh.conf
rm -f "$PF_STATE_FILE"

say "Stopping squid and restoring its original config"
"$BREW_PREFIX/bin/brew" services stop squid || true
if [ -f "$SQUID_CONF.pre-dsh" ]; then
  mv "$SQUID_CONF.pre-dsh" "$SQUID_CONF"
fi

say "Done. /etc/pf.conf was never modified; nothing else to restore."
