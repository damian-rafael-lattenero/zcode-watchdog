# zcode-watchdog — retired

The dead man's switch now lives with the code it watches.

**Runbook:** [zcode-bot-kotlin/docs/beacon-runbook.md](https://github.com/damian-rafael-lattenero/zcode-bot-kotlin/blob/master/docs/beacon-runbook.md)

The primary detector is **healthchecks.io**: the Mac's beacon pings it
every 60 s, and the service sends the Telegram alert when the pings stop.

GitHub Actions' `schedule` degraded to one run every 3–6 hours and could
never detect an outage, so the workflow was removed and the repo retired.
The manual gist diagnostic moved to
`zcode-bot-kotlin/scripts/watchdog-check.nu`.

Nothing here is needed at runtime. This repo is kept only as history and
can be archived or deleted.
