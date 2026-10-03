#!/bin/sh
# Self-check for heartbeat-monitor.sh's state machine. Stubs curl and sleep:
# no network, no real files. Run: sh test-heartbeat-monitor.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"

cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
*api.nextdns.io*) [ -n "${FAKE_FAIL:-}" ] && exit 22; printf '%s' "$FAKE_RESP" ;;
*) prev=; for a; do case "$a" in Title:*) echo "${a#Title: }" >> "$NOTIFY_LOG";; esac
     [ "$prev" = -d ] && echo "$a" >> "$NOTIFY_LOG.body"; prev=$a; done ;;
esac
EOF
printf '#!/bin/sh\n' > "$T/bin/sleep"
chmod +x "$T/bin/curl" "$T/bin/sleep"
echo 'http://127.0.0.1:8080/test' > "$T/ntfy-url"

export PATH="$T/bin:$PATH" PROFILE=abc123 SEARCH=heartbeat.example.com \
       STATE_DIR="$T/state" NTFY_URL_FILE="$T/ntfy-url" HEADER_FILE="$T/hdr" \
       NOTIFY_LOG="$T/notified" NAME="DNS forwarder"
STATE_FILE="$T/state/state"; BATT_FILE="$T/state/battery"
HIT='{"data":[{"domain":"hb1.heartbeat.example.com"}],"meta":{}}'
EMPTY='{"data": [], "meta":{}}'
fails=0

step() {  # step <desc> <resp|FAIL> <expected state> <expected notifications or ->
    : > "$NOTIFY_LOG"
    if [ "$2" = FAIL ]; then FAKE_FAIL=1 FAKE_RESP= sh "$HERE/heartbeat-monitor.sh"
    else FAKE_FAIL= FAKE_RESP="$2" sh "$HERE/heartbeat-monitor.sh"; fi
    got_state=$(cat "$STATE_FILE"); got_note=$(paste -sd+ "$NOTIFY_LOG"); [ -z "$got_note" ] && got_note=-
    if [ "$got_state" = "$3" ] && [ "$got_note" = "$4" ]; then echo "ok   $1"
    else echo "FAIL $1: state=$got_state (want $3) note=$got_note (want $4)"; fails=$((fails+1)); fi
}

step "first run, heartbeat seen: silent"   "$HIT"   up    -
step "still up: silent"                    "$HIT"   up    -
step "heartbeat stops: alert"              "$EMPTY" down  "DNS forwarder is silent"
step "still down: no repeat"               "$EMPTY" down  -
step "heartbeat back: recovery"            "$HIT"   up    "DNS forwarder is back"
step "API fails twice: check failing"      FAIL     error "DNS forwarder check failing"
step "still failing: no repeat"            FAIL     error -
step "API back: check working again"       "$HIT"   up    "DNS forwarder check working again"
step "garbage response counts as error"    "<html>" error "DNS forwarder check failing"
rm -f "$STATE_FILE"
step "first run while down: alert"         "$EMPTY" down  "DNS forwarder is silent"

# Battery, carried in the newest heartbeat name (newest first in the API).
bat() { echo "{\"data\":[{\"domain\":\"hb9-b$1.heartbeat.example.com\"},{\"domain\":\"hb8-b99c.heartbeat.example.com\"}],\"meta\":{}}"; }
rm -f "$STATE_FILE" "$BATT_FILE"
step "battery 55% discharging: silent"     "$(bat 55d)" up "-"
step "battery hits 30%: charge alert"      "$(bat 30d)" up "Charge the DNS forwarder"
step "battery 28%: no repeat"              "$(bat 28d)" up "-"
step "plugged in at 29%: re-arms, silent"  "$(bat 29c)" up "-"
step "next discharge hits 30%: alerts"     "$(bat 30d)" up "Charge the DNS forwarder"
step "heartbeat without battery: ignored"  "$HIT"       up "-"
: > "$NOTIFY_LOG.body"
step "goes silent: alert"                  "$EMPTY"     down "DNS forwarder is silent"
if grep -q "Last battery reading: 30%" "$NOTIFY_LOG.body"; then echo "ok   silent alert quotes last battery"
else echo "FAIL silent alert missing last battery: $(cat "$NOTIFY_LOG.body")"; fails=$((fails+1)); fi
echo "ok 40 d" > "$BATT_FILE"
step "back up at 25%: both alerts fire"    "$(bat 25d)" up "Charge the DNS forwarder+DNS forwarder is back"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
