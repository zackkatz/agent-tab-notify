# claude-code-tab-notify

One bash script (`bin/claude-code-tab-notify`), a test suite (`test/run.sh`), and a
launchd agent (`launchd/*.plist`). macOS only.

## Testing the script by hand

- **Every subcommand but `watch` reads hook JSON from stdin, and hangs when stdin is a
  pipe with nothing coming.** `read_stdin` only skips the read when stdin is a tty, so
  `bash bin/claude-code-tab-notify notify` from a script or an agent harness blocks
  forever with no output. Pipe a payload in, or redirect from `/dev/null`:
  `printf '{"session_id":"x","cwd":"/tmp"}' | bin/claude-code-tab-notify notify`.
  A hang here is the harness, not the hook.
- **`test/run.sh` fails one test on a clean tree**: `parses hook JSON without jq`. Run it
  before you change anything, so you compare against that baseline rather than reading it
  as your own regression.
- The script is safe to `source`: the dispatch block is guarded on `BASH_SOURCE`, so the
  per-terminal functions can be called directly. Source it from `bash`, not `zsh`, or
  every `BASH_SOURCE` reference warns.

## The watch agent (launchd)

Three things about a launchd agent break code that works from a shell, and all three fail
silently. Anything added to `cmd_watch` has to survive them.

- **PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, with no Homebrew**, so `terminal-notifier`
  is simply absent. The plist sets its own PATH for this reason. The symptom without it:
  the dependency check exits, launchd restarts the job five times and throttles it, the
  log is empty, and `launchctl print` reads `state = spawn scheduled` with
  `last exit code = 0`, which all looks healthy. A dependency check that exits 0 makes
  this undiagnosable; name what is missing and exit non-zero.
- **`TMPDIR` is not the same path for a shell and for an agent.** State shared between a
  hook (which runs with your shell's environment) and the agent must live somewhere both
  resolve identically; the pending-marker directory is under `$HOME/.cache` for exactly
  this reason. Putting it back under `TMPDIR` splits the two halves and neither errors.
- **The agent needs its own Automation permission to drive AppleScript**, granted
  separately from any permission your terminal already has. Until it is granted,
  `osascript` returns an empty string, so a swallowed stderr makes a denial
  indistinguishable from "no tab found". Never redirect `osascript` stderr to
  `/dev/null` here; log it.

Verify a change against the *installed* agent, not a foreground run: the foreground copy
inherits your shell's PATH, TMPDIR and permissions, so it passes while the agent does
nothing. `launchctl kickstart -k gui/$UID/<label>` restarts it, and
`/tmp/cctn-watch.log` is where it says why it stopped.

## Behavior that looks like a bug

- **`watch` acts only when the frontmost tab changes.** A notification arriving for the
  tab you are already sitting in is left alone until you leave and come back, so nothing
  is cleared before you have seen it. A test that posts a notification for the currently
  frontmost tab and waits will therefore observe nothing happening, and prove nothing.
- **Ghostty and Warp are absent from `watch` on purpose.** Neither exposes a per-tab
  identifier, and clearing the wrong tab's notification loses the one thing that was
  waiting on you.
