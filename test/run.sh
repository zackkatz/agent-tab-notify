#!/bin/bash
# Test suite. Posts only into its own notification group, and removes what it posts.
#
# Tests that need a specific terminal running are skipped rather than failed, so
# the suite is honest on a machine that has only one of them.

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
EXE="$REPO_DIR/bin/claude-code-tab-notify"

export CCTN_GROUP_PREFIX="cctn-test"

PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "       $2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1 ($2)"; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else fail "$name" "expected [$expected], got [$actual]"; fi
}

# A test that posts must be able to see what landed, so every assertion about a
# notification reads terminal-notifier's own list rather than trusting exit codes.
group_message() { terminal-notifier -list "$1" 2>/dev/null | sed -n '2p' | cut -f4; }
remove_group()  { terminal-notifier -remove "$1" >/dev/null 2>&1; }

payload() {
    printf '{"hook_event_name":"%s","message":"%s","cwd":"%s","session_id":"%s"%s}' \
        "$1" "$2" "$PWD" "$3" "${4:-}"
}

source "$EXE"

echo "claude-code-tab-notify tests"
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
        got=$(env -u ITERM_SESSION_ID bash "$EXE" resolve "$PWD" | head -1)
        check "resolves without ITERM_SESSION_ID" "$BASE" "$got"

        # iTerm assigns a new id when it restores a tab, so a stale value must
        # not win over a tty match.
        got=$(ITERM_SESSION_ID='w0t0p0:00000000-0000-0000-0000-000000000000' \
              bash "$EXE" resolve "$PWD" | head -1)
        check "ignores a stale ITERM_SESSION_ID" "$BASE" "$got"
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
    dirs=$(osascript -e 'tell application "Ghostty"
set out to ""
repeat with w in windows
repeat with t in tabs of w
repeat with trm in terminals of t
set out to out & (working directory of trm) & linefeed
end repeat
end repeat
end repeat
return out
end tell' 2>/dev/null)
    uniq_dir=$(echo "$dirs" | grep -v '^$' | sort | uniq -c | awk '$1==1 {print substr($0, index($0,$2)); exit}')
    dupe_dir=$(echo "$dirs" | grep -v '^$' | sort | uniq -c | awk '$1>1 {print substr($0, index($0,$2)); exit}')
    if [ -n "$uniq_dir" ]; then
        got=$(resolve_ghostty "$uniq_dir" | head -1)
        case "$got" in
            ghostty:*) ok "Ghostty resolves a directory open in exactly one tab" ;;
            *) fail "Ghostty resolves a directory open in exactly one tab" "got [$got]" ;;
        esac
    else
        skip "Ghostty unique-directory match" "no directory is open in exactly one tab"
    fi
    if [ -n "$dupe_dir" ]; then
        # Sending you to the wrong tab is worse than sending you nowhere.
        check "Ghostty refuses an ambiguous directory" "" "$(resolve_ghostty "$dupe_dir")"
    else
        skip "Ghostty ambiguity guard" "no directory is open in more than one tab"
    fi
else
    skip "Ghostty tests" "Ghostty not running"
fi
echo

