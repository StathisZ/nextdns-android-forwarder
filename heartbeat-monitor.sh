#!/bin/sh
# heartbeat-monitor.sh — checks, through the NextDNS API, that the forwarder's
# heartbeat is still reaching your profile. Run it hourly from cron on any
# machine with curl. It doesn't need to reach the forwarder itself.
#
# Silence for an hour means the device, its Wi-Fi, the nextdns daemon or its
# DoH is down. A plain-DNS fallback never carries the profile ID, so it can't
# show up in the profile's logs either. The newest heartbeat also carries the
# battery level, so it says when to charge the device (once per discharge).
#
# Notifies via ntfy only on a state change. Settings come from the environment:
#   PROFILE        NextDNS profile ID (required)
#   SEARCH         heartbeat domain, same as HEARTBEAT_DOMAIN in nextdns.sh (required)
#   HEADER_FILE    file holding one line, "X-Api-Key: <key>", mode 0600
#   NTFY_URL_FILE  file holding the full ntfy topic URL, mode 0600
#   STATE_DIR      where state is kept between runs
#   LOW            battery percentage that triggers the charge alert
#   NAME           what to call the device in alerts
# Test the down path with SEARCH=no-such-heartbeat.

: "${PROFILE:?set PROFILE to your NextDNS profile ID}"
: "${SEARCH:?set SEARCH to your heartbeat domain}"
HEADER_FILE="${HEADER_FILE:-/etc/nextdns/api-header}"
NTFY_URL_FILE="${NTFY_URL_FILE:-/etc/nextdns/ntfy-url}"
STATE_DIR="${STATE_DIR:-$HOME/.heartbeat-monitor}"
LOW="${LOW:-30}"
NAME="${NAME:-DNS forwarder}"
API="https://api.nextdns.io/profiles/$PROFILE/logs?search=$SEARCH&from=-1h&limit=10&raw=1"

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state"
BATT_FILE="$STATE_DIR/battery"   # "<ok|low> <percent> <c|d>"

notify() {
    curl -fsS -m 10 \
        -H "Title: $1" \
        -H "Tags: $3" \
        -H "Priority: $4" \
        -d "$2" \
        "$(cat "$NTFY_URL_FILE")" >/dev/null 2>&1
}

query() {
    # -H @file keeps the key out of the process list
    curl -fsS -m 20 -H @"$HEADER_FILE" "$API"
}

# One retry, so a single API blip doesn't page anyone.
RESP=$(query) || { sleep 30; RESP=$(query) || RESP=""; }

if printf '%s' "$RESP" | grep -Eq '"data": *\[ *\{'; then
    CURR="up"
elif printf '%s' "$RESP" | grep -Eq '"data": *\[ *\]'; then
    CURR="down"
else
    CURR="error"   # key revoked, API down, or the response format changed
fi

PREV="unknown"
[ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE")
BPREV="ok"; BLEVEL=""; BCHG=""
[ -f "$BATT_FILE" ] && read -r BPREV BLEVEL BCHG < "$BATT_FILE"

# Battery, from the newest heartbeat (logs come newest first). Re-arms on its
# own once it's charging or back above LOW.
LAST=$(printf '%s' "$RESP" | grep -oE '"domain": *"hb[0-9]+-b[0-9]+[cd]\.' | head -n 1)
if [ -n "$LAST" ]; then
    BLEVEL=$(printf '%s' "$LAST" | sed -E 's/.*-b([0-9]+)[cd]\./\1/')
    BCHG=$(printf '%s' "$LAST" | sed -E 's/.*-b[0-9]+([cd])\./\1/')
    BCURR="ok"
    [ "$BCHG" = "d" ] && [ "$BLEVEL" -le "$LOW" ] && BCURR="low"
    [ "$BCURR" = "low" ] && [ "$BPREV" != "low" ] && notify "Charge the $NAME" \
        "Battery at ${BLEVEL}% and discharging. DNS stops when it runs flat." \
        "battery" "high"
    echo "$BCURR $BLEVEL $BCHG" > "$BATT_FILE"
fi

[ "$CURR" = "$PREV" ] && exit 0

case "$CURR" in
down)
    notify "$NAME is silent" \
        "No heartbeat reached NextDNS in the last hour. The device, its Wi-Fi, the nextdns daemon or its DoH is down.${BLEVEL:+ Last battery reading: ${BLEVEL}%.}" \
        "warning" "high" ;;
error)
    notify "$NAME check failing" \
        "The NextDNS API call failed twice (key, network or API change). Device state unknown." \
        "grey_question" "default" ;;
up)
    [ "$PREV" = "down" ] && notify "$NAME is back" \
        "Heartbeat is reaching NextDNS again." "white_check_mark" "default"
    [ "$PREV" = "error" ] && notify "$NAME check working again" \
        "NextDNS API reachable, heartbeat seen." "white_check_mark" "low" ;;
esac
echo "$CURR" > "$STATE_FILE"
