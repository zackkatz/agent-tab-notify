# AGENTS.md — agent-tab-notify

> Claude Code notifications that take you to the right terminal tab, and clear when you get there.

## Quick Start

**What this is:** a single bash script wired into Claude Code's hooks. When Claude stops or
asks for input, it posts a macOS notification through `terminal-notifier` carrying a click
action that selects the exact terminal tab the session is running in. A companion launchd
agent clears that notification when you arrive at the tab.

**Main entry point:** `bin/agent-tab-notify` (about 900 lines, one file, no dependencies
beyond `terminal-notifier` and macOS)

**Architecture style:** subcommand dispatch at the bottom of one script; everything above is
functions. Sourcing the file runs nothing, so tests call the internals directly.

**No build system.** No `package.json`, no `composer.json`, no `Makefile`. `test/run.sh` is
the whole toolchain.

## Repository Map

```
bin/agent-tab-notify    the entire program
install.sh                    wires the hooks into ~/.claude/settings.json (backs it up first)
uninstall.sh                  removes them
launchd/                      the watch agent's plist
test/run.sh                   the suite; stubs terminal-notifier and asserts on its arguments
```

## Architecture

### Subcommands

The dispatch block is at the end of `bin/agent-tab-notify`, guarded on `BASH_SOURCE`.

| Subcommand | Runs from | Does |
|---|---|---|
| `notify` | Stop and Notification hooks | posts this session's notification |
| `clear` | UserPromptSubmit hook | drops this session's notification |
| `watch` | the launchd agent | clears a tab's notification when you switch to it |
| `focus <handle>` | a notification click | selects the tab for that handle |
| `resolve` | by hand | prints this session's handle, then its tab name |
| `doctor` | by hand | checks the pieces this depends on |
| `prune` | by hand; `watch` runs it on start and every 5 minutes | drops markers whose tab no longer exists |

### Handles

A handle is `<terminal>:<identifier>` — the kind travels with the identifier so the click
does not have to guess which terminal to ask. `resolve_handle()` tries each terminal in turn
and takes the first that answers:

- `iterm:<session uuid>` — stable per session, matched by tty
- `terminal:<tty>` — Terminal.app exposes a tty per tab
- `ghostty:<tab id>` — matched by working directory, and only when unambiguous
- `tty:<tty>` — unresolved; the click works out which terminal owns it later
- `warp:<scheme>:<32 hex>` — from `$WARP_FOCUS_URL` (`warp_handle()`); checked in `cmd_notify()`
  before `resolve`, because Warp started from an iTerm2 tab inherits that tab's
  `ITERM_SESSION_ID`. A click opens `<scheme>://session/<id>`. No marker is written, since
  Warp cannot name its frontmost tab. Undocumented by Warp; verified on 0.2026.10.14.

`resolve` prints the handle, then the tab name, then the tab's position in its window, then
(iTerm2 and the Codex lookup only) the window's tab count. `tab_shortcut()` turns the last two
into the `⌘N: ` title prefix: iTerm2 maps ⌘9 to the last tab, other terminals to tab nine.
With no tab name, the title is the session's `/rename` name, then its generated name
(`session_name()` reads `custom-title` / `ai-title` entries from the transcript).

The `tty:` fallback exists because asking a terminal anything requires AppleScript, which
stalls under load when several sessions post at once. Reading the tty costs no AppleScript,
so a notification always carries something actionable and the lookup happens on click.

### Group keys

`terminal-notifier`'s `-group` is what makes a new notification replace that session's
previous one instead of stacking. The key is `<prefix>:<identifier>`, falling back from the
resolved handle to Claude's session id to the working directory. Claude's session id is what
keeps sibling tabs in one project distinct; falling back to the directory collapses them,
which is why the directory-based key is never cleared.

### The click callback

`notify` passes `-execute "nohup '$SELF' focus '<handle>' &"`, so the path baked into the
delivered notification must be the real one on disk. `SELF` is resolved with `pwd -P` for
this reason: a symlinked or relative invocation would bake in a path that stops resolving
the moment the caller's directory changes.

### The watch loop

`cmd_watch` polls once a second and is built to cost nothing while nothing is waiting.
Reading the frontmost app is `lsappinfo` (about 8ms, no AppleScript); asking iTerm which
session is frontmost is AppleScript (about 146ms). So the expensive question is only asked
when a marker file says a notification is actually outstanding. `notify` writes one marker
per posted notification that has a tab, and `clear` removes it.

