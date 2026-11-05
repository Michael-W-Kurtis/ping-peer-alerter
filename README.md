# ping-peer-alerter

Shell script that periodically pings another server on the network
and informs you via Telegram if it has stopped responding.

All site values live in a gitignored .env. The script sources that
file. Tracked files contain no addresses, tokens, or credentials.

## Config

Copy .env.example to .env, chmod 600, and fill:

    TELEGRAM_BOT_TOKEN
    TELEGRAM_CHAT_ID
    TARGET_HOST            ICMP destination as seen from the watcher
    WATCH_NAME             short label used in Telegram text
    TZ                     timestamps (example: UTC)
    PING_COUNT             echoes per probe (example: 3)
    PING_WAIT              seconds per echo (example: 2)
    FAIL_THRESHOLD         consecutive fails before Telegram (example: 3)
    REMIND_SECS            seconds between down reminders (example: 3600)
    STATE_DIR              e.g. $HOME/.cache/ping-peer-alerter

github_pat may live in the same .env for git push; the script unsets
it after sourcing so cron does not keep a GitHub token.

Precedence: CLI environment > .env

## Behavior

- probe: ping -c PING_COUNT -W PING_WAIT to TARGET_HOST
- Telegram after FAIL_THRESHOLD consecutive failures
- reminder every REMIND_SECS while still down
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

Confirm the probe from the watcher:

    ping -c 3 -W 2 "$TARGET_HOST"

Dry-run a down alert against TEST-NET-3 (does not touch your host):

    TARGET_HOST=203.0.113.1 FAIL_THRESHOLD=1 ./ping-peer-alerter.sh
    rm -rf ~/.cache/ping-peer-alerter

Crontab (adjust the path):

    */2 * * * * $HOME/git/ping-peer-alerter/ping-peer-alerter.sh >> $HOME/log/ping-peer-alerter.log 2>&1

Env file load order: $PING_PEER_ENV, else $HOME/.config/ping-peer-alerter.env,
else .env next to the script.
