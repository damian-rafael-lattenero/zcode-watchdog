# The dead man's switch — GitHub Actions edition
#
# The bot runs 100% on the owner's Mac. When the Mac's cable dies, the
# component that would report it is dead with it — nothing ON the Mac
# can announce the Mac's own outage, and nothing "lives" in Telegram
# (bots are pull-driven). So the vigilante lives OUTSIDE the failure
# domain: GitHub's runners.
#
#   Mac (every 60 s)                    GitHub Actions (always watching)
#   ┌──────────────────┐    gist push   ┌─────────────────────────────┐
#   │ beacon.nu ───────┼───────────────►│ cron every 5 min, job polls │──sendMessage──► 📱
#   │ (zcode-bot-kotlin│   (unlisted)   │ the gist every 30 s for 4 m │  (bot token,
#   │  repo, Mac side) │                │ stale > 150 s = 💀          │   send-only)
#   └──────────────────┘                └─────────────────────────────┘
#
# Detection: ~2-4 minutes from death to the phone buzzing.

## The alerts

| Message | Meaning |
|---------|---------|
| `💀 la Mac no late hace X min` | Beacon stale > 150 s (3 missed 1-min heartbeats): internet cut, Mac asleep, or Mac dead — from outside they are indistinguishable, and all three mean the bot is down. Repeats every ~5 min while dead (never radio silence, capped 12/hour). |
| `⚠️ Mac viva pero su poller a Telegram falla` | Beacon fresh BUT the daemon logged `getUpdates failed` recently — the Mac reaches GitHub yet not Telegram. |
| `🔌 la Mac volvió a latir` | Recovery seen within a job's watch window. |
| `🟡 watchdog vivo` | Once a day (~09:00 ART): proof the watchdog itself is alive. A dead watchdog must also be visible. |

## Knobs

| What | Where | Value |
|------|-------|-------|
| Stale threshold | `watchdog-check.nu` `STALE_AFTER_S` | 150 s (3 missed 1-min beacons) |
| In-job poll | `watchdog-check.nu` `POLL_EVERY_S` | 30 s |
| Job watch window | workflow `--loop-seconds` | 240 s (job total ~4.5 min < cron 5 min, so no backlog) |
| Beacon cadence | Mac side (`zcode-bot-kotlin` `com.zcode.beacon.plist`) | 60 s |

## Secrets (repo settings)

- `WATCHDOG_BOT_TOKEN` — the bot's own token; sending is stateless and
  never conflicts with the Mac's `getUpdates` monopoly.
- `WATCHDOG_CHAT_ID` — the owner's chat.

The gist is unlisted (secret-by-URL) and carries NO secrets — only
timestamps and health flags. This repo is PUBLIC on purpose: Actions
minutes are free and unlimited, and the code has nothing to hide.

## Testing

- Circuit test (no outage needed): Actions → watchdog → Run workflow →
  `simulate_stale_minutes=20` → a `[TEST] 💀` must arrive on the phone.
- Live drill: `launchctl bootout gui/$UID/com.zcode.beacon`, wait ~3 min
  → real 💀 arrives; `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.zcode.beacon.plist`
  → next job sees the heartbeat again.

## Known gaps (accepted, documented)

- Handoff: each job watches 4 of every 5 minutes; GitHub cron jitter can
  stretch worst-case detection to ~5-6 min occasionally.
- A Mac asleep stops the beacon → 💀 says "dormida o muerta" honestly;
  distinguishing those two needs a second beacon inside the LAN, not on
  this Mac.
- GitHub disables scheduled workflows after 60 days without repo
  activity — the daily 🟡 heartbeat makes staleness visible; re-enable
  manually if it ever trips.
