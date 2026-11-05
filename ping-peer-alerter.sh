#!/usr/bin/env bash
# ICMP watchdog. Telegram on consecutive failures, reminders, and recovery.
# Healthy ticks log one line and stay silent on Telegram / cron mail.
#
# Cron (every 2 min), path is yours:
#   */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1
set -euo pipefail
export PATH="/usr/bin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PING_PEER_ENV:-}" ]]; then
  ENVFILE="$PING_PEER_ENV"
elif [[ -f "${HOME}/.config/ping-peer-alerter.env" ]]; then
  ENVFILE="${HOME}/.config/ping-peer-alerter.env"
elif [[ -f "${HERE}/.env" ]]; then
  ENVFILE="${HERE}/.env"
else
  ENVFILE="${HERE}/.env"
fi
STATE_DIR="${PING_PEER_STATE_DIR:-${HOME}/.cache/ping-peer-alerter}"
STATEFILE="${STATE_DIR}/state"
ALERT_SENT_FILE="${STATE_DIR}/alert_sent"
PING_COUNT="${PING_COUNT:-3}"
PING_WAIT="${PING_WAIT:-2}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
REMIND_SECS="${REMIND_SECS:-3600}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

if [[ ! -f "$ENVFILE" ]]; then
  die "missing env file: $ENVFILE (copy .env.example to .env)"
fi
# shellcheck disable=SC1090
set -a
source "$ENVFILE"
set +a
unset github_pat GITHUB_PAT GH_TOKEN GITHUB_TOKEN 2>/dev/null || true

export TZ="${TZ:-UTC}"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN unset in $ENVFILE}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID unset in $ENVFILE}"
: "${TARGET_HOST:?TARGET_HOST unset in $ENVFILE}"
WATCH_NAME="${WATCH_NAME:-target}"

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
