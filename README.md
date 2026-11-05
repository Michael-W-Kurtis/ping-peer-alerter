# ping-peer-alerter

Shell script that periodically pings another server on the network
and informs you via Telegram if it has stopped responding.

Tracked files contain no addresses, tokens, or site names.

## Config

Fill the CONFIG block at the top of ping-peer-alerter.sh. That is the
intended way to set:

    TARGET_HOST            ICMP destination as seen from the watcher
    TELEGRAM_BOT_TOKEN
    TELEGRAM_CHAT_ID
    WATCH_NAME             short label used in Telegram text
    TZ                     timestamps (example: UTC)
    PING_COUNT             echoes per probe (default 3)
    PING_WAIT              seconds per echo (default 2)
    FAIL_THRESHOLD         consecutive fails before Telegram (default 3)
    REMIND_SECS            seconds between down reminders (default 3600)
    STATE_DIR              default ~/.cache/ping-peer-alerter

Leave a CONFIG value empty to take the same name from a gitignored
.env (see .env.example). Do not commit filled tokens or addresses.

Precedence: CLI environment > CONFIG block (if non-empty) > .env

## Behavior

- probe: ping -c PING_COUNT -W PING_WAIT to TARGET_HOST
- Telegram after FAIL_THRESHOLD consecutive failures
- reminder every REMIND_SECS while still down
- one recovery message when ping succeeds again
- healthy ticks: one log line, no Telegram

## Setup

    git clone https://github.com/Michael-W-Kurtis/ping-peer-alerter.git
    cd ping-peer-alerter
    chmod 755 ping-peer-alerter.sh
    mkdir -p "$HOME/log"
    # edit the CONFIG block at the top of ping-peer-alerter.sh

Confirm the probe from the watcher:

    ping -c 3 -W 2 "$TARGET_HOST"

Dry-run a down alert against TEST-NET-3 (does not touch your host):

    TARGET_HOST=203.0.113.1 FAIL_THRESHOLD=1 ./ping-peer-alerter.sh
    rm -rf ~/.cache/ping-peer-alerter

Crontab (adjust the path):

    */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1

Optional env file: $PING_PEER_ENV, else $HOME/.config/ping-peer-alerter.env,
else .env next to the script.
