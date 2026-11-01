# The dead man's switch — healthchecks.io edition

The bot runs 100% on the owner's Mac. When the Mac's cable dies, the
component that would report it is dead with it — nothing ON the Mac can
announce the Mac's own outage, and nothing "lives" in Telegram (bots are
pull-driven). The detector therefore lives OUTSIDE the Mac's failure
domain: **healthchecks.io**.

```
Mac (every 60 s)                         healthchecks.io (always watching)
┌──────────────────────────┐    ping    ┌──────────────────────────────┐
│ beacon.nu                │───────────►│ check "zcode Mac"            │
│  • heartbeat (primary)   │    /fail   │ period 1 min, grace 1 min    │──► 📱 @HealthchecksBot
│  • gist (diagnostic)     │            │ no ping for 2 min → DOWN     │
└──────────────────────────┘            └──────────────────────────────┘
```

The gist is only for the manual GitHub diagnostic; it is not part of
the healthchecks path.

Detection: **~2 minutes** from the last heartbeat to the phone buzzing,
with no dependency on GitHub Actions.

## Why not GitHub Actions?

GitHub's `schedule` trigger degraded to **one run every 3–6 hours** in
this repo (measured: 16:57, 20:31, 23:41, 05:54 ART; gaps of 3 h 34 m,
3 h 10 m and 6 h 13 m). During a real internet cut there was no job
running, so nothing read the beacon and no alert could be sent. Changing
the cron line did not restore the 5-minute cadence. The schedule has
been removed; the workflow is now manual-only.

## The alerts

| Message | From | Meaning |
|---------|------|---------|
| `DOWN: zcode Mac` | `@HealthchecksBot` | No heartbeat for ~2 min: internet cut, Mac asleep, beacon/launchd dead, or Mac dead — from outside they are indistinguishable, and all mean the bot is down. |
| `UP: zcode Mac` | `@HealthchecksBot` | Heartbeats returned. |
| `DOWN: zcode Mac` (the event log records a `/fail` signal) | `@HealthchecksBot` | The Mac is alive but Telegram is not usable: the live `getMe` probe fails, or the poller's last log event is an unresolved `getUpdates failed` (e.g. 409 Conflict from a second poller). The beacon pings `/fail`; healthchecks.io alerts through **its** bot, a path independent of the Mac's Telegram connection. |
| `💀 watchdog: la Mac no late hace X min` | watchdog workflow (manual only) | Diagnostic path: reads the gist and sends through the second bot token. |
| `[TEST] 💀 watchdog: simulación…` | watchdog workflow (manual only) | Circuit test; proves the gist read and the Telegram send path. |

## Setup (one time)

### 1. Create the check

