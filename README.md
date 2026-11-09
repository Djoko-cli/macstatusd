[![English](https://img.shields.io/badge/lang-English-F65801.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Fran%C3%A7ais-lightgrey.svg)](README.fr.md)

# macstatusd 0.6

macOS background app that exposes the Mac's ON/OFF state to Home Assistant or
Homebridge (plugin
[http-webhooks](https://github.com/benzman81/homebridge-http-webhooks)), and
accepts ON/OFF commands coming from them. Requires macOS 13 or later, no
external dependency.

Code comments, logs and diagnostic output are in French.

```
Home Assistant / HomeKit ──► GET /wake | /sleep  (X-Auth-Token) ──► macstatusd ──► macOS
        ▲                    GET /state  ◄───────────────────────────┤
        └───────────── webhook push (state=true|false) ◄──────────────┘
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
on screen. Being idle does not make the Mac OFF: a video watched without
touching the keyboard is ON.

## What makes the state deterministic

The 4.x prototypes inferred the state by *reading `loginwindow`'s private log messages*
(`log stream --predicate 'process == "loginwindow"'`) and looking for strings
such as `screenLockUIIsHidden` or `updatePlaceholderString`. That was the root
cause of the problem: those strings are not an API, they change from one macOS
release to the next, a message split across two 4 KB reads is lost, and a flag
stuck at `true` freezes the state forever.

Since version 0.5 macstatusd no longer reads any log. Every fact comes from an
observable API, with an independent fallback source:

| Fact | Primary source | Fallback |
|------|----------------|----------|
| System sleep | IOKit `IORegisterForSystemPower` (event) | `NSWorkspace.didWake` |
| Display off | `CGDisplayIsAsleep` (main display) | all online displays asleep + `screensDidSleep/Wake` |
| Screen saver running | `SACScreenSaverIsRunning` (`login.framework`) | the `ScreenSaverEngine` process among the user's processes, or a screen saver host that appeared after `com.apple.screensaver.didstart` |
| Screen saver **alone on screen** | `IOHIDSystem.HIDIdleTime` compared with its start time | — (see below) |
| Session locked | IORegistry `IOConsoleLocked` / `IOConsoleUsers` | `CGSessionCopyCurrentDictionary`, only if the registry does not answer |

### Screen saver detection

`saver_detection` in `/status` tells how the screen saver is detected: `sac`
(`SACScreenSaverIsRunning`), or `hôte` when that function is missing (fallback on
the host process that appeared after `didstart`). The evidence of an active
screen saver is `sac`, `process` or `notification+hôte`; once it is over it
becomes `écarté-par-activité` (keyboard or mouse), `écarté-par-commande` (HomeKit
or Home Assistant ON) or `réaffiché` (back on screen), then `none`. A
notification alone never makes the Mac OFF, and windows are no longer used as
evidence (no screen recording permission is needed).

### Screen saver running ≠ screen saver on screen

This is the main trap, measured on macOS 26.5 (`diagnostics/saver-probe.swift`):
when a keystroke brings up the password field, **the screen saver keeps running
behind the panel**. In that state:

- the `ScreenSaverEngine` process stays alive;
- `SACScreenSaverIsRunning` still returns `1`;
- `com.apple.screensaver.didstop` is only posted **on unlock**;
- `IsSecureEventInputEnabled` says nothing useful: `loginwindow` can hold secure
  input long after an unlock.

The only signal that changes is hardware activity. Since on macOS **any
keystroke or movement dismisses the screen saver**, the rule is:

> the screen saver occupies the screen if it is running **and** no keyboard /
> mouse activity has happened since it started.

`HIDIdleTime` is readable while the session is locked, which makes the rule
usable exactly where it is needed. The panel counts as ON until 30 s after the
last keystroke (`saver_redisplay_idle_seconds`), then macOS goes back to the
screen saver and the state returns to OFF. `saver_dismiss_on_input: false`
disables the rule, and the unit tests (`swift test`, `ScreenSaverOracleTests`)
verify it without a real screen saver.

The screen saver is started by `SACScreenSaverStartNow` and dismissed by
`SACScreenSaverStopNow`, two functions of the system's private `login.framework`
(called through `dlopen`, `/status` field `saver_start` and `saver_dismissal`).
When a function is missing or returns an error code, macstatusd falls back on
`open -a ScreenSaverEngine` to start it; the dismissal has no equivalent
fallback (`killall ScreenSaverEngine` no longer works on macOS 27), so the ON is
held for at most 30 s. These calls are private APIs that can change with macOS;
the log says which way is used (INFO at start-up, WARN on fallback). If the WARN
"didstart non corroboré" shows up at every screen saver, the session agent of the
system does not answer.

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
- **Commands verified against facts.** A command with no observable effect is
  escalated, then abandoned with a warning, and the state goes back to reality
  instead of lying.
- **Heartbeat.** The state is republished periodically (`heartbeat_seconds`): a
  lost webhook or a restarted receiver cannot leave Home Assistant or HomeKit out
  of sync.

The "locked with no field visible" case is treated as ON by default (the lock
screen *is* an accessible UI). `require_auth_ui_when_locked: true` reverses that
choice by requiring secure input to be active.

## Installation

macstatusd is an app that lives in `~/Applications` and runs a background agent
registered with macOS (`SMAppService`). Nothing needs `sudo`, and the scripts
refuse to run as root.

### From the published archive

1. Download `macstatusd-X.Y.Z.zip` and `SHA256SUMS` from the release page, check
   the checksum (`shasum -a 256 -c SHA256SUMS`) and unzip.
2. Move `macstatusd.app` into `~/Applications` (or `/Applications`; elsewhere the
   state is `not-found`).
3. Double-click it, or register it from a terminal:

   ```bash
   ~/Applications/macstatusd.app/Contents/MacOS/macstatusd --register
   ```

   The agent is registered and its state is printed. A double-click does the
   same, shows an alert that follows the state read afterwards ("macstatusd runs in
   the background. Settings: General > Login Items & Extensions.", or an approval
   request, or "macstatusd could not register: ..." with the reason) and quits. While
   the agent runs, a double-click on the app opens nothing.
4. The first time, macOS asks you to allow the app in **System Settings >
   General > Login Items & Extensions**. Without that, the state stays
   `requires-approval`.

The release is signed with a Developer ID and notarized (see [Signing and
notarization](#signing-and-notarization)). Without a configuration file, the app
listens on `127.0.0.1` only and publishes nothing, and without `auth_token` no
other machine can command it. The archive contains neither `install.sh` nor
`config.example.json`: to get a valid configuration without the repository,
paste this block in a Terminal (it does nothing if the file already exists, and
never prints the token):

```bash
D="$HOME/Library/Application Support/macstatusd"
F="$D/config.json"
mkdir -p "$D"
if [ -e "$F" ]; then echo "config.json already exists: add auth_token to it by hand"; else
  ( umask 077; : > "$F"; chmod 600 "$F"
    printf '{\n  "enabled": false,\n  "webhook_targets": [],\n  "auth_token": "%s"\n}\n' "$(openssl rand -hex 32)" > "$F" )
fi
```

The file is in mode 600 and holds an `auth_token` of 64 hexadecimal characters.
To hand the token to Home Assistant, open the file in an editor and copy the
value from there; do not print it in a shared terminal. The other keys are in
[Configuration](#configuration).

### From the sources

```bash
./scripts/install.sh
```

The script builds in release mode, assembles the app (`outils/assembler-app.sh`),
copies it into `~/Applications`, registers the agent and checks `/health`. Options:

| Option | Effect |
|--------|--------|
| `--app <path.app>` | install that app instead of building one |
| `--ancien-prefixe <folder>` | folder of a 0.5 installation to migrate (default `/opt/macstatusd`) |
| `--anciens-journaux <folder>` | old agent's log folder emptied to the Trash (default `~/Library/Logs/macstatusd`); must be a direct subfolder of `~/Library/Logs/` |
| `--preparer-jeton` | stops after the configuration and the token: no copy, no registration. Without `--ancien-prefixe` it reads `/opt/macstatusd/config.json` (the default) when that file exists |
| `--sans-verification` | does not check `/health` at the end |

Steps, in order:

1. **Configuration**: `~/Library/Application Support/macstatusd/config.json`
   (mode 600) is kept if it exists, migrated from the old installation, or taken
   from `config.example.json` (`enabled: false`, `webhook_targets: []`).
2. **Token**: a token of 64 hexadecimal characters is generated if there is none.
   The script prints "jeton prêt dans <config> (64 caractères)" or "jeton déjà
   présent dans <config>", never the token itself. `--preparer-jeton` stops here,
   so you can hand the token to Home Assistant before installing.
3. **Planned restart**: a `restart-pending` marker is written before the app is
   replaced, so the old process does not publish OFF when it stops. If the agent
   is already loaded, the script says "Agent déjà chargé : marqueur restart-pending posé".
4. **Copy and registration**: the app goes into `~/Applications`, then
   `--register` is run.
5. **Old agent**: removed, see below.
6. **Check**: `GET /health`, on the host taken from `bind_address` (`""`, `::` and
   `0.0.0.0` give `127.0.0.1`) and on the configured port, 20 tries 0.5 s apart.
   Failure prints "macstatusd ne répond pas sur <url>" and exits with code 1.

Exit codes: 0 done (also when approval is pending), 1 failure or refusal, 2 usage.

If the script prints "À autoriser : Réglages Système > Général > Ouverture et
extensions" (registration code 3), it stops with code 0 **before** removing the
old agent and before the check: allow the app in the Settings, then run
`install.sh` again. Right after an installation the `/health` check can also
fail if the old agent was still holding the port: running `install.sh` again is
enough.

### The app in System Settings

macstatusd appears in **System Settings > General > Login Items & Extensions**,
under "Allow in the Background", under the app's name. Switching it off there
stops the agent. Its state can be read at any time:

```bash
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --status-service
```

| State (`service` in `/status`) | Message | Exit code |
|--------------------------------|---------|-----------|
| `enabled` | activé | 0 |
| `requires-approval` | à autoriser : Réglages Système > Général > Ouverture et extensions | 3 |
| `not-registered` | non enregistré : lancer macstatusd --register | 4 |
| `not-found` | introuvable : l'app doit être dans ~/Applications ou /Applications | 5 |
| `unknown` | inconnu (code N) | 1 |

macOS may ask once for access to the **local network** (and possibly for the
firewall) the first time the app contacts another machine: the signature identity
changed with 0.6, so the old answers do not apply. If no prompt appears and the
webhook is confirmed in the log, nothing else is needed.

### Updating from 0.5

`install.sh` migrates a 0.5 installation, read-only for the old folder:

- the old `config.json` is copied, and `webhook_base_url` is converted to
  `webhook_targets` (a 0.5 config that has no token gets one);
- the old agent is found by its content (the property list in
  `~/Library/LaunchAgents` whose `ProgramArguments[0]` is the old binary), never
  by its label, then removed with `launchctl bootout`; its plist and its old logs
  go to the Trash. The script prints "ancien agent retiré (libellé de N
  caractères)";
- the 0.5 logs contain the webhook URL: if you removed the 0.5 agent by hand
  first, they stay where they are, so put them in the Trash yourself;
- the script **prints** the command that removes the old folder
  (`sudo rm -rf <old prefix>`), and never runs it.

"Trash" here means a `mv` into `~/.Trash`: there is no "Put Back" in the Finder.

## Endpoints

| Route | Effect |
|-------|--------|
| `GET /state` | `1` (ON) or `0` (OFF), the published state, identical to the last webhook |
| `GET /status` | JSON diagnostics: raw facts, evidence, pending command, webhook state |
| `GET /health` | `OK` |
| `GET /sleep` (`/off`) | OFF command |
| `GET /wake` (`/on`) | ON command |
| `GET /resync` | republishes the current state to the webhook targets |

Responses: `200` (`OK` for a command), `401` token missing or wrong, `403` `Host`
or origin refused, `404` unknown path, `405` wrong method, `429` burst or too
many failures, `503` invalid configuration. Unknown query parameters
(`?action=WAKE`) are ignored.

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
4. **Token.** See below.

### Token

The token is sent in the `X-Auth-Token` header or as `Authorization: Bearer
<token>`. `?token=` in the URL is refused unless `allow_query_token` is `true`
(a token in a URL ends up in logs and history).

- With `auth_token` set: a command needs the right token (`401` otherwise).
  `/state` and `/status` are free from the loopback interface and need the token
  from any other machine.
- Without `auth_token`: only loopback clients are served; every other client
  gets `403`, for commands and reads alike.

`install.sh` generates the token (32 random bytes in hexadecimal, 64 characters)
into the configuration file, mode 600, and never shows it. To read it yourself:
open `~/Library/Application Support/macstatusd/config.json`. The token is never
written to the log nor shown in `/status`.

```bash
curl -H "X-Auth-Token: <token>" http://192.0.2.10:9090/wake
curl -H "Authorization: Bearer <token>" http://192.0.2.10:9090/state
```

A burst of requests or too many failed attempts from one peer gets `429`, and
the number of simultaneous connections is capped (32 in all, 8 per peer).

## Home Assistant

### Commands

Home Assistant drives the Mac with `GET /wake` and `GET /sleep` and the token in
a header. Example (all values are placeholders):

```yaml
rest_command:
  mac_wake:
    url: "http://192.0.2.10:9090/wake"
    headers:
      X-Auth-Token: !secret mac_token
  mac_sleep:
    url: "http://192.0.2.10:9090/sleep"
    headers:
      X-Auth-Token: !secret mac_token
```

Use a literal IPv4 address in the URL, or a name that `allowed_hosts` accepts.

### State push (webhook)

macstatusd pushes the state at every change, then every `heartbeat_seconds`
(60 by default), to each target of `webhook_targets`:

- `GET`: `<url>?accessoryId=<accessory_id>&state=true|false`;
- `POST`: the URL as is, JSON body `{"accessoryId": "<accessory_id>", "state": true}`.

On the Home Assistant side, a webhook trigger reads `state` and updates an
`input_boolean` that serves as the state of a switch. Example:

```yaml
input_boolean:
  mac_actif:
    name: "Mac"

automation:
  - alias: "Mac state from macstatusd"
    trigger:
      - platform: webhook
        webhook_id: "exemple-identifiant-webhook"
        allowed_methods: [GET, POST]
        local_only: true
    action:
      - service: "input_boolean.turn_{{ 'on' if trigger.query.state == 'true' else 'off' }}"
        target:
          entity_id: input_boolean.mac_actif
```

and in `config.json`:

```json
{
  "enabled": true,
  "webhook_targets": [
    { "url": "http://192.0.2.20:8123/api/webhook/exemple-identifiant-webhook", "method": "GET" }
  ]
}
```

(For a `POST` target, read `trigger.json.state` instead.) A webhook URL can carry
a secret: it is never written to the log in clear and `/status` shows it masked.

## Homebridge

Plugin `homebridge-http-webhooks`, switch accessory. The commands need the token
in the `on_headers` and `off_headers` fields (a JSON string):

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "switches": [
    {
      "id": "mac",
      "name": "Mac",
      "on_url": "http://192.0.2.10:9090/wake",
      "on_method": "GET",
      "on_headers": "{\"X-Auth-Token\": \"<token>\"}",
      "off_url": "http://192.0.2.10:9090/sleep",
      "off_method": "GET",
      "off_headers": "{\"X-Auth-Token\": \"<token>\"}"
    }
  ]
}
```

The push goes to the plugin's `webhook_port`:

```json
{
  "enabled": true,
  "accessory_id": "mac",
  "webhook_targets": [ { "url": "http://192.0.2.30:51828/", "method": "GET" } ]
}
```

`accessory_id` must match the accessory's `id`. `webhook_base_url` (a single GET
target) still works for an existing configuration, but `webhook_targets`
overrides it when both are present.

## Configuration

`~/Library/Application Support/macstatusd/config.json` (`--config <path>` to use
another file; `MACSTATUSD_SUPPORT_DIR` replaces the support folder). Every key is
optional; a missing or invalid key falls back to its default without preventing
startup. A file that cannot be read or is not valid JSON puts the daemon in a
closed degraded mode: loopback only, no push, `503` on commands. No file at all
gives the defaults, still listening on `127.0.0.1` only.

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `false` | enables the webhook pushes |
| `webhook_targets` | `[]` | up to 8 targets `{url, method?, headers?}` (see below) |
| `webhook_base_url` | `""` | legacy single GET target, e.g. `http://192.0.2.30:51828` |
| `accessory_id` | `"mac"` | `accessoryId` sent with every push |
| `port` | `9090` | HTTP port |
| `bind_address` | `""` | `""` or `::` = all interfaces, IPv4 and IPv6, `0.0.0.0` = all interfaces, IPv4 only, `127.0.0.1` = loopback; otherwise a literal IP address (invalid value: warning and loopback) |
| `auth_token` | `""` | token for commands and for reads from another machine; empty = only loopback clients are served |
| `allow_query_token` | `false` | also accepts the token as `?token=…` in the URL |
| `allowed_hosts` | `[]` | extra names accepted in the `Host` header (list of strings) |
| `off_action` | `"screensaver"` | `screensaver`, `display_sleep` or `system_sleep` |
| `off_escalate_to_display_sleep` | `true` | if the OFF action has no observed effect |
| `stop_screensaver_on_wake` | `true` | dismisses the screen saver on ON (native stop) |
| `wake_hold_seconds` | `0` | seconds during which the display does not turn off through inactivity after a confirmed ON on a locked session (0 to 600; ignored when `wake_command` is set) |
| `command_confirm_timeout_ms` | `12000` | delay before giving up on a command |
| `command_escalate_after_ms` | `2500` | delay before escalating a command with no effect |
| `saver_dismiss_on_input` | `true` | activity after the screen saver started → ON |
| `saver_dismiss_grace_ms` | `1500` | margin ignored right after the start |
| `saver_redisplay_idle_seconds` | `30` | inactivity after which the screen saver is deemed back on screen |
| `poll_interval_ms` | `500` | how often facts are re-read (100 to 5000) |
| `settle_on_ms` | `300` | stability required before publishing ON |
| `settle_off_ms` | `800` | stability required before publishing OFF |
| `heartbeat_seconds` | `60` | periodic republication (`0` = disabled) |
| `publish_off_on_exit` | `true` | publish OFF on SIGTERM/SIGINT before exiting, unless a planned restart (`restart-pending` marker in the support folder, valid 10 min) or degraded mode |
| `require_auth_ui_when_locked` | `false` | locked with no field visible → OFF |
| `webhook_timeout_ms` | `4000` | timeout of one delivery |
| `webhook_retries` | `3` | retries after a failed delivery (0 to 10) |
| `log_level` | `"info"` | `error`, `warn`, `info`, `debug` |
| `log_file` | `""` | `""` = `~/Library/Logs/macstatusd/macstatusd.log` |
| `off_command` | `[]` | replaces the built-in OFF action (argv, or a string passed to `sh -c`) |
| `wake_command` | `[]` | replaces the built-in ON action (same forms) |

`off_command` and `wake_command`: a first element that is not an absolute path
to an executable file is ignored, with the WARN "off_command ignoré : <path>
n'est pas un chemin absolu exécutable". Every command that is run is logged:
INFO "<label> terminé (code 0)", WARN when the code differs. The folder name
`macstatusd` comes from the `MacstatusdSupportName` key of the app's `Info.plist`.

### Webhook targets

Each entry of `webhook_targets` is an object:

| Field | Purpose |
|-------|---------|
| `url` | `http://` or `https://` address (required) |
| `method` | `GET` (default) or `POST` |
| `headers` | `{name: value}` object sent with every delivery (for a key or a token) |

An invalid target is dropped with a warning that names it ("webhook_targets :
cible N …"). Header values are never logged nor shown in `/status`.

### Choosing the OFF action

`off_action` decides what OFF does:

- `screensaver` (default): starts the screen saver. The Mac stays awake and
  reachable, so **ON can actually turn it back on**. This is what the "OFF" of
  a smart-home switch should do.
- `display_sleep`: turns the display off (`pmset displaysleepnow`). Same
  property.
- `system_sleep`: real sleep (`pmset sleepnow`). Beware: during sleep the
  daemon is frozen and `/wake` is never received; the controller needs
  Wake-on-LAN to turn the Mac back on.

If the session is already locked, `screensaver` turns the display off instead:
measured on macOS 26, `open -a ScreenSaverEngine` has no effect on a locked
session. An OFF received while the Mac is already OFF triggers no action. In all
three cases the published state becomes OFF, and the command is only considered
successful once the facts confirm it.

## Diagnostics

```bash
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --once     # state + facts as JSON, then exits
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --watch    # continuous table of facts
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --version  # version and provenance (git, date)
curl -s localhost:9090/status                       # full view of the running instance
tail -f ~/Library/Logs/macstatusd/macstatusd.log
```

The log starts with `binaire : sha256 <64 hex>` (fingerprint of the running
binary) and, with `--debug`, a line "raison : A → B" at every change of reason.

### Command-line options

| Option | Effect |
|--------|--------|
| `--config <path>` | JSON configuration file |
| `--port <n>` | overrides the HTTP port (1 to 65535) |
| `--debug` | detailed logging |
| `--foreground`, `-f` | also writes the log to standard output |
| `--once` | prints the state and facts as JSON, then exits |
| `--watch` | prints the state continuously |
| `--no-webhook` | sends no webhook (tests) |
| `--register` | registers the agent with macOS and prints its state |
| `--unregister` | removes the agent and prints its state |
| `--status-service` | prints the agent state (read-only), exit codes in the table above |
| `--agent` | launch by launchd (starts the daemon) |
| `--version`, `-v` | `macstatusd 0.6.0 (git …, <date>)`, or "(compilation inconnue)" |
| `--help`, `-h` | usage, with the resolved configuration path |

### `/status` fields

| Field | Content |
|-------|---------|
| `version` | version of the running binary |
| `state` | published state, `"1"` or `"0"` |
| `reason` | why the published state is what it is (list below) |
| `facts` | raw facts: `system_asleep`, `display_asleep`, `display_evidence`, `displays`, `screensaver_active`, `screensaver_evidence`, `screensaver_running`, `hid_idle_seconds` (−1 when not read), `session_locked`, `lock_evidence`, `console_user_logged_in`, `secure_input_active`… |
| `facts_verdict` | state the facts alone give |
| `facts_reason` | reason of the facts alone |
| `uptime_seconds` | seconds since start |
| `transitions` | number of state changes |
| `poll_interval_ms` | polling period |
| `off_action` | configured OFF action |
| `webhook` | push diagnostics: `enabled`, `detail`, `confirmed`, `desired`, `suspended`, `failures_since_success`, `last_attempt`, `last_success`, and one entry per target in `targets` (masked URL, `method`, `phase`, retries) |
| `session_context` | `aqua` (graphical session) or `headless` |
| `publishing_allowed` | whether pushes are allowed |
| `publishing_reason` | why, or why not |
| `saver_detection` | `sac` or `hôte` (see above) |
| `saver_dismissal` | how the screen saver is dismissed |
| `saver_start` | how it is started: `SACScreenSaverStartNow` or `open -a ScreenSaverEngine` |
| `slow_calls` | system reads that took at least 1 s since start: `{"<name>": {"count": n, "max_seconds": x}}`, `{}` if none |
| `build` | `{"git": …, "built_at": …}`, null if unknown |
| `service` | registration state of the agent (table above) |
| `main_display` | identifier of the main display, or `none` |
| `display_list` | the displays: `id`, `main`, `asleep`, `placeholder` |
| `last_transition` | time of the last state change (when there was one) |
| `pending_command` | command being confirmed: `target`, `source`, `age_seconds`, `escalated` (only while there is one) |
| `shutting_down` | `true` while the daemon is stopping (only then) |

`slow_calls` measures awake time, sleep excluded; a freeze of the process while
the Mac is awake counts. The names are `session`, `ecrans`, `saisie_securisee`,
`inactivite_hid` and `economiseur`. A WARN "appel lent : <name> <duration> s
(seuil 1.0 s)" is written at most once per name and per minute.

`reason` is one of: `desktop-ui`, `lock-screen-ui`, `login-window-ui`,
`display-asleep`, `system-asleep`, `no-display`, `displays-reconfiguring` (no
physical display for less than 5 s: the published state holds),
`locked-without-auth-ui`, `screensaver:<evidence>` (for example
`screensaver:sac`), `command:on`, `command:off/<action>`, `command:off/override`
(with `off_command`). The log line of a transition to OFF caused by the return
of the screen saver ends with "— économiseur réaffiché — faits: …".

## Uninstalling

```bash
./scripts/uninstall.sh [--app <path.app>] [--tout]
```

The script unregisters the agent (`--unregister`) and puts the app in the Trash
(default `~/Applications/macstatusd.app`; the app must be under `~/Applications`).
The configuration (token included) and the logs are kept; `--tout` puts them in the
Trash as well. Nothing is deleted for good: "Trash" is a `mv` into `~/.Trash`
(no "Put Back" in the Finder). The script refuses to run as root and refuses any
path outside `~/Applications` and `~/Library`. Exit codes: 0 done, 1 failure or
refusal, 2 usage.

System Settings can keep listing the app under "Allow in the Background", inactive,
after the uninstall: on macOS 27 the entry was still there hours later. The agent
is gone all the same: `launchctl list | grep macstatusd` no longer shows it.

## Development

### Tests

```bash
swift test                               # unit tests of MacStatusCore (rules, engine, webhook, HTTP, documentation)
./scripts/selftest.sh                    # runs swift test, then checks on isolated test instances
./scripts/validate-live.sh               # guided validation through the real states
```

`DocumentationTests` keeps these READMEs aligned with the code: every key of
`Config.knownKeys` and every top-level field of `/status` must appear between
backticks in both files, and both files must have the same sequence of headings.

`selftest.sh` runs `swift test` first, then starts test instances that are
sealed off from the real daemon: they listen on 127.0.0.1 on ports 19000-19999,
their commands are inert (`/usr/bin/true`) and the webhooks go to a local fake
receiver. By default it is non-intrusive and **does not start any fake screen
saver**: a fake `ScreenSaverEngine` process is visible to the whole Mac, so a
running real daemon would see it too, switch to OFF and push that to Home
Assistant. The sections that need it are marked SKIPPED. Environment variables:

- `SELFTEST_FAUX_ECONOMISEUR=1`: plays the fake screen saver. Only with the real
  daemon **stopped**: the script refuses if anything answers on port 9090.
- `SELFTEST_IGNORER_VERROU=1`: a locked session no longer makes the sections
  that need a lit display be skipped (for example from a remote session).
- `SELFTEST_FORCER_ECRAN_ETEINT=1`: forces the "display off" branch without
  turning anything off.
- `SWIFT_SCRATCH=<folder>`: Swift build folder, kept after the run. It must stay
  outside `~/Documents`: the `.xctest` signature fails under iCloud.

`validate-live.sh` asks you to perform the real actions (lock, start the screen
saver, turn the display off, sleep) and checks what macstatusd reported.

### Building the app

```bash
bash outils/assembler-app.sh [--binaire <path>] [--identifiant <id>] [--nom-support <name>] \
                             [--sortie <folder>] [--icone <icns>] [--signer <identity>|-]
```

It builds `macstatusd.app` (`Contents/MacOS/macstatusd`, `Info.plist`,
`build-info.json`, the icon, and the agent's plist in
`Contents/Library/LaunchAgents/`), ad hoc signed by default, in `build/app`. The
last line printed is the path of the app. It refuses to run without the icon
(exit code 2). An identifier `com.djoko.macstatusd.<suffix>` gives an app named
`macstatusd-<suffix>.app`, which is how test builds live next to the real one.

## Known limitations

- **System sleep**: nothing runs during sleep. `/state` is unreachable and
  `/wake` can't wake the Mac; Wake-on-LAN is needed. That's why `off_action`
  defaults to `screensaver`. An application that lets its 30 s sleep notice
  expire delays the sleep by as much.
- **Before login**: the agent belongs to a user's graphical session, so it is
  not running before someone logs in (after a reboot, `/state` is unreachable
  until then). It must not run as root.
- **Multiple users**: two open sessions mean two instances for a single port;
  the second one retries in a loop without crashing, but the published state is
  the one from the instance holding the port.
- **External display physically switched off**: macOS considers it on, so the
  state stays ON. A Mac with no physical display used remotely (screen sharing)
  goes OFF `no-display` after 5 s.
- **Screen savers hosted by `legacyScreenSaver`**: detected through the host
  process, which requires the graphical session.
- **Private functions of `login.framework`**: detection and dismissal rely on
  `SACScreenSaverIsRunning`, `SACScreenSaverStartNow` and `SACScreenSaverStopNow`.
  They return `0` (or `22` for the stop) outside a session and when the session
  agent does not answer; the fallbacks above only cover a missing function. The
  native stop acts on the screen: it opens a panel over the screen saver, which
  returns 30 s later, and only on the main display.
- **Mixed setting**: when the native stop shows no visible panel, a false ON of up
  to 30 s is possible.
- **After `/wake` with the displays off**: macOS shows the lock screen, then turns
  the displays off again after 30 s, without restarting the screen saver.
- **Blinking prompt**: the "Touch ID or password" prompt blinks during the 30 s
  of a panel opened by the native stop (rendering of `loginwindow`, no HID
  activity; no effect on the state).
- **Esc on the lock screen**: dismissing the authentication overlay with Esc
  doesn't bring the state back to OFF right away; it returns to OFF after
  `saver_redisplay_idle_seconds` (30 s) of inactivity, or as soon as the display
  sleeps.
- **Double-click**: while the agent runs, a double-click on the app opens nothing
  (macOS reuses the running instance).
- **Trash of the scripts**: it is a `mv` into `~/.Trash`; the Finder has no "Put
  Back" for it.

## Signing and notarization

A published release is signed with a Developer ID Application certificate and
notarized by Apple (profile stored with `notarytool store-credentials`). It is
produced by:

```bash
bash outils/publier.sh [--repetition] X.Y.Z
```

The script refuses a shallow clone, runs the tests first, signs the app (hardened
runtime), checks that the archive carries no personal data, notarizes, staples,
and writes `build/publication/X.Y.Z/` (`macstatusd-X.Y.Z.zip`, `SHA256SUMS`).
`--repetition` does the same with a rehearsal identity (`com.djoko.macstatusd.repetition`)
in `build/repetition/X.Y.Z/`. Environment: `IDENTITE_SIGNATURE` (default
`Developer ID Application`), `NOTARISER` (default `1`), `PROFIL_NOTARISATION`
(default `djoko-notarisation`). Exit codes: 0 done, 1 refusal or failure, 2
usage. `build/` is ignored by git. An app built from the sources is only ad hoc
signed: macOS treats it as a different app from the published one.

## History

`Versionning/` and `backtest+debug/` contain versions 1 to 4.4.4 and the capture
tools that were used to identify the usable signals. `macstatusdV4.4.4.swift`
stays at the root for reference. Release notes: [NOTES-VERSIONS.md](NOTES-VERSIONS.md).

## License

MIT — see [LICENSE](LICENSE).