**Any marker at all keeps that question running every second**, so a marker that never gets
cleared costs one AppleScript call a second indefinitely. Two rules keep the directory
honest:

- A notification with no handle (a background job, a session with no tty) writes no marker.
  The loop matches markers to the frontmost tab, so one with no tab could never be cleared.
- `prune_pending` drops a marker once its tab is provably gone: a `tty:`/`terminal:` marker
  whose tty has no processes or that was written before this boot (macOS reuses tty
  numbers, so a live tty proves nothing about an older marker), or an `iterm:` marker whose
  session id iTerm no longer lists. iTerm ids do survive a restart when iTerm restores the
  tab, so those are checked by id alone.
  It skips markers under a minute old and keeps any marker it cannot check. Markers outlive
  their tab whenever a session ends without a reply: a closed tab, a crash, a restart.
  Before these rules, 120 markers had piled up over a month, 107 of them with no tab, and
  the agent ran `osascript` about once a second.

## Conventions

- **One file, functions above, dispatch below.** New behavior is a function plus a `case`
  arm, not a new script.
- **Every knob is an environment variable with a `CCTN_` prefix and a default**, so the test
  suite can redirect the tool away from real notifications.
- **Comments explain why, not what.** The existing ones carry the reasoning for the `tty:`
  fallback, the `pwd -P`, the group-key ladder. Match that.
- **Failures are silent by design in the hook paths** (a broken notifier must never block
  Claude) and **loud in `watch` and `doctor`**, which exist to be diagnosed.

## Settings

User settings live in `~/.config/agent-tab-notify/config` (`$CCTN_CONFIG` overrides the
path), as `CCTN_NAME="value"` lines. `SETTINGS_TABLE` near the top of the script is the single
list of names, defaults and descriptions; `config` prints from it and `config set` refuses
any name not in it. `load_config()` parses the file as data (never `source`d), skips names
already in the environment so an env var wins, and records which names came from the file
in `CONFIG_FILE_KEYS` so a reload can unset them first. Read a value with `setting NAME`,
`setting_seconds NAME` for numbers, and `is_on` for booleans. The defaults lookup is plain
bash on purpose: a hook with a bare PATH (no awk) once read every default as empty, which
`is_on` treats as off, and nothing posted. The watch loop stats the file each tick and
reloads it when it changes. `expire_after` timers are detached `expire` subcommands; each
post writes a token to `$TMPDIR/cctn-expire/<group>`, and a timer removes the notification
only if its token is still the latest.

`notify_when_focused` (default off): `cmd_notify` asks `tab_in_front()` for the front tab's
handle and tty (one `lsappinfo`, plus one AppleScript call only when iTerm2 or Terminal is in
front) and skips the post when `handles_match()` says it is this session's tab. Ghostty and
Warp cannot name their front tab, so they always post. The suite exports
`CCTN_NOTIFY_WHEN_FOCUSED=1` because it runs from the tab in front.
`user_is_away()` reads `HIDIdleTime` from `ioreg` (nanoseconds, about 20ms); when idle passes
`away_after` the front-tab skip is bypassed. The suite's `front_stub` fakes `ioreg` too, or
the result would depend on whether someone is at the keyboard.

The `Notification` event's `notification_type` (Claude Code 2.1.317: `permission_prompt`,
`idle_prompt`, `auth_success`, `elicitation_dialog`, `agent_needs_input`, `agent_completed`,
and others) drives `notify_on_idle`: `idle_prompt` is skipped by default, as is a payload
with no type whose message is "Claude is waiting for your input" (older versions).

`notify_while_agents_run` (default off): the Stop payload's `background_tasks` (Claude Code
2.1.319) lists running or pending backgrounded work, each with a `type` label. `waiting_on_agents()`
skips the post for `subagent`, `workflow`, `teammate` and `cloud session`, but not `shell` or
`monitor`, because a dev server or a long watch would otherwise silence a session for good.
A subagent "waiting on its own background work" has status `completed`, so it is not in that list;
only its command is. That case comes from the turn's `<task-notification>` row at the end of the
transcript, read only when `background_tasks` is not empty. Codex sends no such field and always posts.

