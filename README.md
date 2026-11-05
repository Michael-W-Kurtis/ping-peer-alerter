# ping-peer-alerter

Shell script that periodically pings another server on the network
and informs you via Telegram if it has stopped responding.

Tracked files contain no addresses, tokens, or site names. Put those
in `.env` (gitignored). Start from `.env.example`.

## Behavior

- probe: ping -c 3 -W 2 to TARGET_HOST
- Telegram after 3 consecutive failures (~6 min at a 2-minute cron)
- reminder every 60 minutes while still down
- one recovery message when ping succeeds again
- healthy ticks: one log line, no Telegram

## Setup

    git clone https://github.com/Michael-W-Kurtis/ping-peer-alerter.git
    cd ping-peer-alerter
    cp .env.example .env
    chmod 600 .env
    # edit .env
    chmod 755 ping-peer-alerter.sh
    mkdir -p "$HOME/log"

Required in .env:

    TELEGRAM_BOT_TOKEN
    TELEGRAM_CHAT_ID
    TARGET_HOST   ICMP destination as seen from the watcher
    WATCH_NAME    short label used in Telegram text
    TZ            timezone for timestamps (example: UTC)

Confirm the probe from the watcher:

    ping -c 3 -W 2 "$TARGET_HOST"

Dry-run a down alert against TEST-NET-3 (does not touch your host):

    TARGET_HOST=203.0.113.1 FAIL_THRESHOLD=1 ./ping-peer-alerter.sh
    rm -rf ~/.cache/ping-peer-alerter

Crontab (adjust the path):

    */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1

Env load order: $PING_PEER_ENV, else $HOME/.config/ping-peer-alerter.env,
else .env next to the script.

State: ~/.cache/ping-peer-alerter/
