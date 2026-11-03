#!/bin/bash
# Test suite.
#
# Assertions capture the arguments handed to terminal-notifier rather than
# reading delivered notifications back, which depends on Notification Center
# answering and fails for reasons unrelated to this code (a Focus mode, or
# `terminal-notifier -list` hanging).

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
EXE="$REPO_DIR/bin/agent-tab-notify"

export CCTN_GROUP_PREFIX="cctn-test"
# The log and the saved tab names live under TMPDIR, and the live hooks use
# the same ones, so a run of the suite would mix its entries into yours.
REAL_TMPDIR="${TMPDIR:-/tmp}"
export TMPDIR; TMPDIR=$(mktemp -d "$REAL_TMPDIR/cctn-test.XXXXXX")
# Your own settings file must not change what the suite expects.
export CCTN_CONFIG="$TMPDIR/config"
# The suite posts from the tab it runs in, which is usually the one in front.
# The front-tab skip has its own tests with a faked front tab.
export CCTN_NOTIFY_WHEN_FOCUSED=1
# The real marker directory is what the installed watch agent reads, so a
# marker the suite leaves there keeps that agent polling iTerm every second.
export CCTN_PENDING_DIR; CCTN_PENDING_DIR=$(mktemp -d)
trap 'rm -rf "$CCTN_PENDING_DIR" "$TMPDIR"' EXIT

PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "       $2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1 ($2)"; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else fail "$name" "expected [$expected], got [$actual]"; fi
}

# A stub PATH whose terminal-notifier records every call instead of posting.
# Pass "noresolve" to also stub osascript, simulating a terminal too slow to answer.
make_stub() {
    local dir; dir=$(mktemp -d)
    cat > "$dir/terminal-notifier" <<EOF
#!/bin/bash
for a in "\$@"; do printf '%s\t' "\$a" >> "$dir/calls.txt"; done
printf '\n' >> "$dir/calls.txt"
EOF
    chmod +x "$dir/terminal-notifier"
    case "${1:-}" in
        noresolve|notty)
            printf '#!/bin/bash\nexit 0\n' > "$dir/osascript"
            chmod +x "$dir/osascript"
            ;;
    esac
    # No tty anywhere in the ancestry, as with a Claude session parented by
    # launchd rather than started from a terminal tab. "noancestor" keeps the
    # real osascript, as with a hook run by the Codex daemon.
    if [ "${1:-}" = "notty" ] || [ "${1:-}" = "noancestor" ]; then
        printf '#!/bin/bash\nexit 0\n' > "$dir/ps"
        chmod +x "$dir/ps"
    fi
    echo "$dir"
}

# Value following a flag, from call number $3 (default 1).
arg_of() {
    awk -v flag="$2" -v want="${3:-1}" 'BEGIN{FS="\t"}
        {n++; if (n==want) for (i=1;i<=NF;i++) if ($i==flag) {print $(i+1); exit}}' "$1/calls.txt" 2>/dev/null
}
call_count() { [ -f "$1/calls.txt" ] && grep -c . "$1/calls.txt" || echo 0; }

payload() {
    printf '{"hook_event_name":"%s","message":"%s","cwd":"%s","session_id":"%s"%s}' \
        "$1" "$2" "$PWD" "$3" "${4:-}"
}

source "$EXE"

echo "agent-tab-notify tests"
echo

# ---------------------------------------------------------------- syntax ---
echo "syntax"
for f in "$EXE" "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/test/run.sh"; do
    if bash -n "$f" 2>/dev/null; then ok "parses: $(basename "$f")"
    else fail "parses: $(basename "$f")" "bash -n reported an error"; fi
done
echo

# --------------------------------------------------------------- resolve ---
echo "resolve"
if app_running "iTerm2"; then
    BASE=$(bash "$EXE" resolve "$PWD" | head -1)
    if [ -n "$BASE" ]; then
        ok "resolves a live tab: $BASE"

        # An absent ITERM_SESSION_ID is the case that used to fall back to
        # activation, which does nothing when the app is already frontmost.
        check "resolves without ITERM_SESSION_ID" "$BASE" \
              "$(env -u ITERM_SESSION_ID bash "$EXE" resolve "$PWD" | head -1)"

        # iTerm assigns a new id when it restores a tab, so a stale value must
        # not win over a tty match.
        check "ignores a stale ITERM_SESSION_ID" "$BASE" \
              "$(ITERM_SESSION_ID='w0t0p0:00000000-0000-0000-0000-000000000000' \
                 bash "$EXE" resolve "$PWD" | head -1)"
    else
        skip "resolve tests" "iTerm running but this session is not inside it"
    fi
else
    skip "resolve tests" "iTerm2 not running"
fi

if app_running "Terminal"; then
    tty=$(osascript -e 'tell application "Terminal" to return tty of tab 1 of window 1' 2>/dev/null)
    check "Terminal.app resolves by tty" "terminal:$tty" "$(resolve_terminal_app "$tty" | head -1)"
    check "Terminal.app rejects an unknown tty" "" "$(resolve_terminal_app /dev/ttys999)"
else
    skip "Terminal.app tests" "Terminal not running"
fi

if app_running "Ghostty"; then
    check "Ghostty rejects an unknown directory" "" "$(resolve_ghostty /nonexistent/path)"
else
    skip "Ghostty tests" "Ghostty not running"
fi
echo

# ---------------------------------------------------------------- notify ---
echo "notify"