# ---------------------------------------------------------------- notify ---
echo "notify"
if command -v terminal-notifier >/dev/null 2>&1; then
    payload Stop "should not appear" sid-guard ',"stop_hook_active":true' | bash "$EXE" notify
    check "stop_hook_active suppresses the notification" "" "$(group_message "$CCTN_GROUP_PREFIX:sid-guard")"

    payload Notification "posted" sid-post | bash "$EXE" notify
    posted=$(terminal-notifier -list ALL 2>/dev/null | grep -c "$CCTN_GROUP_PREFIX")
    if [ "$posted" -ge 1 ]; then ok "posts a notification"
    else fail "posts a notification" "nothing landed in group prefix $CCTN_GROUP_PREFIX"; fi

    # Two sessions in one directory must not overwrite each other. Without a
    # session id they collapse onto the directory, which is the bug this guards.
    stub=$(mktemp -d)
    printf '#!/bin/bash\nexit 0\n' > "$stub/osascript"
    chmod +x "$stub/osascript"

    PATH="$stub:$PATH" payload Notification "session A" sid-aaa | PATH="$stub:$PATH" bash "$EXE" notify
    PATH="$stub:$PATH" payload Notification "session B" sid-bbb | PATH="$stub:$PATH" bash "$EXE" notify
    a=$(group_message "$CCTN_GROUP_PREFIX:sid-aaa")
    b=$(group_message "$CCTN_GROUP_PREFIX:sid-bbb")
    if [ "$a" = "session A" ] && [ "$b" = "session B" ]; then
        ok "two sessions in one directory keep separate notifications"
    else
        fail "two sessions in one directory keep separate notifications" "got A=[$a] B=[$b]"
    fi

    # Tamper check: remove the session id and the collision must come back, or
    # the test above proves nothing.
    dir_key="$CCTN_GROUP_PREFIX:$(basename "$PWD")"
    remove_group "$dir_key"
    PATH="$stub:$PATH" bash -c "printf '{\"hook_event_name\":\"Notification\",\"message\":\"collide A\",\"cwd\":\"$PWD\"}' | bash '$EXE' notify"
    PATH="$stub:$PATH" bash -c "printf '{\"hook_event_name\":\"Notification\",\"message\":\"collide B\",\"cwd\":\"$PWD\"}' | bash '$EXE' notify"
    check "without a session id they do collide (tamper check)" "collide B" "$(group_message "$dir_key")"
    remove_group "$dir_key"
    rm -rf "$stub"

    # jq is not guaranteed on a hook's PATH; the python fallback must parse.
    nojq=$(mktemp -d)
    for b in bash cat sed head tail cut tr grep basename dirname perl osascript ps pwd python3 terminal-notifier mktemp uname; do
        src=$(command -v "$b") && ln -sf "$src" "$nojq/$b"
    done
    # No-op osascript so nothing resolves and the group key falls back to the
    # session id. This test is about JSON parsing, not about finding a tab.
    # Remove the symlink first: writing through it targets the real binary,
    # which SIP refuses.
    rm -f "$nojq/osascript"
    printf '#!/bin/bash\nexit 0\n' > "$nojq/osascript"
    chmod +x "$nojq/osascript"

    if env -i PATH="$nojq" "$nojq/bash" -c 'command -v jq' >/dev/null 2>&1; then
        skip "parses hook JSON without jq" "jq still reachable in the stub PATH"
    else
        # env -i drops CCTN_GROUP_PREFIX, and without it this test posts into
        # the real notification namespace instead of the test one.
        payload Notification "no jq here" sid-nojq | \
            env -i HOME="$HOME" PATH="$nojq" \
                CCTN_GROUP_PREFIX="$CCTN_GROUP_PREFIX" "$nojq/bash" "$EXE" notify
        check "parses hook JSON without jq" "no jq here" "$(group_message "$CCTN_GROUP_PREFIX:sid-nojq")"
    fi
    rm -rf "$nojq"
else
    skip "notify tests" "terminal-notifier not installed"
fi
echo

# ----------------------------------------------------------------- clear ---
echo "clear"
if command -v terminal-notifier >/dev/null 2>&1; then
    # Stub osascript so no tab resolves, which forces the group key onto the
    # session id. Without this the key is the resolved handle and the assertion
    # below would pass against a notification that was never posted.
    stub=$(mktemp -d)
    printf '#!/bin/bash\nexit 0\n' > "$stub/osascript"
    chmod +x "$stub/osascript"

    payload Notification "to be cleared" sid-clear | PATH="$stub:$PATH" bash "$EXE" notify
    before=$(group_message "$CCTN_GROUP_PREFIX:sid-clear")
    check "posts before clearing (control)" "to be cleared" "$before"
    bash "$EXE" clear "x:sid-clear"
    check "clear removes the notification" "" "$(group_message "$CCTN_GROUP_PREFIX:sid-clear")"
    rm -rf "$stub"

    bash "$EXE" clear "x:no-such-group-at-all"
    check "clearing an absent group exits cleanly" "0" "$?"
else
    skip "clear tests" "terminal-notifier not installed"
fi
echo

# --------------------------------------------------------------- cleanup ---
for key in $(terminal-notifier -list ALL 2>/dev/null | awk -v p="$CCTN_GROUP_PREFIX" -F'\t' '$1 ~ p {print $1}'); do
    remove_group "$key"
done

echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ]