1. Create a free account at [healthchecks.io](https://healthchecks.io).
2. **Create Check**:
   - **Name:** `zcode Mac`
   - **Schedule:** Simple
   - **Period:** `1 minute`
   - **Grace Time:** `1 minute`
   - **Description:** `Heartbeat from the Mac's beacon.nu every 60 s. /fail means the Mac is alive but Telegram is unreachable or its poller is failing. Runbook: github.com/damian-rafael-lattenero/zcode-watchdog`
3. Copy the check's **Ping URL** (`https://hc-ping.com/<uuid>`).

With period 1 min + grace 1 min, the alert fires ~2 minutes after the
last successful ping. If you see false positives from a flaky network,
raise **Grace Time** to `2 minutes` (alert in ~3 minutes).

### 2. Connect Telegram

1. In Telegram, open **[@HealthchecksBot](https://t.me/HealthchecksBot)** and send `/start`.
2. Tap the confirmation link. healthchecks.io opens in the browser.
3. Select the project and click **Connect Telegram**.
4. In healthchecks.io, open the integration and click **Send test notification**. The message must arrive from **@HealthchecksBot** — not from your own bot.

The alert is sent by healthchecks.io's bot, so it survives a flood
penalty or a connectivity failure on the Mac's own bot token.

### 3. Give the Mac the heartbeat URL

The ping URL is a secret: anyone holding it can forge a heartbeat. It
lives outside both repos, in a `0600` file:

```sh
mkdir -p ~/.zcode/bot-kotlin
printf '%s\n' 'https://hc-ping.com/<uuid>' > ~/.zcode/bot-kotlin/heartbeat.url
chmod 600 ~/.zcode/bot-kotlin/heartbeat.url
```

Verify it before touching launchd:

```sh
curl -fsS "$(cat ~/.zcode/bot-kotlin/heartbeat.url)"
# expected: OK
```

If the answer is `OK (not found)`, the UUID is wrong or the check was
deleted; the beacon's log will say `heartbeat ERROR: check not found`.

The beacon (`zcode-bot-kotlin/scripts/beacon.nu`) reads this file on
every run. No plist change is needed: `com.zcode.beacon.plist` already
runs the script every 60 s.

### 4. Reload the beacon

The `launchctl` domain is the **numeric user ID** (usually `501`), not
the healthchecks UUID. `$(id -u)` prints it; reading the UUID here is
the most common mistake.

```sh
launchctl bootout gui/$(id -u)/com.zcode.beacon 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.zcode.beacon.plist
launchctl kickstart -k gui/$(id -u)/com.zcode.beacon
```

Within 1–2 minutes the healthchecks.io dashboard must show a ping, and
the beacon log must show the run without `heartbeat SKIP`:

```sh
tail -n 5 ~/.zcode/bot-kotlin/logs/beacon.log
```

A missing `heartbeat.url` is logged as
`heartbeat SKIP: no ~/.zcode/bot-kotlin/heartbeat.url`; the gist path
still works, but there is no hosted heartbeat.

## Test the real circuit

1. Stop only the beacon:
   ```sh
   launchctl bootout gui/$(id -u)/com.zcode.beacon
   ```
   If it says `Could not find service`, it is already stopped — that
   is fine for the drill.
2. Wait 2–3 minutes. **`DOWN: zcode Mac` must arrive from @HealthchecksBot.**
3. Bring it back:
   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.zcode.beacon.plist
   ```
   The next heartbeat produces **`UP: zcode Mac`**. After a real
   connectivity outage the green arrives on the first beacon run
   (≤60 s): the live `getMe` probe sees Telegram immediately, and the
   poller's `poller RECOVERED` line clears the log signal — no stale
   window keeps the check down.

The equivalent live drill is turning off the Mac's Wi-Fi for 2–3
minutes. The Mac cannot send anything, but healthchecks.io can: that is
the whole point of the external heartbeat.

## GitHub Actions (manual only)

The workflow no longer has a `schedule:`. It is kept for two jobs:

- **Circuit test:** Actions → **watchdog** → **Run workflow** →
  `simulate_stale_minutes = 20` → a `[TEST] 💀` must arrive.
- **Diagnostic watch:** `simulate_stale_minutes = 0` → polls the gist
  for 4 minutes and alerts on a stale beacon. Useful when you want to
  confirm what the Mac was publishing, not as the primary detector.

The secrets are unchanged:

- `WATCHDOG_BOT_TOKEN` — the watchdog's own bot token; sending is
  stateless and never conflicts with the Mac's `getUpdates` monopoly.
- `WATCHDOG_CHAT_ID` — the owner's chat.

The gist is unlisted (secret-by-URL) and carries NO secrets — only
timestamps and health flags. The repo is PUBLIC on purpose: the code has
nothing to hide.

## Knobs

| What | Where | Value |
|------|-------|-------|
| Heartbeat period | healthchecks.io check | 60 s |
| Heartbeat grace | healthchecks.io check | 60 s (alert ~2 min after the last ping) |
| Beacon cadence | `zcode-bot-kotlin/scripts/com.zcode.beacon.plist` | 60 s |
| Heartbeat URL | `~/.zcode/bot-kotlin/heartbeat.url` | secret, `0600` |
| Telegram `/fail` signal | `beacon.nu` | live `getMe` probe (≤6 s), OR an unresolved `getUpdates failed` inside 60 s |
| Gist stale threshold | `watchdog-check.nu` `STALE_AFTER_S` | 150 s (manual path only) |
| In-job poll | `watchdog-check.nu` `POLL_EVERY_S` | 30 s |
| Job watch window | workflow `--loop-seconds` | 240 s (manual path only) |

## Known gaps (accepted, documented)

- **healthchecks.io is a third party.** If it is down, no heartbeat
  alert is sent. Add a second integration (email is free) as redundancy,
  and keep an eye on [status.healthchecks.io](https://status.healthchecks.io/).
- **The heartbeat proves the beacon ran, not that the bot daemon is
  healthy.** `daemon_log_age_s` and `poll_fail_recent` are diagnostics;
  the only daemon failure promoted to an alert is an unresolved
  `getUpdates failed` (cleared by the poller's own `poller RECOVERED`
  line, and bounded to 60 s) or a failed live `getMe` probe (`/fail`).
  A daemon that dies while the beacon keeps running is not detected by
  this check.
- **A Mac asleep stops the beacon** → the alert says "Mac asleep or
  dead" honestly; distinguishing those two needs a second beacon inside
  the LAN, not on this Mac.
- **The heartbeat URL is a secret.** Anyone with it can forge pings.
  Keep the file `0600`; never commit it to either repo.
- **Free plan limits:** 20 checks and 100 log entries per check. With
  one ping per minute the event log holds ~100 minutes; the alerting
  state is unaffected.