stub=$(make_stub)
payload Stop "should not appear" sid-guard ',"stop_hook_active":true' | PATH="$stub:$PATH" bash "$EXE" notify
check "stop_hook_active posts nothing" "0" "$(call_count "$stub")"
rm -rf "$stub"

stub=$(make_stub)
payload Notification "hello" sid-post | PATH="$stub:$PATH" bash "$EXE" notify
check "posts one notification" "1" "$(call_count "$stub")"
check "carries the message" "hello" "$(arg_of "$stub" -message)"
if [ -n "${BASE:-}" ]; then
    case "$(arg_of "$stub" -title)" in
        "⌘"[1-9]": "?*|"Tab "[1-9][0-9]*": "?*) ok "title starts with the tab position" ;;
        *) fail "title starts with the tab position" "got [$(arg_of "$stub" -title)]" ;;
    esac
fi
case "$(arg_of "$stub" -title)" in
    "cctn: "*) fail "title has no prefix by default" "got [$(arg_of "$stub" -title)]" ;;
    ?*) ok "title has no prefix by default" ;;
    *) fail "title has no prefix by default" "title is empty" ;;
esac
rm -rf "$stub"

# The payload's reply wins over the transcript, which can lag one reply behind.
stub=$(make_stub notty)
stale_transcript=$(mktemp)
printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"OLD REPLY"}]}}' > "$stale_transcript"
printf '{"hook_event_name":"Stop","cwd":"%s","session_id":"sid-fresh","stop_hook_active":false,"transcript_path":"%s","last_assistant_message":"NEW REPLY"}' \
    "$PWD" "$stale_transcript" | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "uses the payload's reply over a stale transcript" "NEW REPLY" "$(arg_of "$stub" -message)"
rm -rf "$stub"

# Tamper check: without the payload field, the transcript is still read.
stub=$(make_stub notty)
printf '{"hook_event_name":"Stop","cwd":"%s","session_id":"sid-fresh2","stop_hook_active":false,"transcript_path":"%s"}' \
    "$PWD" "$stale_transcript" | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "falls back to the transcript" "OLD REPLY" "$(arg_of "$stub" -message)"
rm -rf "$stub" "$stale_transcript"

# The banner gets plain text: no Markdown, no bare lead-in, cut at a word.
reply_of() {
    local stub; stub=$(make_stub notty)
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","cwd":sys.argv[1],"session_id":"sid-reply","stop_hook_active":False,"last_assistant_message":sys.argv[2]}))' "$PWD" "$1" \
        | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
    arg_of "$stub" -message; rm -rf "$stub"
}
check "removes Markdown and a bare lead-in" "Both are in. See the repo and run make." \
    "$(reply_of $'Done.\n\n**Both are in.** See [the repo](https://x.y/z) and run `make`.')"
check "separates list lines" "Title. No prefix" "$(reply_of $'- **Title**\n- *No* prefix')"
check "keeps accented letters whole" "Café résumé — 日本語" "$(reply_of 'Café résumé — 日本語')"
long_reply="$(reply_of "$(printf 'word%.0s ' {1..60})end")"
case "$long_reply" in
    *"word…") ok "cuts a long reply at a word, with an ellipsis" ;;
    *) fail "cuts a long reply at a word, with an ellipsis" "got [$long_reply]" ;;
esac
check "a long reply fits the banner" "1" "$([ "$(printf '%s' "$long_reply" | python3 -c 'import sys;print(len(sys.stdin.read()))')" -le 151 ] && echo 1)"

# Warp cannot be scripted, so its own focus link is the handle, and a click
# opens it. Its tab is never matched by tty, so no marker is written.
warp_id=428d4ec809d6424fa3273df7827cd2c8
stub=$(make_stub noresolve)
# A live ITERM_SESSION_ID is set on purpose: Warp started from an iTerm2 tab
# inherits one, and it must not win.
payload Notification "warp" sid-warp | ITERM_SESSION_ID="w0t0p0:${BASE#iterm:}" TERM_PROGRAM=WarpTerminal \
    WARP_FOCUS_URL="warp://session/$warp_id" CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
case "$(arg_of "$stub" -execute)" in
    *"focus 'warp:warp:$warp_id'"*) ok "a Warp session's click opens its focus link" ;;
    *) fail "a Warp session's click opens its focus link" "got [$(arg_of "$stub" -execute)]" ;;
esac
check "a Warp notification is grouped by its session" "cctn-test:warp:$warp_id" "$(arg_of "$stub" -group)"
check "a Warp session writes no marker" "" "$(ls "$CCTN_PENDING_DIR" | grep "$warp_id")"
rm -rf "$stub"
check "ignores a malformed Warp link" "" \
    "$(TERM_PROGRAM=WarpTerminal WARP_FOCUS_URL='warp://session/x;rm' warp_handle)"
check "ignores a Warp link outside Warp" "" \
    "$(TERM_PROGRAM=iTerm.app WARP_FOCUS_URL="warp://session/$warp_id" warp_handle)"
check "keeps a preview channel's scheme" "warp:warppreview:$warp_id" \
    "$(TERM_PROGRAM=WarpTerminal WARP_FOCUS_URL="warppreview://session/$warp_id" warp_handle)"

# With no tab name, the session's own name is the title: the /rename one over
# the generated one, and the last of each.
named=$(mktemp)
printf '%s\n' '{"type":"ai-title","aiTitle":"Generated name"}' '{"type":"custom-title","customTitle":"Old name"}' \
    '{"type":"custom-title","customTitle":"session warp one"}' '{"type":"ai-title","aiTitle":"Later generated"}' > "$named"