Watch loop states: `fresh` (nothing was pending last tick, so the tab you are on when a
notification first appears counts as already visited, not arrived at), `last_handle`,
`arrived_at` and `cleared` (one clear per visit, after `clear_delay` seconds on the tab).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CCTN_GROUP_PREFIX` | `agent-tab-notify` | notification group namespace; the suite sets `cctn-test` |
| `CCTN_TITLE_PREFIX` | (empty) | text before the tab name in the title; set it to tell these apart from iTerm2's own Claude Code notifications |
| `CCTN_PENDING_DIR` | `$HOME/.cache/cctn-pending` | marker files the watch loop reads |
| `CCTN_WATCH_INTERVAL` | `1` | watch poll seconds |
| `CCTN_WATCH_QUIET` | unset | silences watch's diagnostics |
| `CCTN_PRUNE_INTERVAL` | `300` | seconds between the watch loop's stale-marker sweeps |
| `CCTN_ALWAYS_NOTIFY` | unset | overrides the unroutable-session skip |
| `CCTN_BANNER_CHARS` | `150` | most characters of the reply `clean_reply` keeps, cut at a word |
| `CCTN_CONFIG` | `~/.config/agent-tab-notify/config` | settings file path; the suite points it at a temp file |
| other `CCTN_*` settings | see `SETTINGS_TABLE` | any setting can also come from the environment, which wins over the file |
| `CCTN_AGENT` | unset | `codex` marks a Codex hook; a payload with `turn_id` counts too |
| `CODEX_HOME` | `~/.codex` | where `install.sh` writes Codex's `hooks.json` and where the thread-name lookup reads `state_*.sqlite` |

## Claude Code hook wiring

`install.sh` adds four entries to `~/.claude/settings.json`, backing the file up to
`settings.json.bak-cctn-<timestamp>` first. An event that already has an entry naming this
tool (either name) is not added again; its command is rewritten to this checkout's path
instead, which is how a rename or a moved checkout is picked up:

| Event | Subcommand |
|---|---|
| `Stop` | `notify` |
| `Notification` | `notify` |
| `PermissionRequest` | `notify` |
| `UserPromptSubmit` | `clear` |

`PermissionRequest` carries `tool_name` and `tool_input` (Claude Code 2.1.317), which
`permission_summary()` turns into "Wants to run: <command>", "Wants to edit: <path>", or
"Wants to use <server> <tool>: <first text argument>". The `Notification` event Claude Code
sends for the same prompt (`notification_type: permission_prompt`) says only "Claude needs
your permission"; it is dropped when this session posted a PermissionRequest notification in
the last ten minutes (a touch file in `$TMPDIR/cctn-permission/<session_id>`), so it cannot
replace the detailed one.

The watch agent is separate and not installed by `install.sh`; see the README.

**Renamed from claude-code-tab-notify.** `bin/claude-code-tab-notify` is a committed symlink
to `bin/agent-tab-notify`, so old hook commands and the click callbacks stored in
already-delivered notifications keep working; `SELF` resolves the symlink so new callbacks
use the new name. The settings file falls back to `~/.config/claude-code-tab-notify/config`
when the new path does not exist. The `CCTN_` prefix for settings and the
`~/.cache/cctn-pending` marker directory kept their names.

## Codex hook wiring

When `${CODEX_HOME:-~/.codex}` exists, `install.sh` also writes two entries to its
`hooks.json`: `Stop` runs `notify` and `UserPromptSubmit` runs `clear`, each command
prefixed `CCTN_AGENT=codex`.
Codex runs a hook only after the user trusts it with `/hooks`; until then nothing fires and
nothing reports why. `PermissionRequest` is left out because it fires before Codex's
automatic reviewer decides.

Codex runs hooks in one of two places, and the code has to tell them apart:

- **In the tab's own `codex` process** (an in-process app server). A tty sits above the
  hook and the environment is the tab's own, so the Claude path works unchanged.
- **In the shared app-server daemon** (`codex app-server --managed-daemon`). No tty, and its
  `ITERM_SESSION_ID` and `TMUX` belong to whichever tab started the daemon.
  `forget_daemon_env` unsets them when no ancestor has a tty, and `resolve_codex_thread`
  matches the iTerm tab whose name starts with the thread's `name` from
  `state_*.sqlite`, only when exactly one tab matches.

## Extension patterns

### Adding support for another terminal

Four functions, and all four are needed or the terminal half-works:

1. `resolve_<term>()` — return `<kind>:<identifier>` for the current session, or nothing.
   Add it to the ladder in `resolve_handle()`.
2. `focus_<term>()` — select that tab. Add a `case` arm in `cmd_focus()` with the bundle id.
3. A `case` arm in `watch_frontmost_handle()` if the terminal can name its frontmost tab.
4. A `TERM_PROGRAM` arm in `cmd_notify()` so an unresolved session still raises the app.

**Only add a terminal that exposes a per-tab identifier.** Ghostty is matched by working
directory and only when unique; Warp by its own `WARP_FOCUS_URL` link. Sending someone to the wrong tab is
worse than sending them nowhere, which is the rule the existing code is built around.

### Adding a subcommand

A function named `cmd_<name>`, an arm in the dispatch `case`, and a line in the usage header
at the top of the file — `cmd_doctor`'s fallback prints lines 2 to 12 of the script itself (widen that range when the header grows),
so the header is the help text.

## Development

```bash
bash test/run.sh                      # the suite
bin/agent-tab-notify doctor     # checks macOS, terminal-notifier, alert style, resolution
bin/agent-tab-notify resolve    # what this session resolves to
./install.sh                          # wire the hooks
```

The suite stubs `terminal-notifier` on `PATH` and asserts on the arguments it was called
with (`arg_of`, `call_count` in `test/run.sh`), so it never posts a real notification. It
covers syntax, resolution, notify, degraded resolution, unroutable sessions, clear, and
markers (no marker without a tab; what `prune` drops and keeps).

The suite points `CCTN_PENDING_DIR` at a temporary directory and deletes it on exit. The
real directory is what the installed watch agent reads, so a test marker left there keeps
the agent polling iTerm every second. A test that runs the script under `env -i` has to
pass `CCTN_PENDING_DIR` through explicitly.

## Gotchas

1. **Every subcommand but `watch` reads hook JSON from stdin and hangs when stdin is a pipe
   with nothing coming.** `read_stdin` skips the read only when stdin is a tty, so
   `bash bin/agent-tab-notify notify` from a script or harness blocks forever with no
   output. Pipe a payload in or redirect from `/dev/null`. A hang here is the harness, not
   the hook.
2. **`test/run.sh` fails one test on a clean tree**: `parses hook JSON without jq`. Run the
   suite before changing anything so you compare against that baseline instead of reading it
   as your own regression.
3. **launchd hands an agent `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, with no Homebrew**, so
   `terminal-notifier` is simply absent. The plist sets its own PATH. Without it the
   dependency check exits, launchd restarts the job five times and throttles it, the log is
   empty, and `launchctl print` reads `state = spawn scheduled` with `last exit code = 0` —
   which all looks healthy. A dependency check that exits 0 makes this undiagnosable.
