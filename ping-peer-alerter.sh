#!/usr/bin/env bash
# ICMP watchdog. Telegram on consecutive failures, reminders, and recovery.
# Healthy ticks log one line and stay silent on Telegram / cron mail.
#
# All site values live in a gitignored .env (see .env.example).
# Cron (every 2 min), path is yours:
#   */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1
set -euo pipefail
export PATH="/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CLI dry-run wins over .env (TARGET_HOST=203.0.113.1 ./ping-peer-alerter.sh)
_cli_TARGET_HOST="${TARGET_HOST:-}"
_cli_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_cli_TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
_cli_WATCH_NAME="${WATCH_NAME:-}"
_cli_TZ="${TZ:-}"
_cli_PING_COUNT="${PING_COUNT:-}"
_cli_PING_WAIT="${PING_WAIT:-}"
_cli_FAIL_THRESHOLD="${FAIL_THRESHOLD:-}"
_cli_REMIND_SECS="${REMIND_SECS:-}"
_cli_STATE_DIR="${STATE_DIR:-${PING_PEER_STATE_DIR:-}}"

if [[ -n "${PING_PEER_ENV:-}" ]]; then
  ENVFILE="$PING_PEER_ENV"
elif [[ -f "${HOME}/.config/ping-peer-alerter.env" ]]; then
  ENVFILE="${HOME}/.config/ping-peer-alerter.env"
elif [[ -f "${HERE}/.env" ]]; then
  ENVFILE="${HERE}/.env"
else
  ENVFILE="${HERE}/.env"
fi

if [[ ! -f "$ENVFILE" ]]; then
  echo "ERROR: missing env file: $ENVFILE (copy .env.example to .env)" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a
source "$ENVFILE"
set +a
unset github_pat GITHUB_PAT GH_TOKEN GITHUB_TOKEN 2>/dev/null || true

TARGET_HOST="${_cli_TARGET_HOST:-${TARGET_HOST:-}}"
TELEGRAM_BOT_TOKEN="${_cli_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TELEGRAM_CHAT_ID="${_cli_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
WATCH_NAME="${_cli_WATCH_NAME:-${WATCH_NAME:-}}"
TZ="${_cli_TZ:-${TZ:-}}"
PING_COUNT="${_cli_PING_COUNT:-${PING_COUNT:-}}"
PING_WAIT="${_cli_PING_WAIT:-${PING_WAIT:-}}"
FAIL_THRESHOLD="${_cli_FAIL_THRESHOLD:-${FAIL_THRESHOLD:-}}"
REMIND_SECS="${_cli_REMIND_SECS:-${REMIND_SECS:-}}"
STATE_DIR="${_cli_STATE_DIR:-${STATE_DIR:-${PING_PEER_STATE_DIR:-}}}"
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

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset in $ENVFILE}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID unset in $ENVFILE}"
: "${TARGET_HOST:?TARGET_HOST unset in $ENVFILE}"
: "${WATCH_NAME:?WATCH_NAME unset in $ENVFILE}"
: "${TZ:?TZ unset in $ENVFILE}"
: "${PING_COUNT:?PING_COUNT unset in $ENVFILE}"
: "${PING_WAIT:?PING_WAIT unset in $ENVFILE}"
: "${FAIL_THRESHOLD:?FAIL_THRESHOLD unset in $ENVFILE}"
: "${REMIND_SECS:?REMIND_SECS unset in $ENVFILE}"
: "${STATE_DIR:?STATE_DIR unset in $ENVFILE}"

# Channel (@name or -100...), user id, or comma-separated mix.
# A @...bot username is a bot, not a channel — Telegram will 403.
CHAT_IDS=()
_raw="${TELEGRAM_CHAT_ID//,/ }"
_raw="${_raw//; / }"
_raw="${_raw//;/ }"
for _id in ${_raw}; do
  [[ -z "$_id" ]] && continue
  if [[ "$_id" =~ ^@.+[Bb][Oo][Tt]$ ]]; then
    die "TELEGRAM_CHAT_ID ${_id} is a bot username. Use a channel @name or numeric -100 id, and add this bot as a channel admin."
  fi
  CHAT_IDS+=("$_id")
done
((${#CHAT_IDS[@]} > 0)) || die "TELEGRAM_CHAT_ID has no destinations"
unset _raw _id

mkdir -p "$STATE_DIR"

if [[ -f "$STATEFILE" ]]; then
  FAILURES=$(cut -d: -f1 < "$STATEFILE")
else
  FAILURES=0
fi
FAILURES=${FAILURES:-0}

send_telegram() {
  local text="$1"
  local chat_id resp
  local fail=0
  for chat_id in "${CHAT_IDS[@]}"; do
    resp=$(curl -sS --max-time 20 -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true") || {
      log "ERROR: telegram curl failed dest=${chat_id}"
      fail=1
      continue
    }
    if printf '%s' "$resp" | grep -q '"ok":true'; then
      log "telegram ok dest=${chat_id}"
    else
      log "ERROR: telegram API dest=${chat_id}: $resp"
      fail=1
    fi
  done
  (( fail == 0 )) || die "telegram send failed for one or more destinations"
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