stub=$(make_stub notty)
printf '{"hook_event_name":"Notification","cwd":"%s","session_id":"sid-named","message":"x","transcript_path":"%s"}' "$PWD" "$named" \
    | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "titles a tabless session by its /rename name" "session warp one" "$(arg_of "$stub" -title)"
rm -rf "$stub"
printf '%s\n' '{"type":"ai-title","aiTitle":"Generated name"}' > "$named"
stub=$(make_stub notty)
printf '{"hook_event_name":"Notification","cwd":"%s","session_id":"sid-named2","message":"x","transcript_path":"%s"}' "$PWD" "$named" \
    | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "falls back to the generated name" "Generated name" "$(arg_of "$stub" -title)"
rm -rf "$stub" "$named"

# ------------------------------------------------------------- settings ---
# Each case runs the script in a subshell with its own settings file.
with_config() {
    local cfg; cfg=$(mktemp "$TMPDIR/cfg.XXXXXX"); printf '%b' "$1" > "$cfg"; shift
    CCTN_CONFIG="$cfg" "$@"; local rc=$?; rm -f "$cfg"; return $rc
}
cfg_value() { with_config "$1" bash -c 'source "$1"; setting "$2"' _ "$EXE" "$2"; }

check "a setting defaults when the file is missing" "2" "$(CCTN_CONFIG=/nonexistent bash -c 'source "$1"; setting CCTN_CLEAR_DELAY' _ "$EXE")"
check "reads a plain value" "5" "$(cfg_value 'CCTN_CLEAR_DELAY=5\n' CCTN_CLEAR_DELAY)"
check "trims spaces around an unquoted value" "30" "$(cfg_value 'CCTN_EXPIRE_AFTER =  30  \n' CCTN_EXPIRE_AFTER)"
check "keeps spaces inside quotes" "CC: " "$(cfg_value 'CCTN_TITLE_PREFIX="CC: "\n' CCTN_TITLE_PREFIX)"
check "accepts a short lower-case name" "7" "$(cfg_value 'clear_delay=7\n' CCTN_CLEAR_DELAY)"
check "ignores comments" "2" "$(cfg_value '# CCTN_CLEAR_DELAY=9\n' CCTN_CLEAR_DELAY)"
check "reads a Windows line ending" "4" "$(cfg_value 'CCTN_CLEAR_DELAY=4\r\n' CCTN_CLEAR_DELAY)"
check "reads a last line with no line break" "6" "$(cfg_value 'CCTN_CLEAR_DELAY=6' CCTN_CLEAR_DELAY)"
check "never runs a value" '$(touch /tmp/cctn-pwned)' "$(cfg_value 'CCTN_SOUND_DONE=$(touch /tmp/cctn-pwned)\n' CCTN_SOUND_DONE)"
check "an unknown name sets nothing" "" "$(with_config 'CCTN_BOGUS=1\nPATH=/nowhere\n' bash -c 'source "$1"; printf "%s" "${CCTN_BOGUS:-}"; [ "$PATH" = /nowhere ] && printf moved' _ "$EXE")"
check "the environment wins over the file" "2" "$(CCTN_CLEAR_DELAY=2 cfg_value 'CCTN_CLEAR_DELAY=5\n' CCTN_CLEAR_DELAY)"
check "a non-number delay falls back to the default" "2" "$(with_config 'CCTN_CLEAR_DELAY=soon\n' bash -c 'source "$1"; setting_seconds CCTN_CLEAR_DELAY' _ "$EXE")"

check "a later line wins over an earlier one" "10" "$(cfg_value 'CCTN_CLEAR_DELAY=5\nCCTN_CLEAR_DELAY=10\n' CCTN_CLEAR_DELAY)"
check "reads past a byte order mark" "3" "$(cfg_value '\xEF\xBB\xBFCCTN_CLEAR_DELAY=3\n' CCTN_CLEAR_DELAY)"
check "strips quotes with spaces around them" "a b" "$(cfg_value 'CCTN_TITLE_PREFIX = "a b"  \n' CCTN_TITLE_PREFIX)"

cfgfile="$TMPDIR/written-config"
CCTN_CONFIG="$cfgfile" bash "$EXE" config set clear_delay 3 >/dev/null
CCTN_CONFIG="$cfgfile" bash "$EXE" config set sound-done none >/dev/null
CCTN_CONFIG="$cfgfile" bash "$EXE" config set clear_delay 8 >/dev/null
check "config set writes and replaces one line" "2" "$(grep -c '^CCTN_' "$cfgfile")"
check "config set's value reads back" "8" "$(CCTN_CONFIG="$cfgfile" bash -c 'source "$1"; setting CCTN_CLEAR_DELAY' _ "$EXE")"
CCTN_CONFIG="$cfgfile" bash "$EXE" config unset clear_delay >/dev/null
check "config unset returns to the default" "2" "$(CCTN_CONFIG="$cfgfile" bash -c 'source "$1"; setting CCTN_CLEAR_DELAY' _ "$EXE")"
CCTN_CONFIG="$cfgfile" bash "$EXE" config set bogus 1 >/dev/null 2>&1
check "config set refuses an unknown name" "1" "$?"
rm -f "$cfgfile"