4. **`TMPDIR` is not the same path for a shell and for a launchd agent.** State shared
   between a hook and the agent must live somewhere both resolve identically, which is why
   the marker directory is under `$HOME/.cache`. Moving it back under `TMPDIR` splits the two
   halves and neither errors.
5. **The watch agent needs its own Automation permission to drive AppleScript**, granted
   separately from whatever your terminal already has. Until it is granted `osascript`
   returns an empty string, so a swallowed stderr makes a denial indistinguishable from
   "no tab found". Never send `osascript` stderr to `/dev/null` here.
6. **Verify a watch change against the installed agent, not a foreground run.** The
   foreground copy inherits your shell's PATH, TMPDIR and permissions, so it passes while the
   agent does nothing. `launchctl kickstart -k gui/$UID/<label>` restarts it, and
   `/tmp/cctn-watch.log` is where it says why it stopped.
7. **`watch` acts only when the frontmost tab changes.** A notification arriving for the tab
   you are already sitting in is left alone until you leave and come back, so nothing is
   cleared before you have seen it. A test that posts for the currently frontmost tab and
   waits will observe nothing and prove nothing.
8. **Claude re-fires the Stop hook when it continues from its own stop.** `cmd_notify` exits
   on `stop_hook_active`, because nothing is waiting on you at that point.
9. **A session that resolves to no tab is skipped when iTerm2's own Claude Code integration
   is active**, since that integration posts a working notification of its own and two would
   be worse than one. `CCTN_ALWAYS_NOTIFY=1` overrides it.
10. **`cctn.log` is capped at 300 lines, so its line count stops growing once full.** A
    check that waits for `wc -l` to rise never sees a new entry. Match on the timestamp
    or the session id instead.
11. **A Codex session started from a script inherits that shell's `ITERM_SESSION_ID`**, and
    runs hooks in-process with a tty, so it routes to the tab you launched it from. The
    routing matches the environment it was given; test daemon routing under launchd instead.
12. **The script is safe to `source`** — the dispatch is guarded on `BASH_SOURCE`, so tests
    call the per-terminal functions directly. Source it from `bash`; under `zsh` every
    `BASH_SOURCE` reference warns.

## Related resources

- `README.md` — installation and what each feature does, for humans
- `test/run.sh` — the executable specification for notify and clear
