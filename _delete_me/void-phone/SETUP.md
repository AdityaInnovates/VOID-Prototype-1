# VOID Phone Link — setup

This connects the VOID app on your Mac and a VOID app on your Android phone, so each can
use the other. It has three parts:

1. **Mac side** — a phone-link server already built into VOID (the `VOID/Phone/*.swift`
   files), listening on `127.0.0.1:47322`.
2. **cloudflared** — a tunnel that publishes that local port at
   `wss://void.adityainnovates.me`, so the phone can reach it from anywhere.
3. **Android app** — in `android/`, a Java app that connects to that address.

Everything is end-to-end over your own Cloudflare tunnel. The Mac only ever accepts a
phone that has paired with a one-time PIN, and after that only one holding the device key.

---

## 1. DNS — what to add

You asked which DNS record to update. It depends on how you run the tunnel. **Use the
first option** — it's the normal, recommended way and needs no fixed IP.

### Option A (recommended): a *named* Cloudflare Tunnel → a CNAME

A named tunnel has a stable ID like `b1c2...-....cfargotunnel.com`. You point your
subdomain at it with **one CNAME record**:

| Type  | Name  | Target                                   | Proxy |
|-------|-------|------------------------------------------|-------|
| CNAME | void  | `<TUNNEL-ID>.cfargotunnel.com`           | Proxied (orange cloud) |

- **Name** is just `void` (Cloudflare fills in `.adityainnovates.me`).
- The **Proxy** must be ON (orange cloud) — that's what terminates TLS for
  `https://void.adityainnovates.me` and gives you the `wss://` endpoint.
- `cloudflared` can create this record for you automatically (below), so you may not have
  to add it by hand at all.

Your domain's DNS must be **on Cloudflare** for this (its nameservers point to Cloudflare).
If `adityainnovates.me` is registered elsewhere but uses Cloudflare DNS, that's fine — the
CNAME goes in the Cloudflare dashboard.

### Option B: a quick trycloudflare tunnel (no DNS at all)

For a first test you can skip the subdomain entirely — `cloudflared` prints a random
`https://something.trycloudflare.com` URL each run. You'd type that (as `wss://…`) into the
phone app. No DNS record, but the URL changes every restart, so it's only for testing.

### Not recommended: an A record to your home IP

You *could* put an `A` record `void → <your public IP>` and forward a port on your router,
but home IPs change, it exposes a port to the internet, and you'd have to get your own TLS
certificate. The tunnel avoids all of that. Don't use this unless you have a static IP and
a reason.

---

## 2. cloudflared on the Mac

Install and log in (once):

```bash
brew install cloudflared
cloudflared tunnel login          # opens the browser, pick adityainnovates.me
```

Create the tunnel and point the subdomain at it (this writes the CNAME from Option A for
you):

```bash
cloudflared tunnel create void
cloudflared tunnel route dns void void.adityainnovates.me
```

Create a config file at `~/.cloudflared/config.yml`:

```yaml
tunnel: void
credentials-file: /Users/adityainnovates/.cloudflared/<TUNNEL-ID>.json

ingress:
  - hostname: void.adityainnovates.me
    service: ws://127.0.0.1:47322
  - service: http_status:404
```

(`cloudflared tunnel create` prints the `<TUNNEL-ID>` and the path to the JSON. Use `ws://`,
not `wss://` — the tunnel adds TLS on the public side.)

Run it, and install it so it starts with the Mac:

```bash
cloudflared tunnel run void          # to test in the foreground
sudo cloudflared service install     # to keep it running
```

Check it: open `https://void.adityainnovates.me` in a browser. A **426 Upgrade Required**
or a WebSocket error means it reached VOID's server (good — that endpoint only speaks
WebSocket). A 502/404 means the tunnel is up but VOID isn't running yet.

---

## 3. Build and install the Android app

Open the `android/` folder in **Android Studio** (it will fetch Gradle + the Android SDK on
first open), then Run onto your phone. Or from the command line with the SDK installed:

```bash
cd android
./gradlew assembleDebug
# APK lands at app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The app needs **minSdk 26** (Android 8.0) or newer.

---

## 4. Pair

1. Start VOID on the Mac and make sure the tunnel is running.
2. In VOID's menu bar, click **Pair a phone…** — it shows a 6-digit PIN for 5 minutes.
3. Open VOID on the phone. The Mac address is pre-filled as
   `wss://void.adityainnovates.me`. Type the PIN, tap **Pair with Mac**.
4. The status line should change to "Connected to <your Mac>". The PIN is now used up; the
   phone holds a long device key for next time.

Then grant the powers you want on the phone's screen — each button is one permission, and
anything you don't grant simply stays unavailable (VOID will say so if you ask for it).

---

## 5. Try it

From the Mac, say or type to VOID:

- "where's my phone" / "find my phone" → the phone rings even on silent; "found it" stops it
- "what's my phone battery"
- "read my messages" / "any notifications"
- "text Mom I'll be late" → VOID reads it back and waits for "yes" before sending
- "where is my phone right now" → turns GPS into a place name
- "turn on the flashlight", "put my phone on silent", "set an alarm for 7 am"
- "open Spotify on my phone"

From the phone (in the app, or however you wire the `ask` tool into a widget/Assistant):
the phone can call `ask` to run any VOID request on the Mac, plus `mac.*` tools —
`mac.open`, `mac.clipboard.get/set`, `mac.media`, `mac.lock`, `mac.say`, `mac.shortcut`,
`mac.screenshot`, `mac.status`.