# A new file explains itself: every setting is there, commented out at its
# default, and edits change one line in place.
CCTN_CONFIG="$cfgfile" bash "$EXE" config set clear_delay 3 >/dev/null
check "a new file lists every setting" "$(printf '%s\n' "$SETTINGS_TABLE" | grep -c .)" "$(grep -c '^# CCTN_\|^CCTN_' "$cfgfile")"
check "the set value replaces its commented line" "0" "$(grep -c '^# CCTN_CLEAR_DELAY' "$cfgfile")"
echo "# a note of my own" >> "$cfgfile"
CCTN_CONFIG="$cfgfile" bash "$EXE" config unset clear_delay >/dev/null
check "unset turns the line back into its commented default" '# CCTN_CLEAR_DELAY="2"' "$(grep 'CCTN_CLEAR_DELAY' "$cfgfile")"
check "edits keep other comments" "1" "$(grep -c '^# a note of my own$' "$cfgfile")"
check "the template itself sets nothing" "0" "$(grep -c '^CCTN_' "$cfgfile")"
rm -f "$cfgfile"

stub=$(make_stub notty)
payload Stop "x" sid-off ',"last_assistant_message":"done"' | with_config 'CCTN_NOTIFY_ON_DONE=0\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "notify_on_done=0 posts nothing" "0" "$(call_count "$stub")"
rm -rf "$stub"
stub=$(make_stub notty)
payload Notification "perm" sid-off2 | with_config 'CCTN_NOTIFY_ON_INPUT=no\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "notify_on_input=no posts nothing" "0" "$(call_count "$stub")"
rm -rf "$stub"
stub=$(make_stub notty)
payload Stop "x" sid-snd ',"last_assistant_message":"done"' | with_config 'CCTN_SOUND_DONE=none\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "sound none posts without a sound" "0" "$(grep -c -- '-sound' "$stub/calls.txt")"
rm -rf "$stub"
stub=$(make_stub notty)
payload Notification "perm" sid-snd2 | with_config 'CCTN_SOUND_INPUT=Ping\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a chosen sound is used" "Ping" "$(arg_of "$stub" -sound)"
rm -rf "$stub"

stub=$(make_stub notty)
printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"sid-type"}' "$PWD" | with_config 'CCTN_CLEAR_ON_TYPE=0\n' env PATH="$stub:$PATH" bash "$EXE" clear
check "clear_on_type=0 clears nothing" "0" "$(call_count "$stub")"
rm -rf "$stub"

# Not notifying for the tab in front: Terminal.app is faked as the front app,
# with a given tty in its front tab.
# $2 is the idle time in seconds that a faked ioreg reports (default 0).
front_stub() {
    local dir; dir=$(make_stub noresolve)
    printf '#!/bin/bash\necho "    |   \\"HIDIdleTime\\" = %s"\n' "$(( ${2:-0} * 1000000000 ))" > "$dir/ioreg"; chmod +x "$dir/ioreg"
    printf '#!/bin/bash\ncase "$1" in front) echo "ASN:0x0-0x1:";; info) echo "\\"CFBundleIdentifier\\"=\\"com.apple.Terminal\\" bundleID=\\"com.apple.Terminal\\"";; esac\n' > "$dir/lsappinfo"
    printf '#!/bin/bash\ncase "$*" in *"selected tab"*) echo "%s";; esac\nexit 0\n' "$1" > "$dir/osascript"
    chmod +x "$dir/lsappinfo" "$dir/osascript"
    echo "$dir"
}
my_tty=$(session_tty)
if [ -n "$my_tty" ]; then
    stub=$(front_stub "$my_tty")
    payload Stop "x" sid-front ',"last_assistant_message":"done"' | env -u CCTN_NOTIFY_WHEN_FOCUSED PATH="$stub:$PATH" bash "$EXE" notify
    check "posts nothing for the tab in front" "0" "$(call_count "$stub")"
    rm -rf "$stub"
    stub=$(front_stub "/dev/ttys999")
    payload Stop "x" sid-front2 ',"last_assistant_message":"done"' | env -u CCTN_NOTIFY_WHEN_FOCUSED PATH="$stub:$PATH" bash "$EXE" notify
    check "posts for a tab that is not in front (tamper check)" "1" "$(call_count "$stub")"
    rm -rf "$stub"
    stub=$(front_stub "$my_tty")
    payload Stop "x" sid-front3 ',"last_assistant_message":"done"' | CCTN_NOTIFY_WHEN_FOCUSED=1 PATH="$stub:$PATH" bash "$EXE" notify
    check "notify_when_focused=1 posts for the tab in front" "1" "$(call_count "$stub")"
    rm -rf "$stub"
    stub=$(front_stub "$my_tty" 120)
    payload Stop "x" sid-away ',"last_assistant_message":"done"' | env -u CCTN_NOTIFY_WHEN_FOCUSED PATH="$stub:$PATH" bash "$EXE" notify
    check "posts for the tab in front when you have been away" "1" "$(call_count "$stub")"
    rm -rf "$stub"
    stub=$(front_stub "$my_tty" 120)
    payload Stop "x" sid-away2 ',"last_assistant_message":"done"' | env -u CCTN_NOTIFY_WHEN_FOCUSED CCTN_AWAY_AFTER=0 PATH="$stub:$PATH" bash "$EXE" notify
    check "away_after=0 never posts for the tab in front" "0" "$(call_count "$stub")"
    rm -rf "$stub"
else
    skip "front-tab tests" "no tty for this session"
fi
check "a tty handle matches Terminal's front tab with that tty" "yes" "$(handles_match tty:/dev/ttys1 $'terminal:/dev/ttys1\n/dev/ttys1' && echo yes)"
check "a tty handle matches iTerm2's front tab with that tty" "yes" "$(handles_match tty:/dev/ttys5 $'iterm:A\n/dev/ttys5' && echo yes)"
check "different tabs do not match" "no" "$(handles_match iterm:A $'iterm:B\n/dev/ttys2' || echo no)"
check "an empty front tab matches nothing" "no" "$(handles_match iterm:A '' || echo no)"

