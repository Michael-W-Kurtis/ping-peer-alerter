#!/usr/bin/env bash
# ICMP watchdog. Telegram on consecutive failures, reminders, and recovery.
# Healthy ticks log one line and stay silent on Telegram / cron mail.
#
# Cron (every 2 min), path is yours:
#   */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1
set -euo pipefail
export PATH="/usr/bin:/bin"

# Values already in the environment (CLI dry-run) win over this block.
_env_TARGET_HOST="${TARGET_HOST:-}"
_env_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_env_TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
_env_WATCH_NAME="${WATCH_NAME:-}"
_env_TZ="${TZ:-}"
_env_PING_COUNT="${PING_COUNT:-}"
_env_PING_WAIT="${PING_WAIT:-}"
_env_FAIL_THRESHOLD="${FAIL_THRESHOLD:-}"
_env_REMIND_SECS="${REMIND_SECS:-}"
_env_STATE_DIR="${PING_PEER_STATE_DIR:-}"

# =============================================================================
# CONFIG — fill these. Leave empty to fall back to .env (gitignored).
# Do not commit filled tokens or addresses to a public repo.
# =============================================================================
TARGET_HOST=""                 # ICMP address or hostname of the peer
TELEGRAM_BOT_TOKEN=""          # BotFather token
TELEGRAM_CHAT_ID=""            # destination chat id
WATCH_NAME="target"            # label in Telegram text
TZ="UTC"                       # timestamps, e.g. America/New_York

PING_COUNT=3                   # ICMP echoes per probe
PING_WAIT=2                    # seconds to wait for each echo
FAIL_THRESHOLD=3               # consecutive fails before first Telegram
REMIND_SECS=3600               # seconds between down reminders
STATE_DIR="${HOME}/.cache/ping-peer-alerter"
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_cfg_TARGET_HOST="$TARGET_HOST"
_cfg_TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
_cfg_TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
_cfg_WATCH_NAME="$WATCH_NAME"
_cfg_TZ="$TZ"
_cfg_PING_COUNT="$PING_COUNT"
_cfg_PING_WAIT="$PING_WAIT"
_cfg_FAIL_THRESHOLD="$FAIL_THRESHOLD"
_cfg_REMIND_SECS="$REMIND_SECS"
_cfg_STATE_DIR="$STATE_DIR"

if [[ -n "${PING_PEER_ENV:-}" ]]; then
  ENVFILE="$PING_PEER_ENV"
elif [[ -f "${HOME}/.config/ping-peer-alerter.env" ]]; then
  ENVFILE="${HOME}/.config/ping-peer-alerter.env"
elif [[ -f "${HERE}/.env" ]]; then
  ENVFILE="${HERE}/.env"
else
  ENVFILE=""
fi

if [[ -n "$ENVFILE" && -f "$ENVFILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENVFILE"
  set +a
fi
unset github_pat GITHUB_PAT GH_TOKEN GITHUB_TOKEN 2>/dev/null || true

# Precedence: CLI env > CONFIG block (if non-empty) > .env
TARGET_HOST="${_env_TARGET_HOST:-${_cfg_TARGET_HOST:-${TARGET_HOST:-}}}"
TELEGRAM_BOT_TOKEN="${_env_TELEGRAM_BOT_TOKEN:-${_cfg_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}}"
TELEGRAM_CHAT_ID="${_env_TELEGRAM_CHAT_ID:-${_cfg_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}}"
WATCH_NAME="${_env_WATCH_NAME:-${_cfg_WATCH_NAME:-${WATCH_NAME:-target}}}"
TZ="${_env_TZ:-${_cfg_TZ:-${TZ:-UTC}}}"
PING_COUNT="${_env_PING_COUNT:-${_cfg_PING_COUNT:-${PING_COUNT:-3}}}"
PING_WAIT="${_env_PING_WAIT:-${_cfg_PING_WAIT:-${PING_WAIT:-2}}}"
FAIL_THRESHOLD="${_env_FAIL_THRESHOLD:-${_cfg_FAIL_THRESHOLD:-${FAIL_THRESHOLD:-3}}}"
REMIND_SECS="${_env_REMIND_SECS:-${_cfg_REMIND_SECS:-${REMIND_SECS:-3600}}}"
STATE_DIR="${_env_STATE_DIR:-${_cfg_STATE_DIR:-${PING_PEER_STATE_DIR:-${HOME}/.cache/ping-peer-alerter}}}"
STATEFILE="${STATE_DIR}/state"
ALERT_SENT_FILE="${STATE_DIR}/alert_sent"

export TZ

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset — fill CONFIG at top of script or .env}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID unset — fill CONFIG at top of script or .env}"
: "${TARGET_HOST:?TARGET_HOST unset — fill CONFIG at top of script or .env}"

