#!/bin/bash
# Test suite.
#
# Assertions capture the arguments handed to terminal-notifier rather than
# reading delivered notifications back, which depends on Notification Center
# answering and fails for reasons unrelated to this code (a Focus mode, or
# `terminal-notifier -list` hanging).

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
EXE="$REPO_DIR/bin/claude-code-tab-notify"

export CCTN_GROUP_PREFIX="cctn-test"
# The real marker directory is what the installed watch agent reads, so a
# marker the suite leaves there keeps that agent polling iTerm every second.
export CCTN_PENDING_DIR; CCTN_PENDING_DIR=$(mktemp -d)
trap 'rm -rf "$CCTN_PENDING_DIR"' EXIT

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
case "$(arg_of "$stub" -title)" in
    "cctn: "*) ok "title is prefixed so it is distinguishable from iTerm's own" ;;
    *) fail "title is prefixed" "got [$(arg_of "$stub" -title)]" ;;
esac
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
            CCTN_PENDING_DIR="$CCTN_PENDING_DIR" \
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
    saved=""; [ -f "$cache" ] && saved=$(cat "$cache")
    printf 'CACHED TAB NAME' > "$cache"

    stub=$(make_stub noresolve)
    payload Notification "degraded" sid-degraded | PATH="$stub:$PATH" bash "$EXE" notify
    # The command is detached because terminal-notifier exits within ~120ms of
    # being relaunched to handle the click, faster than one AppleScript round trip.
    got_exec=$(arg_of "$stub" -execute)
    case "$got_exec" in
        "nohup "*"focus 'tty:$tty'"*"&") ok "click target falls back to the tty, detached" ;;
        *) fail "click target falls back to the tty, detached" "got [$got_exec]" ;;
    esac
    check "reuses the last known tab name" "CACHED TAB NAME" "$(arg_of "$stub" -subtitle)"
    rm -rf "$stub"

    if [ -n "$saved" ]; then printf '%s' "$saved" > "$cache"; else rm -f "$cache"; fi
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

stub=$(make_stub)
codex_payload Stop 0a0a-codex-title ',"last_assistant_message":"All done here"' \
    | PATH="$stub:$PATH" bash "$EXE" notify
case "$(arg_of "$stub" -title)" in
    "cctn: Codex ("*) ok "a turn_id payload is labeled Codex" ;;
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
    tab_name=$(bash "$EXE" resolve "$PWD" | sed -n 2p)
    codex_home=$(mktemp -d)
    /usr/bin/sqlite3 "$codex_home/state_5.sqlite" \
        "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT);
         INSERT INTO threads VALUES ('0123abcd-0000-4000-8000-000000000001', '$(printf '%s' "$tab_name" | sed "s/'/''/g")');"
    stub=$(make_stub noancestor)
    codex_payload Stop 0123abcd-0000-4000-8000-000000000001 \
        | CODEX_HOME="$codex_home" CCTN_AGENT=codex PATH="$stub:$PATH" bash "$EXE" notify
    case "$(arg_of "$stub" -execute)" in
        *"focus '$BASE'"*) ok "finds the tab by Codex thread name" ;;
        *) fail "finds the tab by Codex thread name" "got [$(arg_of "$stub" -execute)] for name [$tab_name]" ;;
    esac
    rm -rf "$stub"

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