stub=$(make_stub notty)
payload Stop "x" sid-bc ',"last_assistant_message":"a real reply"' | with_config 'CCTN_BANNER_CHARS=abc\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a bad banner_chars still shows the reply" "a real reply" "$(arg_of "$stub" -message)"
rm -rf "$stub"
stub=$(make_stub notty)
payload Stop "x" sid-dash ',"last_assistant_message":"-1 test failed"' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a reply starting with a dash stays a value" $'\xE2\x80\x8B-1 test failed' "$(arg_of "$stub" -message)"
rm -rf "$stub"
err_out=$(watch_ask 'this is not applescript' 2>&1 >/dev/null)
case "$err_out" in "watch: osascript failed"*) ok "the watcher reports an AppleScript error" ;;
    *) fail "the watcher reports an AppleScript error" "got [$err_out]" ;; esac

# The "waiting for your input" reminder must not replace the reply.
idle_payload() {
    printf '{"hook_event_name":"Notification","cwd":"%s","session_id":"%s","message":"%s"%s}' "$PWD" "$1" "$2" "${3:-}"
}
stub=$(make_stub notty)
idle_payload sid-idle "Claude is waiting for your input" ',"notification_type":"idle_prompt"' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "skips the idle reminder" "0" "$(call_count "$stub")"
idle_payload sid-idle2 "Claude is waiting for your input" | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "skips the idle reminder from an older Claude Code" "0" "$(call_count "$stub")"
idle_payload sid-perm "Claude needs your permission to use Bash" ',"notification_type":"permission_prompt"' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "still posts a permission request (tamper check)" "1" "$(call_count "$stub")"
rm -rf "$stub"
stub=$(make_stub notty)
idle_payload sid-idle3 "Claude is waiting for your input" ',"notification_type":"idle_prompt"' | CCTN_NOTIFY_ON_IDLE=1 CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "notify_on_idle=1 posts the reminder" "1" "$(call_count "$stub")"
rm -rf "$stub"

# Permission prompts say what is being asked, and the generic Notification
# that follows for the same prompt does not replace it.
perm_payload() {
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PermissionRequest","cwd":sys.argv[1],"session_id":sys.argv[2],"tool_name":sys.argv[3],"tool_input":json.loads(sys.argv[4])}))' "$PWD" "$1" "$2" "$3"
}
stub=$(make_stub notty)
perm_payload sid-perm-a Bash '{"command":"git push origin main"}' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a permission request names the command" "Wants to run: git push origin main" "$(arg_of "$stub" -message)"
idle_payload sid-perm-a "Claude needs your permission" ',"notification_type":"permission_prompt"' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "the generic permission notice after it is dropped" "1" "$(call_count "$stub")"
idle_payload sid-perm-b "Claude needs your permission" ',"notification_type":"permission_prompt"' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a generic permission notice with no detailed one still posts (tamper check)" "2" "$(call_count "$stub")"
rm -rf "$stub"
stub=$(make_stub notty)
perm_payload sid-perm-c Edit "{\"file_path\":\"$PWD/src/app.ts\"}" | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "an edit request shows the path from the project folder" "Wants to edit: src/app.ts" "$(arg_of "$stub" -message)"
perm_payload sid-perm-d mcp__plugin_linear-gravitykit_linear-gravitykit__save_issue '{"title":"Fix the map header"}' | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "an MCP request names the server and tool" "Wants to use linear-gravitykit save_issue: Fix the map header" "$(arg_of "$stub" -message 2)"
rm -rf "$stub"

# The old name still works, and its clicks point at the new file.
stub=$(make_stub notty)
payload Notification "old name" sid-oldname | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$REPO_DIR/bin/claude-code-tab-notify" notify
check "the old name still posts" "old name" "$(arg_of "$stub" -message)"
rm -rf "$stub"
check "the old name resolves to the new file" "$REPO_DIR/bin/agent-tab-notify" "$(bash -c 'source "$1"; printf %s "$SELF"' _ "$REPO_DIR/bin/claude-code-tab-notify")"

# The installer points hooks from before the rename at this checkout.
fake_home=$(mktemp -d "$TMPDIR/home.XXXXXX")
mkdir -p "$fake_home/.claude"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/old/place/bin/claude-code-tab-notify\" notify"},{"type":"command","command":"/other/tool"}]}]}}' > "$fake_home/.claude/settings.json"
HOME="$fake_home" CODEX_HOME="$fake_home/no-codex" bash "$REPO_DIR/install.sh" >/dev/null 2>&1
installed=$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; print(";".join(sorted(e+"="+x["command"] for e,g in h.items() for gg in g for x in gg["hooks"])))' "$fake_home/.claude/settings.json")
case "$installed" in *"Stop=\"$REPO_DIR/bin/agent-tab-notify\" notify"*) ok "install moves an old hook to the new name" ;; *) fail "install moves an old hook to the new name" "got [$installed]" ;; esac
case "$installed" in *"PermissionRequest=\"$REPO_DIR/bin/agent-tab-notify\" notify"*) ok "install adds the PermissionRequest hook" ;; *) fail "install adds the PermissionRequest hook" "got [$installed]" ;; esac
case "$installed" in *"Stop=/other/tool"*) ok "install leaves other hooks alone" ;; *) fail "install leaves other hooks alone" "got [$installed]" ;; esac
check "install leaves no old-name hook" "0" "$(grep -c 'bin/claude-code-tab-notify' "$fake_home/.claude/settings.json")"
HOME="$fake_home" CODEX_HOME="$fake_home/no-codex" bash "$REPO_DIR/uninstall.sh" >/dev/null 2>&1
check "uninstall removes every hook it added" "0" "$(grep -c 'tab-notify' "$fake_home/.claude/settings.json")"
rm -rf "$fake_home"