mkdir -p "$STATE_DIR"

if [[ -f "$STATEFILE" ]]; then
  FAILURES=$(cut -d: -f1 < "$STATEFILE")
else
  FAILURES=0
fi
FAILURES=${FAILURES:-0}

send_telegram() {
  local text="$1"
  local resp
  resp=$(curl -sS --max-time 20 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "disable_web_page_preview=true") || die "telegram curl failed"
  printf '%s' "$resp" | grep -q '"ok":true' || die "telegram API: $resp"
}

NOW=$(date +%s)
if ping -c "$PING_COUNT" -W "$PING_WAIT" -q "$TARGET_HOST" >/dev/null 2>&1; then
  UP=1
else
  UP=0
fi

if (( UP == 1 )); then
  if [[ -f "$ALERT_SENT_FILE" ]]; then
    DOWN_FOR=$(( NOW - $(cut -d: -f1 < "$ALERT_SENT_FILE") ))
    send_telegram "$(printf '%s\n' \
      "${WATCH_NAME} recovered" \
      "host: ${TARGET_HOST}" \
      "from: $(hostname)" \
      "was down for: ${DOWN_FOR}s" \
      "time: $(date '+%Y-%m-%d %H:%M:%S %Z')")"
    log "RECOVERY telegram sent name=${WATCH_NAME} down_for=${DOWN_FOR}s"
  elif (( FAILURES > 0 )); then
    log "flap below threshold name=${WATCH_NAME} failures=${FAILURES} (no telegram)"
  else
    log "ok name=${WATCH_NAME}"
  fi
  printf '0:%s\n' "$NOW" > "$STATEFILE"
  rm -f "$ALERT_SENT_FILE"
  exit 0
fi

FAILURES=$((FAILURES + 1))
printf '%d:%s\n' "$FAILURES" "$NOW" > "$STATEFILE"
log "DOWN name=${WATCH_NAME} failures=${FAILURES}/${FAIL_THRESHOLD}"

if (( FAILURES < FAIL_THRESHOLD )); then
  exit 0
fi

SEND=0
if [[ ! -f "$ALERT_SENT_FILE" ]]; then
  SEND=1
else
  LAST_ALERT_TS=$(cut -d: -f1 < "$ALERT_SENT_FILE")
  if (( NOW - LAST_ALERT_TS >= REMIND_SECS )); then
    SEND=1
  fi
fi

if (( SEND == 0 )); then
  exit 0
fi

KIND="DOWN"
if [[ -f "$ALERT_SENT_FILE" ]]; then
  KIND="STILL DOWN"
fi

send_telegram "$(printf '%s\n' \
  "${WATCH_NAME} ${KIND}" \
  "host: ${TARGET_HOST}" \
  "from: $(hostname)" \
  "consecutive failures: ${FAILURES}" \
  "probe: ping -c ${PING_COUNT} -W ${PING_WAIT}" \
  "time: $(date '+%Y-%m-%d %H:%M:%S %Z')")"

printf '%s\n' "$NOW" > "$ALERT_SENT_FILE"
log "telegram ${KIND} sent name=${WATCH_NAME} failures=${FAILURES}"
exit 0
