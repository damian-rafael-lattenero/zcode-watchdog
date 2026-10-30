#!/usr/bin/env nu
#
# The other half of the dead man's switch — the vigilante that lives
# OUTSIDE the Mac's failure domain. Runs on GitHub Actions: a cron job
# every 5 min, each job polling the Mac's heartbeat gist every 30 s for
# 4 minutes, so the Mac's death is noticed in ~2-4 minutes. Talks to
# Telegram DIRECTLY via sendMessage — stateless, it never fights the
# Mac's getUpdates monopoly (bot ADR-001). Stable-Nushell compatible on
# purpose: the CI runner installs the latest release, not the nightly.

const GIST_RAW = "https://gist.githubusercontent.com/damian-rafael-lattenero/d61ac1dd354d8d69579a2df683db1688/raw/beacon.json"
const STALE_AFTER_S = 150
const POLL_EVERY_S = 30

def now_epoch [] {
    date now | format date "%s" | into int
}

def send [text: string] {
    if ($env.WATCHDOG_BOT_TOKEN? | is-empty) {
        error make {msg: "WATCHDOG_BOT_TOKEN is not set"}
    }
    let url = $"https://api.telegram.org/bot($env.WATCHDOG_BOT_TOKEN)/sendMessage"
    # Explicit JSON: the runner's stable nu does not auto-serialize
    # records in http post (accepted types there: binary, string).
    let body = ({chat_id: ($env.WATCHDOG_CHAT_ID | into string), text: $text} | to json)
    let resp = (http post --content-type "application/json" $url $body)
    if ($resp.ok? != true) {
        error make {msg: $"telegram send failed: ($resp.description? | default 'unknown')"}
    }
    print $"sent: ($text | str substring 0..60)..."
}

def main [--loop-seconds: int = 0, --simulate-stale-minutes: int = 0] {
    # The forced path proves the whole circuit (runner → gist read →
    # Telegram send) without needing a real outage.
    if $simulate_stale_minutes > 0 {
        send $"[TEST] 💀 watchdog: simulación — la Mac llevaría ($simulate_stale_minutes) min sin latir. Si ves esto, el circuito Mac→gist→GitHub→Telegram está vivo."
        return
    }
    mut slept = 0
    mut first = true
    mut alerted_dead = false
    mut warned_poll = false
    loop {
        let beacon = (http get $GIST_RAW | from json)
        let stale_s = ((now_epoch) - ($beacon.epoch | into int))
        let mins = ($stale_s // 60)
        if $stale_s > $STALE_AFTER_S {
            # One 💀 per job (~every 5 min while dead — never radio
            # silence, bounded to 12/hour); the next job re-alerts.
            if not $alerted_dead {
                send $"💀 watchdog: la Mac no late hace ($mins) min — último beacon ($beacon.iso). Internet cortado, Mac dormida o muerta: el bot de Telegram cayó con ella."
                $alerted_dead = true
            }
            $warned_poll = false
        } else if ($beacon.poll_fail_recent? == true) {
            # The Mac reaches GitHub but not Telegram: different disease,
            # different message.
            if not $warned_poll {
                send $"⚠️ watchdog: Mac viva (beacon hace ($mins) min) pero su poller a Telegram falla — la Mac llega a GitHub pero no a Telegram."
                $warned_poll = true
            }
        } else {
            if $alerted_dead {
                send $"🔌 watchdog: la Mac volvió a latir (beacon hace ($mins) min)."
                $alerted_dead = false
            }
            $warned_poll = false
            # Once-a-day proof the watchdog itself is alive (12:00 UTC =
            # 09:00 ART; a delayed cron just skips the day).
            let hm = (date now | format date "%H%M" | into int)
            if ($first and ($hm >= 1200 and $hm < 1210)) {
                send $"🟡 watchdog vivo — Mac latiendo (beacon hace ($mins) min), poller ok."
            }
        }
        $first = false
        $slept = ($slept + $POLL_EVERY_S)
        if ($loop_seconds > 0 and $slept >= $loop_seconds) {
            break
        }
        sleep ($POLL_EVERY_S * 1sec)
    }
}