# Expiry: the notification removes itself, and an older timer never removes
# the newer notification that replaced its own.
stub=$(make_stub notty)
payload Stop "x" sid-exp ',"last_assistant_message":"one"' | with_config 'CCTN_EXPIRE_AFTER=1\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
sleep 2.5
check "expire_after removes the notification" "-remove" "$(sed -n 2p "$stub/calls.txt" | cut -f1)"
rm -rf "$stub"
stub=$(make_stub notty)
payload Stop "x" sid-exp2 ',"last_assistant_message":"one"' | with_config 'CCTN_EXPIRE_AFTER=1\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
payload Stop "x" sid-exp2 ',"last_assistant_message":"two"' | with_config 'CCTN_EXPIRE_AFTER=3\n' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
sleep 2
check "an older timer leaves the newer notification" "0" "$(grep -c -- '-remove' "$stub/calls.txt")"
sleep 2
check "the newer notification's own timer removes it" "1" "$(grep -c -- '-remove' "$stub/calls.txt")"
rm -rf "$stub"
# Turning expiry off must also stop the timer of the notification it replaces.
stub=$(make_stub notty)
payload Stop "x" sid-exp3 ',"last_assistant_message":"one"' | with_config 'CCTN_EXPIRE_AFTER=1
' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
payload Stop "x" sid-exp3 ',"last_assistant_message":"two"' | with_config 'CCTN_EXPIRE_AFTER=0
' env CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
sleep 2
check "an old timer leaves a notification posted with expiry off" "0" "$(grep -c -- '-remove' "$stub/calls.txt")"
rm -rf "$stub"

# Two sessions with no tab and no tty must still not overwrite each other; the
# Claude session id is the only thing left to tell them apart.
stub=$(make_stub notty)
# CCTN_ALWAYS_NOTIFY because a session with no tty is otherwise skipped when
# iTerm's integration is installed; this test is about grouping, not the skip.
payload Notification "session A" sid-aaa | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
payload Notification "session B" sid-bbb | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
ga=$(arg_of "$stub" -group 1); gb=$(arg_of "$stub" -group 2)
if [ -n "$ga" ] && [ "$ga" != "$gb" ]; then ok "two sessions get different groups"
else fail "two sessions get different groups" "got [$ga] and [$gb]"; fi
rm -rf "$stub"

# Tamper check: drop the session id and the collision must come back, or the
# assertion above proves nothing.
stub=$(make_stub notty)
for msg in "collide A" "collide B"; do
    printf '{"hook_event_name":"Notification","message":"%s","cwd":"%s"}' "$msg" "$PWD" \
        | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
done
ga=$(arg_of "$stub" -group 1); gb=$(arg_of "$stub" -group 2)
if [ -n "$ga" ] && [ "$ga" = "$gb" ]; then ok "without a session id they do collide (tamper check)"
else fail "without a session id they do collide (tamper check)" "got [$ga] and [$gb]"; fi
rm -rf "$stub"

# jq is not guaranteed on a hook's PATH; the python fallback must parse.
stub=$(make_stub)
nojq=$(mktemp -d)
for b in bash cat sed head tail cut tr grep basename dirname perl ps pwd python3 mktemp uname date printf; do
    src=$(command -v "$b") && ln -sf "$src" "$nojq/$b"
done
printf '#!/bin/bash\nexit 0\n' > "$nojq/osascript"; chmod +x "$nojq/osascript"
ln -sf "$stub/terminal-notifier" "$nojq/terminal-notifier"
if env -i PATH="$nojq" "$nojq/bash" -c 'command -v jq' >/dev/null 2>&1; then
    skip "parses hook JSON without jq" "jq still reachable in the stub PATH"
else
    payload Notification "no jq here" sid-nojq | \
        env -i HOME="$HOME" PATH="$nojq" CCTN_GROUP_PREFIX="$CCTN_GROUP_PREFIX" \
            CCTN_PENDING_DIR="$CCTN_PENDING_DIR" CCTN_CONFIG="$CCTN_CONFIG" \
            "$nojq/bash" "$EXE" notify
    check "parses hook JSON without jq" "no jq here" "$(arg_of "$stub" -message)"
fi
rm -rf "$nojq" "$stub"
echo

# A terminal that answers too slowly is the failure this guards: the click target
# and the tab name must both survive it.
echo "degraded resolution"
tty=$(session_tty)
if [ -n "$tty" ]; then
    cache="${TMPDIR:-/tmp}/cctn-tabnames/$(echo "$tty" | tr '/' '_')"
    mkdir -p "$(dirname "$cache")"
    printf '◑ CACHED TAB NAME (claude)' > "$cache"

    stub=$(make_stub noresolve)
    payload Notification "degraded" sid-degraded | PATH="$stub:$PATH" bash "$EXE" notify
    # The command is detached because terminal-notifier exits within ~120ms of
    # being relaunched to handle the click, faster than one AppleScript round trip.
    got_exec=$(arg_of "$stub" -execute)
    case "$got_exec" in
        "nohup "*"focus 'tty:$tty'"*"&") ok "click target falls back to the tty, detached" ;;
        *) fail "click target falls back to the tty, detached" "got [$got_exec]" ;;
    esac
    check "reuses the last known tab name, without the status glyph or (claude)" "CACHED TAB NAME" "$(arg_of "$stub" -title)"
    check "the tab name is the only heading (no subtitle)" "" "$(arg_of "$stub" -subtitle)"
    rm -rf "$stub"
