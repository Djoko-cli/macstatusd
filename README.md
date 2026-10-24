[![English](https://img.shields.io/badge/lang-English-F65801.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Fran%C3%A7ais-lightgrey.svg)](README.fr.md)

# macstatusd 0.5

macOS daemon that exposes the Mac's ON/OFF state to Homebridge (plugin
[http-webhooks](https://github.com/benzman81/homebridge-http-webhooks)), and
accepts ON/OFF commands coming from HomeKit.

Code comments, logs and diagnostic output are in French.

```
HomeKit ──► Homebridge ──► GET /wake | /sleep ──► macstatusd ──► macOS
   ▲                       GET /state  ◄──────────────┤
   └───────── webhook push (state=true|false) ◄────────┘
```

## State semantics

| What the Mac is actually showing                         | State |
|----------------------------------------------------------|-------|
| Unlocked desktop, in an app                              | ON    |
| Lock screen visible (password field)                     | ON    |
| Login window (nobody logged in), display on              | ON    |
| Screen saver running                                     | OFF   |
| Display off (display sleep)                              | OFF   |
| System sleep                                             | OFF   |
| No display connected                                     | OFF   |

In other words: **ON = a user interface is visible and usable**, OFF = nothing
on screen.

## What makes the state deterministic

The 4.x prototypes inferred the state by *reading `loginwindow`'s private log messages*
(`log stream --predicate 'process == "loginwindow"'`) and looking for strings
such as `screenLockUIIsHidden` or `updatePlaceholderString`. That was the root
cause of the problem: those strings are not an API, they change from one macOS
release to the next, a message split across two 4 KB reads is lost, and a flag
stuck at `true` freezes the state forever.

Version 0.5 no longer reads any log. Every fact comes from an observable API, with
an independent fallback source:

| Fact | Primary source | Fallback |
|------|----------------|----------|
| System sleep | IOKit `IORegisterForSystemPower` (event) | `NSWorkspace.didWake` |
| Display off | `CGDisplayIsAsleep` (main display) | all online displays asleep + `screensDidSleep/Wake` |
| Screen saver running | `ScreenSaverEngine` process | on-screen window at `kCGScreenSaverWindowLevel` or above, owned by a screen saver process; `com.apple.screensaver.didstart/didstop` notifications |
| Screen saver **alone on screen** | `IOHIDSystem.HIDIdleTime` compared with its start time | — (see below) |
| Session locked | IORegistry `IOConsoleLocked` / `IOConsoleUsers` | `CGSessionCopyCurrentDictionary` |

### Screen saver running ≠ screen saver on screen

This is the main trap, measured on macOS 26.5 (`diagnostics/saver-probe.swift`):
when a keystroke brings up the password field, **the screen saver keeps running
behind the panel**. In that state:

- the `ScreenSaverEngine` process stays alive;
- `SACScreenSaverIsRunning` (Apple private API) still returns `1`;
- `com.apple.screensaver.didstop` is only posted **on unlock**;
- the list of on-screen windows is unchanged;
- `IsSecureEventInputEnabled` says nothing useful: `loginwindow` can hold secure
  input long after an unlock.

The only signal that changes is hardware activity. Since on macOS **any
keystroke or movement dismisses the screen saver**, the rule is:

> the screen saver occupies the screen if it is running **and** no keyboard /
> mouse activity has happened since it started.

`HIDIdleTime` is readable while the session is locked, which makes the rule
usable exactly where it is needed. Prolonged inactivity
(`saver_redisplay_idle_seconds`, 90 s) re-arms the screen saver, since macOS
goes back to it when the panel is left unanswered.
`saver_dismiss_on_input: false` disables the rule, and the unit tests
(`swift test`, `ScreenSaverOracleTests`) verify it without a real screen saver.

Resulting properties:

- **No stored state that can get stuck.** Facts are re-read on every cycle;
  notifications only make reactions faster, they are never the sole source of
  truth.
- **Explicit debouncing.** A change is only published after a stability period
  (`settle_on_ms` / `settle_off_ms`), which absorbs transient states (a
  one-second black screen while locking, for example).
- **Self-healing.** A gap in the polling loop (sleep, freeze, overload) is
  detected and triggers a full resync.
- **OFF pushed *before* sleep.** IOKit lets the daemon hold off sleep long
  enough to send the webhook; otherwise HomeKit would stay ON during the whole
  sleep.
- **Commands verified against facts.** A HomeKit command with no observable
  effect is escalated, then abandoned with a warning, and the state goes back to
  reality instead of lying.
- **Heartbeat.** The state is republished periodically: a lost webhook or a
  restarted Homebridge cannot leave HomeKit out of sync.

The "locked with no field visible" case is treated as ON by default (the lock
screen *is* an accessible UI). `require_auth_ui_when_locked: true` reverses that
choice by requiring secure input to be active.

## Installation

```bash
./scripts/install.sh
```

**Without `sudo`.** The script elevates privileges itself for `/opt/macstatusd`
and nothing else: run entirely as root, `$UID` is 0 and
`launchctl bootstrap gui/0` fails with "Domain does not support specified
action" (a LaunchAgent belongs to a user's graphical session). If you call it
with `sudo` anyway, it re-runs itself as `$SUDO_USER`.

It builds in release mode, installs `/opt/macstatusd/macstatusd`, creates
`/opt/macstatusd/config.json` if it doesn't exist, then loads the LaunchAgent
`~/Library/LaunchAgents/com.djoko.macstatusd.plist` and checks that the endpoint
responds.

**LaunchAgent (Aqua session), not LaunchDaemon**: that is what gives access to
display state, screen saver notifications and secure input. Consequence:
macstatusd doesn't run before login (after a reboot, Homebridge can't read
`/state` until someone has logged in). Session locking, on the other hand, is
read through the IORegistry and would also work from a LaunchDaemon.

Uninstall: `./scripts/uninstall.sh` (add `--purge` to also remove the
configuration and logs).

## Endpoints

| Route | Effect |
|-------|--------|
| `GET /state` | `1` (ON) or `0` (OFF) — the published state, identical to the last webhook |
| `GET /status` | JSON diagnostics: raw facts, evidence, pending command, webhook state |
| `GET /health` | `OK` |
| `GET /sleep` (`/off`) | HomeKit OFF command |
| `GET /wake` (`/on`) | HomeKit ON command |
| `GET /resync` | republishes the current state to Homebridge |

### Access control

`/health` is always served, without any check. Every other route goes through
these checks, in this order (the first refusal answers):

1. **`Host` header.** Accepted: an IPv4 or IPv6 literal, `localhost`, the Mac's
   own `.local` names (Bonjour name and host name) and the names listed in
   `allowed_hosts`. Any other name gets `403` (protection against DNS
   rebinding). A request without `Host` (HTTP/1.0) passes; an empty or
   malformed `Host` is refused.
2. **Browser requests.** An `Origin` header, or a `Sec-Fetch-Site` other than
   `none`, gets `403`: a web page open on the Mac cannot drive the daemon, with
   or without the token.
3. **Method.** Commands accept `GET` only; `/state` and `/status` accept `GET`
   and `HEAD`. Anything else gets `405`.
4. **Token.** Sent in the `X-Auth-Token` header or as
   `Authorization: Bearer <token>`. `?token=` in the URL is refused unless
   `allow_query_token` is `true` (a token in a URL ends up in logs and
   history).
   - With `auth_token` set: a command needs the right token (`401`
     otherwise). `/state` and `/status` are free from the loopback interface
     and need the token from any other machine.
   - Without `auth_token`: only loopback clients are served; every other
     client gets `403`, for commands and reads alike.

Unknown paths get `404`, whoever asks.

```bash
curl -H "X-Auth-Token: jeton-essai-0123456789abcdef" http://192.0.2.10:9090/wake
curl -H "Authorization: Bearer jeton-essai-0123456789abcdef" http://192.0.2.10:9090/state
```

## Configuration

`/opt/macstatusd/config.json` — every key is optional; a missing or invalid key
falls back to its default without preventing startup.

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `false` | enables webhooks to Homebridge |
| `webhook_base_url` | `""` | e.g. `http://192.0.2.10:51828` |
| `accessory_id` | `"mac"` | `accessoryId` sent to the plugin |
| `port` | `9090` | HTTP port |
| `bind_address` | `""` | `""` = all interfaces, `127.0.0.1` = loopback |
| `auth_token` | `""` | token for commands and for reads from another machine; empty = only loopback clients are served |
| `allow_query_token` | `false` | also accepts the token as `?token=…` in the URL |
| `allowed_hosts` | `[]` | extra names accepted in the `Host` header (list of strings) |
| `off_action` | `"screensaver"` | `screensaver`, `display_sleep` or `system_sleep` |
| `off_escalate_to_display_sleep` | `true` | if the OFF action has no observed effect |
| `stop_screensaver_on_wake` | `true` | terminates the screen saver on ON |
| `command_confirm_timeout_ms` | `12000` | delay before giving up on a command |
| `command_escalate_after_ms` | `2500` | delay before escalating a command with no effect |
| `saver_dismiss_on_input` | `true` | activity after the screen saver started → ON |
| `saver_dismiss_grace_ms` | `1500` | margin ignored right after the start |
| `saver_redisplay_idle_seconds` | `90` | inactivity after which the screen saver is deemed back on screen |
| `poll_interval_ms` | `500` | how often facts are re-read |
| `settle_on_ms` / `settle_off_ms` | `300` / `800` | stability required before publishing |
| `heartbeat_seconds` | `60` | periodic republication (`0` = disabled) |
| `require_auth_ui_when_locked` | `false` | locked with no field visible → OFF |
| `webhook_timeout_ms` / `webhook_retries` | `4000` / `3` | delivery robustness |
| `log_level` | `"info"` | `error`, `warn`, `info`, `debug` |
| `log_file` | `""` | `""` = `~/Library/Logs/macstatusd/macstatusd.log` |
| `off_command` / `wake_command` | `[]` | replace the built-in action (argv, or a string passed to `sh -c`) |

### Choosing the OFF action

`off_action` decides what HomeKit → OFF does:

- `screensaver` (default) — starts the screen saver. The Mac stays awake and
  reachable, so **HomeKit ON can actually turn it back on**.
- `display_sleep` — turns the display off (`pmset displaysleepnow`). Same
  property.
- `system_sleep` — real sleep (`pmset sleepnow`). Beware: during sleep the
  daemon is frozen and `/wake` is never received; Homebridge needs Wake-on-LAN
  to turn the Mac back on.

If the session is already locked, `screensaver` turns the display off instead:
measured on macOS 26, `open -a ScreenSaverEngine` has no effect on a locked
session. An OFF received while the Mac is already OFF triggers no action.

In all three cases the published state becomes OFF, and the command is only
considered successful once the facts confirm it.

## Homebridge

Plugin `homebridge-http-webhooks`, switch accessory:

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "switches": [
    {
      "id": "mac",
      "name": "Mac",
      "on_url": "http://<mac-ip>:9090/wake",
      "on_method": "GET",
      "off_url": "http://<mac-ip>:9090/sleep",
      "off_method": "GET"
    }
  ]
}
```

`webhook_base_url` in `config.json` must point to that `webhook_port`, and
`accessory_id` must match `id`.

Commands sent from another machine require `auth_token` to be set and sent in a
header (see [Access control](#access-control)): without a token, only loopback
clients are served.

## Diagnostics

```bash
/opt/macstatusd/macstatusd --once      # state + facts as JSON, then exits
/opt/macstatusd/macstatusd --watch     # continuous table of facts
curl -s localhost:9090/status          # full view of the running instance
tail -f ~/Library/Logs/macstatusd/macstatusd.log
launchctl print gui/$UID/com.djoko.macstatusd
```

`reason` in `/status` tells which rule decided: `desktop-ui`, `lock-screen-ui`,
`login-window-ui`, `display-asleep`, `system-asleep`, `no-display`,
`locked-without-auth-ui`, `screensaver:<evidence>` (for example
`screensaver:process+notification`), `command:on`, `command:off/<action>`.

## Tests

```bash
swift test                               # unit tests of MacStatusCore (rules, engine, webhook, HTTP)
./scripts/selftest.sh                    # runs swift test, then checks on isolated test instances
./scripts/validate-live.sh               # guided validation through the real states
# Diagnostic probe: triggers a real OFF (screen saver) at t≈4 s
swiftc -O -o /tmp/saver-probe diagnostics/saver-probe.swift && /tmp/saver-probe 60
```

`selftest.sh` runs `swift test` first, then starts test instances that are
sealed off from the real daemon: they listen on 127.0.0.1 on ports 19000-19999,
their commands are inert (`/usr/bin/true`) and the webhooks go to a local fake
receiver. It checks the honest fallback of a command with no effect,
authentication and access control, HTTP errors, webhook retries and server
recovery when the port is already taken.

By default it is non-intrusive and **does not start any fake screen saver**: a
fake `ScreenSaverEngine` process is visible to the whole Mac, so a running real
daemon would see it too, switch to OFF and push that to HomeKit and Home
Assistant. The sections that need it (screen saver detection, HomeKit commands
confirmed by the facts, the OFF push) are marked SKIPPED. Environment variables:

- `SELFTEST_FAUX_ECONOMISEUR=1`: plays the fake screen saver, a binary named
  `ScreenSaverEngine` (exactly what the "process" oracle observes). Only with
  the real daemon **stopped**: the script refuses if anything answers on port
  9090.
- `SELFTEST_IGNORER_VERROU=1`: a locked session no longer makes the sections
  that need a lit display be skipped (for example from a remote session).
- `SELFTEST_FORCER_ECRAN_ETEINT=1`: forces the "display off" branch without
  turning anything off.
- `SWIFT_SCRATCH=<folder>`: Swift build folder, kept after the run (otherwise a
  temporary folder, deleted on exit). It must stay outside `~/Documents`: the
  `.xctest` signature fails under iCloud.

If the display is off, the session locked (unless `SELFTEST_IGNORER_VERROU=1`)
or the Mac asleep, the sections that need a lit display are marked SKIPPED
instead of failing.

`validate-live.sh` (run it without `sudo`) asks you to perform the real actions
(lock, start the screen saver, turn the display off, sleep) and automatically
checks what macstatusd reported during each one.

## Known limitations

- **System sleep**: nothing runs during sleep. `/state` is unreachable and
  `/wake` can't wake the Mac — Wake-on-LAN is needed. That's why `off_action`
  defaults to `screensaver`.
- **Before login**: the LaunchAgent isn't loaded yet.
- **Multiple users**: two open sessions mean two instances for a single port;
  the second one retries in a loop without crashing, but the published state is
  the one from the instance holding the port.
- **External display physically switched off**: macOS considers it on, so the
  state stays ON.
- **Screen savers hosted by `legacyScreenSaver`**: detected by the window
  oracle, which requires the graphical session (hence the LaunchAgent).
- **Esc on the lock screen**: dismissing the authentication overlay with Esc
  doesn't bring the state back to OFF right away; it returns to OFF after
  `saver_redisplay_idle_seconds` (90 s) of inactivity, or as soon as the display
  sleeps. No signal telling the hidden overlay apart from the displayed one has
  been identified yet (investigation ongoing with
  `diagnostics/saver-probe.swift`).

## History

`Versionning/` and `backtest+debug/` contain versions 1 to 4.4.4 and the capture
tools that were used to identify the usable signals. `macstatusdV4.4.4.swift`
stays at the root for reference; 0.5 doesn't replace it on disk.

## License

MIT — see [LICENSE](LICENSE).
