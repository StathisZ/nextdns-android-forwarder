#!/system/bin/sh
# NextDNS LAN forwarder for a rooted Android device. Magisk service.d script:
# runs as root at boot. Answers plain DNS on port 53 for the LAN and forwards
# it over DoH to a NextDNS profile.
#
# Optionally sends a heartbeat lookup every 10 minutes that carries the battery
# level. heartbeat-monitor.sh, on another machine, looks for it through the
# NextDNS API.
#
# Install as /data/adb/service.d/nextdns.sh (0700 root). See README.md.
# Run "sh nextdns.sh now" to start without the boot delay.

PROFILE="abc123"         # your NextDNS profile ID
HEARTBEAT_DOMAIN=""      # e.g. heartbeat.example.com. Empty = no heartbeat
DISCOVERY_DNS=""         # your router's IP, used to learn client names. Optional

D=/data/adb/nextdns      # nextdns binary, ca.pem and the log live here
BB=/data/adb/magisk/busybox
BAT=/sys/class/power_supply/battery

# Old Android CA stores can't verify NextDNS's certificate chain. When that
# happens the CLI silently falls back to UNENCRYPTED DNS. A current bundle
# avoids it. Refresh ca.pem if the log ever shows x509 errors.
export SSL_CERT_FILE=$D/ca.pem

[ "$1" = now ] || sleep 60   # let Wi-Fi come up
touch $D/nextdns.conf        # flags carry the config; the CLI still wants a file

# Heartbeat: hb<time>-b<percent><c|d>.<domain>, sent straight to the local
# daemon, not Android's resolver (which may pick a secondary). A unique name
# each time, so the cache never answers it. It only reaches the profile over
# DoH, so a plain-DNS fallback shows up in the monitor as silence.
if [ -n "$HEARTBEAT_DOMAIN" ]; then
  ( sleep 30   # let the daemon below start first
    while true; do
      bat=""
      if [ -r $BAT/capacity ]; then
        case "$(cat $BAT/status)" in Charging|Full) st=c ;; *) st=d ;; esac
        bat="-b$(cat $BAT/capacity)$st"
      fi
      $BB nslookup "hb$($BB date +%s)$bat.$HEARTBEAT_DOMAIN" 127.0.0.1 >/dev/null 2>&1
      sleep 600
    done ) &
fi

# Restart on crash: if this stops, the LAN loses its primary DNS.
while true; do
  # -use-hosts=false: an ad blocker's hosts file (e.g. AdAway) must not
  # answer before NextDNS. -control: Android has no /var/run.
  $D/nextdns run \
    -config-file $D/nextdns.conf \
    -control $D/nextdns.sock \
    -profile "$PROFILE" \
    -listen 0.0.0.0:53 \
    -cache-size 10MB \
    -max-ttl 5s \
    -report-client-info \
    ${DISCOVERY_DNS:+-discovery-dns $DISCOVERY_DNS} \
    -use-hosts=false >> $D/nextdns.log 2>&1
  echo "exited $?, restarting $(date)" >> $D/nextdns.log
  # Trim in place, no logrotate. Without -log-queries it barely grows.
  [ "$(wc -l < $D/nextdns.log)" -gt 2000 ] && { tail -n 1000 $D/nextdns.log > $D/nextdns.log.t && mv $D/nextdns.log.t $D/nextdns.log; }
  sleep 10
done