else
    skip "degraded resolution tests" "no tty for this session"
fi
echo

echo "unroutable sessions"
if grep -q 'iterm2/cc-status' "$HOME/.claude/settings.json" 2>/dev/null; then
    stub=$(make_stub notty)
    printf '{"hook_event_name":"Stop","message":"x","cwd":"%s","session_id":"bg1"}' "$PWD" \
        | env -u TERM_PROGRAM -u ITERM_SESSION_ID CLAUDE_CODE_SESSION_KIND=bg \
              PATH="$stub:$PATH" bash "$EXE" notify
    check "skips a notification it cannot route when iTerm's integration is installed" \
          "0" "$(call_count "$stub")"

    printf '{"hook_event_name":"Stop","message":"x","cwd":"%s","session_id":"bg1"}' "$PWD" \
        | env -u TERM_PROGRAM -u ITERM_SESSION_ID CLAUDE_CODE_SESSION_KIND=bg \
              CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
    check "CCTN_ALWAYS_NOTIFY overrides the skip" "1" "$(call_count "$stub")"
    rm -rf "$stub"
else
    skip "unroutable session tests" "iTerm's cc-status integration not installed"
fi
echo

# ----------------------------------------------------------------- codex ---
echo "codex"
codex_payload() {
    printf '{"hook_event_name":"%s","cwd":"%s","session_id":"%s","turn_id":"t1","stop_hook_active":false%s}' \
        "$1" "$PWD" "$2" "${3:-}"
}

# No tab, so the title falls back to the agent label, which is what this checks.
stub=$(make_stub notty)
codex_payload Stop 0a0a-codex-title ',"last_assistant_message":"All done here"' \
    | PATH="$stub:$PATH" bash "$EXE" notify
case "$(arg_of "$stub" -title)" in
    "Codex ("*"): Task Complete") ok "a turn_id payload is labeled Codex" ;;
    *) fail "a turn_id payload is labeled Codex" "got [$(arg_of "$stub" -title)]" ;;
esac
check "uses Codex's last_assistant_message" "All done here" "$(arg_of "$stub" -message)"
rm -rf "$stub"

if [ -n "${BASE:-}" ]; then
    live_id="${BASE#iterm:}"
    # The Codex daemon keeps the ITERM_SESSION_ID of whichever tab started it.
    # With no tty above the hook, that id must not be used, even when it names
    # a live tab.
    stub=$(make_stub noancestor)
    codex_payload Stop ffff0000-stale-env | ITERM_SESSION_ID="w0t0p0:$live_id" \
        CCTN_AGENT=codex PATH="$stub:$PATH" bash "$EXE" notify
    case "$(arg_of "$stub" -execute)" in
        *"$live_id"*) fail "ignores the daemon's ITERM_SESSION_ID" "routed to $live_id" ;;
        *) ok "ignores the daemon's ITERM_SESSION_ID" ;;
    esac
    check "posts even when it cannot route" "1" "$(call_count "$stub")"
    rm -rf "$stub"

    # Tamper check: the same environment for Claude does route to that tab, so
    # the assertion above is about the Codex rule and not a broken lookup.
    stub=$(make_stub noancestor)
    payload Stop "x" sid-claude-env | ITERM_SESSION_ID="w0t0p0:$live_id" \
        PATH="$stub:$PATH" bash "$EXE" notify
    case "$(arg_of "$stub" -execute)" in
        *"$live_id"*) ok "Claude still trusts ITERM_SESSION_ID (tamper check)" ;;
        *) fail "Claude still trusts ITERM_SESSION_ID (tamper check)" "got [$(arg_of "$stub" -execute)]" ;;
    esac
    rm -rf "$stub"

    # A daemon-run hook finds its tab by the thread name Codex puts in the title.
    # This tab's name is Claude Code's, whose status glyph animates, so it can
    # change between reading it and matching it. Retry with a fresh read; the
    # tamper check below still proves a wrong name matches nothing.
    codex_home=$(mktemp -d)
    found_codex_tab=""
    for attempt in 1 2 3; do
        tab_name=$(bash "$EXE" resolve "$PWD" | sed -n 2p)
        rm -f "$codex_home/state_5.sqlite"
        /usr/bin/sqlite3 "$codex_home/state_5.sqlite" \
            "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT);
             INSERT INTO threads VALUES ('0123abcd-0000-4000-8000-000000000001', '$(printf '%s' "$tab_name" | sed "s/'/''/g")');"
        stub=$(make_stub noancestor)
        codex_payload Stop 0123abcd-0000-4000-8000-000000000001 \
            | CODEX_HOME="$codex_home" CCTN_AGENT=codex PATH="$stub:$PATH" bash "$EXE" notify
        got_exec=$(arg_of "$stub" -execute)
        rm -rf "$stub"
        case "$got_exec" in *"focus '$BASE'"*) found_codex_tab=1; break ;; esac
    done
    if [ -n "$found_codex_tab" ]; then ok "finds the tab by Codex thread name"
    else fail "finds the tab by Codex thread name" "got [$got_exec] for name [$tab_name]"
    fi

    # Tamper check: a thread with no row resolves nowhere.
    stub=$(make_stub noancestor)
    codex_payload Stop 0123abcd-0000-4000-8000-000000000002 \
        | CODEX_HOME="$codex_home" CCTN_AGENT=codex PATH="$stub:$PATH" bash "$EXE" notify
    case "$(arg_of "$stub" -execute)" in
        *"$live_id"*) fail "an unknown thread resolves nowhere (tamper check)" "routed to $live_id" ;;
        *) ok "an unknown thread resolves nowhere (tamper check)" ;;
    esac
    rm -rf "$stub" "$codex_home"
