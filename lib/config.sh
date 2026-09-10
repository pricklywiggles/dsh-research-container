# Shared configuration loader. Source this, do not execute it.
#
#   . "$(dirname "$0")/lib/config.sh"
#
# Precedence, lowest to highest: defaults here, config.env, the environment.
# That last step lets a one-off override work without editing a file:
#
#   MODEL_HOST=10.0.0.9:8090 ./run.sh
#
# Secrets live in secrets.env, which setup-host.sh generates and which is
# never committed. Everything about your machine (username, uid, Homebrew
# prefix) is detected rather than configured, because asking someone their own
# username is a good way to get it wrong.

set -euo pipefail

# Dependency guard for the scripts that source this. macOS ships neither jq nor
# python3; failing here beats a command-not-found from three pipes deep.
require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing dependency: $1" >&2
  echo "Install it with:  brew install ${2:-$1}" >&2
  exit 1
}

DSH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Capture real environment overrides before the files load. A fixed list of
# names rather than filtering `set` output: `set` also prints shell functions,
# and an exported function whose name matched a prefix used to reach the eval
# below as a syntax error. printf %q makes any value safe to re-apply.
__env_before=""
for __v in MODEL_HOST MODEL_ID MODEL_API_KEY SUBNET SUBNET6 UI_PORT SQUID_PORT \
           MODEL_RELAY_PORT SEARXNG_PORT CRAWL4AI_PORT LABEL_PREFIX DSH_CPUS \
           DSH_MEMORY BUILDER_CACHE_MAX_GB CRAWL4AI_TOKEN SEARXNG_SECRET; do
  if [ "${!__v+set}" = set ]; then
    __env_before="${__env_before}${__v}=$(printf '%q' "${!__v}") "
  fi
done
unset __v

if [ -f "$DSH_ROOT/config.env" ]; then
  set -a; . "$DSH_ROOT/config.env"; set +a
elif [ -f "$DSH_ROOT/config.example.env" ]; then
  echo "config.env not found; using defaults from config.example.env." >&2
  echo "Run: cp config.example.env config.env" >&2
  set -a; . "$DSH_ROOT/config.example.env"; set +a
fi

if [ -f "$DSH_ROOT/secrets.env" ]; then
  set -a; . "$DSH_ROOT/secrets.env"; set +a
fi

# Re-apply the environment after BOTH files, so a one-off override outranks
# secrets.env too, exactly as the header promises.
if [ -n "$__env_before" ]; then eval "export $__env_before"; fi
unset __env_before

# --- detected, never configured ----------------------------------------------

USER_NAME="$(id -un)"
USER_UID="$(id -u)"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"

# --- derived ------------------------------------------------------------------

# The gateway is the .1 host of SUBNET. Derived so the two can never disagree.
GATEWAY="$(printf '%s' "${SUBNET:-192.168.66.0/24}" | awk -F'[./]' '{print $1"."$2"."$3".1"}')"

MODEL_HOST="${MODEL_HOST:-}"   # no default on purpose; see config.example.env
MODEL_ID="${MODEL_ID:-qwen38}"
LABEL_PREFIX="${LABEL_PREFIX:-local.dshbox}"
BUILDER_CACHE_MAX_GB="${BUILDER_CACHE_MAX_GB:-25}"
LOG_DIR="$BREW_PREFIX/var/logs"

export DSH_ROOT USER_NAME USER_UID BREW_PREFIX GATEWAY MODEL_HOST MODEL_ID LABEL_PREFIX BUILDER_CACHE_MAX_GB LOG_DIR

# --- template rendering -------------------------------------------------------

# Substitute ${VAR} placeholders in a template. Deliberately not envsubst
# (a gettext dependency), not `eval` (would execute backticks in a template),
# and not sed (a value containing | or & breaks or corrupts the output): pure
# bash string replacement treats both sides literally. Every variable the
# template references must be set and non-empty, so a missing secret fails the
# render instead of writing an empty Bearer token or secret_key.
render() {
  local src="$1" dst="$2" content v val
  content="$(cat "$src")"
  for v in $(grep -oE '\$[{][A-Z0-9_]+[}]' "$src" | tr -d '${}' | sort -u); do
    val="${!v-}"
    if [ -z "$val" ]; then
      echo "render: $src references \${$v}, which is unset or empty" >&2
      return 1
    fi
    content=${content//"\${${v}}"/$val}
  done
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
}
