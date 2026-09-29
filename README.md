# claude-code-tab-notify

Claude Code notifications that take you to the right terminal tab, and clear when you get there.

If you run Claude Code in more than one tab, you already know the problem. A notification arrives, you click it, and nothing happens. Or it raises your terminal and drops you wherever you left off, so you hunt through eleven tabs to find the one that wants you. Meanwhile Notification Center fills with a hundred stale alerts you can no longer match to anything.

## What you get

**Click a notification, land on the exact tab.** Not just the app. In iTerm, the right window, tab, and split pane.

**Know which tab before you click.** The notification carries the tab's own title, so five sessions in one project stay distinguishable.

**It waits for you.** Set to the Alerts style, a notification stays on screen until you deal with it, instead of fading after a few seconds while you are in another app.

**It cleans up after itself.** Reaching a tab clears its notification, whether you clicked through or switched tabs and typed. Notification Center stops filling with alerts for work you already handled.

**Switching to the tab is enough.** With the watcher running, arriving at a tab clears its notification straight away, without waiting for you to type. See [Clearing on tab switch](#clearing-on-tab-switch).

**One notification per session.** A new alert replaces that session's previous one rather than stacking, and other sessions keep their own.

**Quiet when nothing needs you.** Claude re-fires its stop hook when it continues from its own stop. That does not notify.

## Terminal support

What a terminal exposes to AppleScript decides how well this can work.

| Terminal | Identified by | Click takes you to |
| --- | --- | --- |
| iTerm2 | session id, or tty | the exact tab and split pane |
| Terminal.app | tty | the exact tab |
| Ghostty | working directory | the tab, when only one is open on that directory |
| Warp | nothing | the app |

Ghostty exposes no tty and no per-tab environment variable, so the working directory is the only handle available. Two tabs open on one project cannot be told apart, and sending you to the wrong tab is worse than sending you nowhere, so a match counts only when it is unique. Warp ships no scripting dictionary at all, so its notifications raise the app and stop there.

Sessions under VS Code's terminal, or any terminal not listed, get a notification that raises that app. When the terminal is unrecognized, the notification carries no click action rather than guessing and pulling you somewhere you were not working.

## Clearing on tab switch

Claude Code fires no hook when you switch terminal tabs, so the built-in clearing happens on your next keystroke in that tab. To clear on arrival instead, run the watcher:

```bash
launchctl load -w ~/Library/LaunchAgents/com.zackkatz.claude-code-tab-notify.watch.plist
```

Copy `launchd/com.zackkatz.claude-code-tab-notify.watch.plist` there first, with the path inside it pointing at your checkout.

It polls once a second. An idle tick reads the frontmost app and lists one directory, which is about 8ms and no AppleScript at all; it only asks iTerm or Terminal which tab is in front while a notification is actually outstanding. A notification that arrives for the tab you are already sitting in is left alone until you move away and come back, so nothing is cleared before you have seen it.

iTerm2 and Terminal.app only. Ghostty and Warp expose no per-tab identifier, so the watcher cannot tell their tabs apart, and clearing the wrong tab's notification would lose the one thing waiting on you.

Stop it with `launchctl unload -w ~/Library/LaunchAgents/com.zackkatz.claude-code-tab-notify.watch.plist`, or run it in the foreground as `claude-code-tab-notify watch` to see what it does.

## Requirements

macOS, [terminal-notifier](https://github.com/julienXX/terminal-notifier), and one of the terminals above:

```
brew install terminal-notifier
```

`jq` is used when present and not required. Everything else ships with macOS.

## Install

```
git clone https://github.com/YOUR_USER/claude-code-tab-notify.git
cd claude-code-tab-notify
./install.sh
```

The installer merges three hooks into `~/.claude/settings.json`, leaving any hooks you already have in place. Run it twice and it changes nothing the second time. `./uninstall.sh` removes only what it added.

Restart Claude Code, then confirm the setup:

```
bin/claude-code-tab-notify doctor
```

`doctor` reports whether `terminal-notifier` is installed, which terminals are running, whether your session resolves to a tab, whether the hooks are registered, and what alert style macOS has for `terminal-notifier`.

### Make notifications stay on screen

macOS shows notifications as Banners by default, which fade after a few seconds. To have them wait for you, open System Settings, Notifications, `terminal-notifier`, and set Alert style to Alerts.

You may see two `terminal-notifier` entries. That happens when the npm package `node-notifier` is installed anywhere on your machine, because it vendors its own copy of the app under a different bundle identifier. The one that matters here is the Homebrew build, `fr.julienxx.oss.terminal-notifier`. `doctor` prints both and marks which is which.

## How it works

Three hooks, one executable.

| Hook | What runs | When |
| --- | --- | --- |
| `Stop` | `notify` | Claude finishes a turn |
| `Notification` | `notify` | Claude needs permission or input |
| `UserPromptSubmit` | `clear` | You type in the tab |

`notify` posts through `terminal-notifier` with `-execute`, which stores a command inside the notification. Clicking it runs `focus`, which selects the tab through AppleScript and then clears that notification.

Identifying the tab is the part worth explaining. In iTerm, `$ITERM_SESSION_ID` is the obvious handle and it is not enough on its own: it is missing from some sessions, and it goes stale when iTerm restores a tab, because restoring assigns a new id. So the value is validated against live sessions before use, and when it does not match, the tab is found by tty instead. Hooks run without a controlling terminal, so the tty comes from the nearest ancestor process that has one, which is the `claude` process itself. Under tmux that pty belongs to the tmux server rather than to any terminal, so the attached client's tty is used instead.

Rather than trusting `$TERM_PROGRAM`, which is absent from some hook environments for the same reasons, each running terminal is asked in turn whether it owns this session. Every identifier handed to a notification resolved against a live tab, so a click can never target a tab that no longer exists.

## Background sessions

Claude Code background sessions run under its daemon rather than in a tab. They have no tty, and the terminal session id they inherit points at whichever tab launched them, which is often closed. No tab exists to switch to, and nothing in Claude's job metadata records where you are watching one.

Those notifications say `background job: <name>`, read in full from the job's own state file, since the name is the only thing identifying which job woke you.

If iTerm2's Claude Code integration is installed, which its own setup detects by looking for `cc-status` in your hooks, notifications that cannot route anywhere are skipped entirely. iTerm posts a working one for those sessions, so a second one that does nothing on click is noise. Set `CCTN_ALWAYS_NOTIFY=1` to post them anyway.

## Known limits

Sessions that cannot be matched to a tab fall back to Claude's own session id for grouping, and to the working directory if that is also absent. In the directory case, sibling tabs in one project share a group and overwrite each other's notifications.

With more than one tmux client attached to a session, the first one is used.

Reaching a tab without typing does not clear its notification. Clicking the notification does, and so does typing in the tab.

## Tests

```
./test/run.sh
```

Tests that need a particular terminal running are skipped rather than failed, and the suite posts only into its own notification group and removes what it posts. Several checks are paired with a tamper case, so a passing assertion has to be capable of failing: the check that two sessions in one directory keep separate notifications is followed by one proving they do collide once the session id is removed.

## Credits

The `stop_hook_active` guard and the idea of putting the tab title in the subtitle both came from reading [stevemeisner/claude-iterm-notify](https://github.com/stevemeisner/claude-iterm-notify), which is MIT licensed.

Two AppleScript details cost time here and may save you some. iTerm2 tabs have no `name` property, and Terminal.app tabs have none either, though Terminal offers `custom title`. Asking for `name` fails with error -1700, and a suppressed error leaves the subtitle silently absent rather than reporting anything.

## License

MIT