else
    skip "Codex resolution tests" "this session does not resolve to an iTerm tab"
fi

stub=$(make_stub)
codex_payload UserPromptSubmit 0a0a-codex-clear | PATH="$stub:$PATH" bash "$EXE" clear
check "clear removes the Codex session's group" "$CCTN_GROUP_PREFIX:0a0a-codex-clear" "$(arg_of "$stub" -remove)"
rm -rf "$stub"
echo

# ----------------------------------------------------------------- clear ---
echo "clear"
stub=$(make_stub)
PATH="$stub:$PATH" bash "$EXE" clear "x:sid-clear"
check "clear removes exactly one group" "1" "$(call_count "$stub")"
check "clear targets the right group" "$CCTN_GROUP_PREFIX:sid-clear" "$(arg_of "$stub" -remove)"
rm -rf "$stub"

bash "$EXE" clear "x:no-such-group-at-all"
check "clearing an absent group exits cleanly" "0" "$?"
echo

# --------------------------------------------------------------- markers ---
echo "markers"

# A session with no tab gets a notification but no marker: the watch loop
# matches markers to the frontmost tab, so this one could never be cleared.
stub=$(make_stub notty)
payload Notification "no tab" sid-nomarker | CCTN_ALWAYS_NOTIFY=1 PATH="$stub:$PATH" bash "$EXE" notify
check "a session with no tab still posts" "1" "$(call_count "$stub")"
if [ -e "$(pending_path "$CCTN_GROUP_PREFIX:sid-nomarker")" ]; then
    fail "a session with no tab writes no marker" "found $(pending_path "$CCTN_GROUP_PREFIX:sid-nomarker")"
else ok "a session with no tab writes no marker"; fi
rm -rf "$stub"

# Markers are aged past prune's one-minute grace so only the tab check decides.
old_marker() { printf '%s' "$2" > "$CCTN_PENDING_DIR/$1"; touch -t 202001010000 "$CCTN_PENDING_DIR/$1"; }
has_marker() { [ -e "$CCTN_PENDING_DIR/$1" ] && echo kept || echo dropped; }

old_marker dead-tty "tty:/dev/ttys999"
old_marker dead-terminal "terminal:/dev/ttys999"
old_marker no-tab ""
old_marker unknown-kind "ghostty:some-tab"
old_marker gone-iterm "iterm:00000000-0000-0000-0000-000000000000"
printf '' > "$CCTN_PENDING_DIR/fresh-no-tab"
live_tty=$(ps -axo tty= | grep -m1 '^ttys' | tr -d ' ')
if [ -n "$live_tty" ]; then
    # Two minutes old: past the grace period, but written since this boot.
    printf '%s' "tty:/dev/$live_tty" > "$CCTN_PENDING_DIR/live-tty"
    touch -t "$(date -v-2M +%Y%m%d%H%M)" "$CCTN_PENDING_DIR/live-tty"
    # Same live tty, but written before this boot: the number was reused.
    old_marker reused-tty "tty:/dev/$live_tty"
fi

# The stubbed osascript answers nothing, so iTerm reads as not running.
stub=$(make_stub noresolve)
CCTN_WATCH_QUIET=1 PATH="$stub:$PATH" bash "$EXE" prune
rm -rf "$stub"
check "prune drops a marker whose tty is gone" "dropped" "$(has_marker dead-tty)"
check "prune drops a Terminal.app marker whose tty is gone" "dropped" "$(has_marker dead-terminal)"
check "prune drops a marker with no tab" "dropped" "$(has_marker no-tab)"
check "prune drops an iTerm marker when iTerm is not running" "dropped" "$(has_marker gone-iterm)"
check "prune keeps a marker it cannot check" "kept" "$(has_marker unknown-kind)"
check "prune keeps a marker under a minute old" "kept" "$(has_marker fresh-no-tab)"
if [ -n "$live_tty" ]; then
    check "prune keeps a marker whose tty is live" "kept" "$(has_marker live-tty)"
    check "prune drops a live tty's marker written before this boot" "dropped" "$(has_marker reused-tty)"
else
    skip "prune keeps a marker whose tty is live" "no live tty on this machine"
fi

if app_running "iTerm2"; then
    live_iterm=$(osascript -e 'tell application "iTerm2" to get id of first session of current tab of current window' 2>/dev/null)
    old_marker live-iterm "iterm:$live_iterm"
    old_marker gone-iterm "iterm:00000000-0000-0000-0000-000000000000"
    CCTN_WATCH_QUIET=1 bash "$EXE" prune
    check "prune keeps an iTerm marker whose tab is open" "kept" "$(has_marker live-iterm)"
    check "prune drops an iTerm marker whose tab is closed" "dropped" "$(has_marker gone-iterm)"
else
    skip "prune against a live iTerm" "iTerm2 not running"
fi
echo

echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ]
