# nextdns-android-forwarder

A NextDNS forwarder for an old, rooted Android device, with monitoring through the NextDNS API and alerts on your phone through ntfy.

The device answers plain DNS on port 53 for your home network and forwards every query over DNS-over-HTTPS to your NextDNS profile. Your router hands it out as the DNS server. Therefore every device on the LAN gets NextDNS filtering and encrypted DNS, including the ones that can't run a NextDNS app: guests, TVs, smart plugs.

It uses the official [NextDNS CLI](https://github.com/nextdns/nextdns), unmodified. This repository adds the Android integration and the monitoring.

## What's here

- `nextdns.sh` is a Magisk `service.d` script. It starts the NextDNS CLI at boot as root, restarts it if it exits, and optionally sends a heartbeat lookup every 10 minutes.
- `heartbeat-monitor.sh` runs hourly from cron on a separate monitoring machine. It asks the NextDNS API whether the heartbeat arrived in the last hour. When something changes, it posts a message to an [ntfy](https://ntfy.sh) topic, which pushes it to your phone.
- `test-heartbeat-monitor.sh` checks every state transition of the monitor. It stubs `curl` and needs no network.

## Requirements

- An Android device rooted with Magisk, on Wi-Fi.
- The NextDNS CLI build for the device's architecture. Old Intel tablets need `linux_386`, most phones `linux_arm64` or `linux_armv7`.
- A current CA bundle (see the first trap below).
- For monitoring: a NextDNS API key and an always-on monitoring machine (see The monitoring machine).
- For alerts: an ntfy server (the public `ntfy.sh` or your own) and the ntfy app on your phone.

## Install on the device

Download the release from [nextdns/nextdns releases](https://github.com/nextdns/nextdns/releases) and check it against the release's `checksums.txt`. Then, from a computer with adb:

```
adb push nextdns /data/local/tmp/
adb push /etc/ssl/certs/ca-certificates.crt /data/local/tmp/ca.pem
adb push nextdns.sh /data/local/tmp/
adb shell su -c 'mkdir -p /data/adb/nextdns /data/adb/service.d'
adb shell su -c 'mv /data/local/tmp/nextdns /data/local/tmp/ca.pem /data/adb/nextdns/'
adb shell su -c 'mv /data/local/tmp/nextdns.sh /data/adb/service.d/'
adb shell su -c 'chmod 0700 /data/adb/nextdns /data/adb/nextdns/nextdns /data/adb/service.d/nextdns.sh'
adb shell su -c 'chmod 0600 /data/adb/nextdns/ca.pem'
```

The CA path above is Debian's and Ubuntu's. Elsewhere, use the [Mozilla bundle that curl publishes](https://curl.se/docs/caextract.html).

Edit the three settings at the top of `/data/adb/service.d/nextdns.sh`: `PROFILE`, `HEARTBEAT_DOMAIN` and, optionally, `DISCOVERY_DNS`. Then start it without rebooting:

```
adb shell su -c '/data/adb/magisk/busybox setsid sh /data/adb/service.d/nextdns.sh now </dev/null >/dev/null 2>&1 &'
```

Give the device a fixed address in your router (a DHCP reservation), then set that address as the DNS server your router's DHCP hands out. A public secondary keeps the house online if the device goes down. The cost is that clients sometimes use the secondary on their own, unfiltered and unencrypted. Drop it once the device has proved itself.

## Verify

From another machine on the LAN:

```
dig @<device-ip> doubleclick.net +short     # 0.0.0.0 if your profile blocks ads
```

On the device, fetch NextDNS's test page through the forwarder:

```
adb shell su -c '/data/adb/magisk/busybox wget -q -O - https://x$(date +%s).test.nextdns.io/'
```

Expect `"status": "ok"`, `"protocol": "DOH"` and `"clientName": "nextdns-cli"`. The same request over a plain resolver returns `"status": "unconfigured"`.

## Three traps

These cost real time during setup. All three fail quietly.

1. **Silent fallback to unencrypted DNS.** Old Android CA stores can't verify NextDNS's certificate chain. The CLI logs `x509: certificate signed by unknown authority`, then switches to plain DNS on port 53, for example `Switching endpoint: 45.90.28.0:53`. Lookups keep working, so nothing looks wrong. The queries are unencrypted and carry no profile ID, so they're unfiltered as well. The log tags them `none` instead of your profile. The fix is `SSL_CERT_FILE` pointing at a current bundle, which `nextdns.sh` sets. Check for it with `grep -E "x509|Switching endpoint: [0-9.]+:53" /data/adb/nextdns/nextdns.log`.
2. **The device's hosts file answers first.** The CLI's `-use-hosts` defaults to true, so it consults `/etc/hosts` before NextDNS. On a device with a hosts-based ad blocker (AdAway, for example), that blocklist then answers for the whole LAN. The giveaway is blocked names returning the ad blocker's address, often `127.0.0.1`, instead of NextDNS's `0.0.0.0`. `nextdns.sh` passes `-use-hosts=false`.
3. **A leftover ad blocker breaks Android's connectivity check.** Some hosts-based blockers redirect blocked names to a small web server on the device itself. AdAway does this, for example. If the blocklist covers `www.google.com`, Android's captive-portal probe reaches that local server and gets a page instead of an empty `204` reply. Android then decides the network needs a login. It shows "Sign in required" and marks the network "no internet". After a Wi-Fi drop it may refuse to rejoin until that flag expires. On the tested device that meant about two minutes without DNS for the whole LAN. Remove the ad blocker, since NextDNS now does its job. Switch its blocking off first so it restores the hosts file, then uninstall it. Check that its web server didn't survive as an orphan process. With AdAway it did, and had to be killed by hand.

## Monitoring and alerts

The device is on your LAN, so a monitor elsewhere usually can't reach it. NextDNS can, because it sees every query the device forwards. The monitoring therefore runs in a chain:

```
device --heartbeat lookup, over DoH--> NextDNS
                                         ^
                                         | NextDNS API, once an hour
                                         |
                                monitoring machine
                           (heartbeat-monitor.sh, cron)
                                         |
                                         | HTTP POST, only when something changes
                                         v
                                 ntfy topic --push--> ntfy app on your phone
```

### The check

The heartbeat is a lookup for a new name every 10 minutes, such as `hb1791041417-b97d.heartbeat.example.com`. The `-b97d` part means 97% battery, discharging. It's sent straight to the local daemon, so it reaches your profile only when the device is up, the daemon is running and DoH works. Therefore one check for silence catches all of these failures:

| What goes wrong | What the monitor sees |
|---|---|
| Device off, frozen or flat | no heartbeat |
| nextdns daemon crashed | no heartbeat |
| Device off Wi-Fi | no heartbeat |
| Encryption fails and the CLI falls back to plain DNS | no heartbeat in your profile |
| Your internet connection is down | no heartbeat |

Use a domain you control for the heartbeat. Each heartbeat is one query to its authoritative servers.

NextDNS files the heartbeat under a device named `localhost`, because the lookup starts on the device itself. The monitor searches by domain name, so that doesn't matter.

### Alerts through ntfy

[ntfy](https://ntfy.sh) is a push-notification service. A script publishes a message to a topic with a plain HTTP POST, and every phone subscribed to that topic receives it as a notification. The monitor uses it as its only output.

To set it up:

1. Choose a server. The public `https://ntfy.sh` works without an account. A self-hosted ntfy server works the same way.
2. Choose a topic name that nobody can guess, such as the output of `openssl rand -hex 16`. On a public server, anyone who knows the name can read the topic and post to it. Treat it like a password.
3. Install the ntfy app on your phone (Android or iOS) and subscribe to that topic on that server.
4. Save the full topic URL, for example `https://ntfy.sh/3f9c2b7e8a41d06c5b19e7a2c4d8f013`, on the monitoring machine (see The monitoring machine below).
5. Send a test message from the monitoring machine. It should arrive on your phone within seconds.

```
curl -d "test from the DNS forwarder monitor" "$(cat /etc/nextdns/ntfy-url)"
```

The monitor posts only when the state changes, so a long outage produces one alert, not one per hour. These are the messages you can receive:

| Title | Priority | Meaning |
|---|---|---|
| DNS forwarder is silent | high | No heartbeat for an hour. The text quotes the last battery reading. |
| DNS forwarder is back | default | Heartbeats are arriving again. |
| DNS forwarder check failing | default | The API call failed twice: a revoked key, an API outage or a format change. Without it, the monitor could stop working without telling you. |
| DNS forwarder check working again | low | The API answers again. |
| Charge the DNS forwarder | high | Battery at or below `LOW` percent (default 30) and discharging. Sent once per discharge. Charging re-arms it. |

Set `NAME` to change "DNS forwarder" in the titles.

## The monitoring machine

### What it does

The monitoring machine runs `heartbeat-monitor.sh` once an hour. Each run makes one call to the NextDNS API, compares the answer with the previous run, and posts to ntfy if anything changed. It does nothing else.

### What it needs

- It must be on all the time. A VPS, a home server, a NAS or a Raspberry Pi all work.
- It needs outbound HTTPS to `api.nextdns.io` and to your ntfy server.
- It needs cron, a POSIX `sh` and `curl` 7.55 or later. The script reads the API key with `curl -H @file`, which older versions lack.
- Root isn't required. The default file locations below assume root. Point `HEADER_FILE`, `NTFY_URL_FILE` and `STATE_DIR` elsewhere to run it as an ordinary user.

### What it doesn't need

- It never connects to the forwarder or to your LAN. It only talks to NextDNS and ntfy.
- It needs no VPN, no open ports and no access to your router.

### Where to run it

Off-site is better than at home. A machine outside your house keeps checking during a power cut or an internet outage at home, and alerts you to the silence. A machine at home goes down with the house and stays quiet.

Avoid running it on the forwarder itself. A device can't report its own death.

If you self-host ntfy, prefer a monitoring machine other than the ntfy server. Otherwise one failure takes out both the check and the alert.

### What it stores

| File | Contents | Mode |
|---|---|---|
| `/root/heartbeat-monitor.sh` | the script | 0700 |
| `/etc/nextdns/api-header` | one line: `X-Api-Key: <key>` | 0600 |
| `/etc/nextdns/ntfy-url` | the full ntfy topic URL | 0600 |
| `~/.heartbeat-monitor/state` | last result: `up`, `down` or `error` | created by the script |
| `~/.heartbeat-monitor/battery` | last battery reading and alert state | created by the script |

The API key gives full control of your NextDNS account, including filtering settings and logs. Keep it on a machine you trust, readable by root only. Never put it on the forwarder.

### Install

As root on the monitoring machine:

```
install -m 0700 heartbeat-monitor.sh /root/
mkdir -p -m 0700 /etc/nextdns
(umask 077; cat > /etc/nextdns/api-header)   # type "X-Api-Key: " + paste the key, Enter, Ctrl-D
(umask 077; cat > /etc/nextdns/ntfy-url)     # paste the full topic URL, Enter, Ctrl-D
```

The API key comes from your NextDNS account page. The header file needs the whole line, because a bare key gets HTTP 403. Typing both files into `cat` keeps the key and the topic out of your shell history and the process list.

### Test

Run it once by hand, then force the alert path. The second and third commands should each put a notification on your phone:

```
PROFILE=abc123 SEARCH=heartbeat.example.com sh /root/heartbeat-monitor.sh
PROFILE=abc123 SEARCH=no-such-heartbeat sh /root/heartbeat-monitor.sh   # "DNS forwarder is silent"
PROFILE=abc123 SEARCH=heartbeat.example.com sh /root/heartbeat-monitor.sh   # "DNS forwarder is back"
```

The first run should print nothing and leave `up` in `~/.heartbeat-monitor/state`. A result of `error` means the API key or the network path is wrong.

### Schedule

Add it to root's crontab:

```
17 * * * * PROFILE=abc123 SEARCH=heartbeat.example.com /bin/sh /root/heartbeat-monitor.sh
```

Hourly checks mean an alert arrives one to two hours after a failure. That suits a DNS server with a secondary behind it. It's 24 API calls a day.

## Battery

Some ROMs never let the CPU sleep. The one tested here holds a permanent kernel wakelock (`ME176C.DisableSuspend` in `/sys/power/wake_lock`). That suits a DNS server: with the screen off, 24 of 24 probes were answered in under 500 ms. The cost is a constant draw of 150 to 200 mA, about 4 to 5% of a 3,550 mAh battery per hour.

You can keep the device on the charger, or run it on battery and charge when the monitor says so. On the tested device the charger's `sysfs` controls were read-only even for root, so a charge cap wasn't possible.

## What it doesn't cover

- If the monitoring machine is down, nobody checks. If it also hosts your ntfy server, the alerts die with it.
- ntfy only delivers to phones that are subscribed and online. If the ntfy app is stopped or your phone is off, the alerts wait on the server and may expire before you see them.
- A failure of your internet connection looks the same as a failure of the device.
- The heartbeat proves DNS reaches NextDNS from the device. It doesn't prove other clients can reach the device. A secondary DNS in your DHCP covers that gap.

## Tested on

ASUS MeMO Pad 7 (ME176C(X)), Intel Atom Z3745, unofficial LineageOS 16.0 (Android 9), Magisk 26.4, NextDNS CLI 1.47.3 (`linux_386`). The monitor ran on OpenBSD 7.9 with curl 8.21. The self-test passes under OpenBSD's `sh` and Debian's `dash`.

Full write-up: [an old tablet as the house DNS server](https://nevrast.xyz/nextdns-tutorial.html)

## License

MIT. See `LICENSE`. The NextDNS CLI is a separate project under its own license.
