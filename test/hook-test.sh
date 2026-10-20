#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 M. Abdullah Onus
#
# Test bin/agit-hook with the hook input of Claude Code:
#
#   AGIT_GIT=<agit's git> test/hook-test.sh
#
# Without AGIT_GIT, the git on PATH must be agit.  Everything happens
# in a temporary directory; jq is required.

set -e

root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/bin/agit-hook
fixtures=$root/test/fixtures
GIT=${AGIT_GIT:-$(command -v git)}
"$GIT" stamp -h 2>&1 | grep -q "usage: git stamp" ||
{ echo >&2 "$GIT is not agit; set AGIT_GIT"; exit 1; }
command -v jq >/dev/null || { echo >&2 "jq is required"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
export AGIT_HOME="$tmp/agit-home"
export AGIT_GIT="$GIT"
unset CLAUDE_ENV_FILE
export GIT_CONFIG_NOSYSTEM=1
export HOME="$tmp/home"
mkdir -p "$HOME" "$AGIT_HOME"
"$GIT" config --global user.name "Test User"
"$GIT" config --global user.email test@example.com
"$GIT" config --global init.defaultBranch main
"$GIT" config --global advice.provenanceSession false

sid=test-session
model=claude-test-model
transcript=$fixtures/transcript.jsonl
failures=0

fail () {
	echo "FAIL: $*"
	failures=$((failures + 1))
}

ok () {
	echo "ok: $*"
}

# The hook input of Claude Code for the event $1, in the directory $2,
# with the path or command $3.
input () {
	case "$1" in
	session-start)
		jq -nc --arg s "$sid" --arg c "$2" --arg m "$model" --arg t "$transcript" \
			'{session_id: $s, cwd: $c, transcript_path: $t,
			  hook_event_name: "SessionStart", source: "startup", model: $m}' ;;
	session-end)
		jq -nc --arg s "$sid" --arg c "$2" \
			'{session_id: $s, cwd: $c, hook_event_name: "SessionEnd",
			  reason: "other"}' ;;
	pre-edit|post-edit)
		jq -nc --arg s "$sid" --arg c "$2" --arg f "$3" --arg t "$transcript" \
			--arg e "$(test "$1" = pre-edit && echo PreToolUse || echo PostToolUse)" \
			'{session_id: $s, cwd: $c, transcript_path: $t,
			  hook_event_name: $e, tool_name: "Edit",
			  tool_input: {file_path: $f, old_string: "a", new_string: "b"},
			  tool_use_id: "toolu_1"}' ;;
	pre-notebook)
		jq -nc --arg s "$sid" --arg c "$2" --arg f "$3" \
			'{session_id: $s, cwd: $c, hook_event_name: "PreToolUse",
			  tool_name: "NotebookEdit",
			  tool_input: {notebook_path: $f, new_source: "x"}}' ;;
	pre-*)
		bash_input PreToolUse "$@" ;;
	*)
		bash_input PostToolUse "$@" ;;
	esac
}

bash_input () {
	jq -nc --arg e "$1" --arg s "$sid" --arg c "$3" --arg x "$4" --arg t "$transcript" \
		'{session_id: $s, cwd: $c, transcript_path: $t,
		  hook_event_name: $e, tool_name: "Bash",
		  tool_input: {command: $x}, tool_use_id: "toolu_2"}'
}

# Run the hook for the event $1 with the input on stdin; check that it
# exits with 0 and prints nothing, except for session-start.
run_hook () {
	ev=$1
	test "$ev" = pre-notebook && ev=pre-edit
	if ! sh "$hook" claude "$ev" >"$tmp/out" 2>"$tmp/err"
	then
		fail "agit-hook claude $ev exited with $?"
	fi
	if test -s "$tmp/err"
	then
		fail "agit-hook claude $ev wrote to stderr: $(cat "$tmp/err")"
	fi
	if test "$ev" != session-start && test -s "$tmp/out"
	then
		fail "agit-hook claude $ev printed: $(cat "$tmp/out")"
	fi
}

# hook <event> <dir> [<path-or-command>]
hook () {
	input "$@" | run_hook "$1"
}

new_repo () {
	rm -rf "${tmp:?}/$1"
	"$GIT" init -q "$tmp/$1"
	printf 'one\ntwo\nthree\n' >"$tmp/$1/hello.txt"
	"$GIT" -C "$tmp/$1" add hello.txt
	"$GIT" -C "$tmp/$1" commit -q -m initial
}

# The marks of the + ranges of <path> in the record of HEAD in <repo>,
# as "<range> <mark>" lines.
marks () {
	"$GIT" -C "$1" provenance show HEAD |
	awk -v p="$2" '$1 == "file" { f = ($2 == p) } f && $1 == "+" { print $2, $3 }'
}

journal () {
	"$GIT" -C "$1" stamp list
}

repo=$tmp/repo

echo "== session-start"
new_repo repo
export CLAUDE_ENV_FILE="$tmp/env-file"
: >"$CLAUDE_ENV_FILE"
hook session-start "$repo"
jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$tmp/out" >/dev/null ||
fail "session-start printed no SessionStart JSON: $(cat "$tmp/out")"
ctx=$(jq -r .hookSpecificOutput.additionalContext "$tmp/out")
case "$ctx" in
*"git stamp reason --session $sid --summary -"*) ok "context" ;;
*) fail "unexpected context: $ctx" ;;
esac
grep -qx "export AGIT_SESSION=$sid" "$CLAUDE_ENV_FILE" || fail "AGIT_SESSION not in CLAUDE_ENV_FILE"
grep -qx "model=$model" "$AGIT_HOME/run/claude/$sid" || fail "the model was not remembered"
unset CLAUDE_ENV_FILE
mkdir -p "$tmp/plain"
hook session-start "$tmp/plain"
test -s "$tmp/out" && fail "session-start outside a repository printed: $(cat "$tmp/out")"
ok "no context outside a repository"

echo "== edits"
hook pre-edit "$repo" "$repo/hello.txt"
printf 'one\nTWO by the agent\nthree\n' >"$repo/hello.txt"
hook post-edit "$repo" "$repo/hello.txt"
# A file in a directory that does not exist yet.
hook pre-edit "$repo" "$repo/sub/dir/new.txt"
mkdir -p "$repo/sub/dir"
echo "new file" >"$repo/sub/dir/new.txt"
hook post-edit "$repo" "$repo/sub/dir/new.txt"
# A path with pathspec magic characters.
hook pre-notebook "$repo" "$repo/nb[1].ipynb"
echo "{}" >"$repo/nb[1].ipynb"
hook post-edit "$repo" "$repo/nb[1].ipynb"
journal "$repo"
test "$(journal "$repo" | grep -c "^begin .* $sid .* model=$model tool=claude-code$")" = 3 ||
fail "expected 3 begin entries with the model and tool"
test "$(journal "$repo" | grep -c "^end .* $sid ")" = 3 || fail "expected 3 end entries"
# A line changed outside the hooks.
printf 'one\nTWO by the agent\nthree by a human\n' >"$repo/hello.txt"

echo "== pre-commit without a reason from the agent"
hook pre-shell "$repo" "git add -A && git commit -m 'Add a greeting'"
hook pre-commit "$repo" "git add -A && git commit -m 'Add a greeting'"
journal "$repo" | grep -q "^reason .* $sid " || fail "no reason recorded by pre-commit"
"$GIT" -C "$repo" add -A
"$GIT" -C "$repo" commit -q -m "Add a greeting"
hook post-shell "$repo" "git add -A && git commit -m 'Add a greeting'"
test -z "$(journal "$repo")" || fail "journal not empty after the commit: $(journal "$repo")"
"$GIT" -C "$repo" provenance show HEAD
test "$(marks "$repo" hello.txt)" = "2 AI
3 HUMAN" || fail "hello.txt: $(marks "$repo" hello.txt)"
test "$(marks "$repo" sub/dir/new.txt)" = "1 AI" || fail "new.txt: $(marks "$repo" sub/dir/new.txt)"
test "$(marks "$repo" 'nb[1].ipynb')" = "1 AI" || fail "nb[1].ipynb: $(marks "$repo" 'nb[1].ipynb')"
"$GIT" -C "$repo" provenance show HEAD | grep -q "session=$sid" || fail "no actor for $sid"
summary=$("$GIT" -C "$repo" log -1 --format='%(provenance:summary)')
expected="Request: Add a greeting to hello.txt and a list of names.

I will add the greeting first.

Added the greeting and the names file."
test "$summary" = "$expected" || fail "summary from the transcript: $summary"
ok "summary from the transcript"

echo "== pre-commit with a reason from the agent"
hook pre-edit "$repo" "$repo/hello.txt"
echo four >>"$repo/hello.txt"
hook post-edit "$repo" "$repo/hello.txt"
echo "The agent's own summary." |
"$GIT" -C "$repo" stamp reason --session "$sid" --summary -
hook pre-commit "$tmp" "cd $repo && git commit -am four"
test "$(journal "$repo" | grep -c "^reason ")" = 1 || fail "pre-commit replaced the agent's reason"
"$GIT" -C "$repo" commit -q -am four
test "$("$GIT" -C "$repo" log -1 --format='%(provenance:summary)')" = "The agent's own summary." ||
fail "summary is not the agent's"
ok "the agent's summary is kept"

echo "== pre-commit does nothing for other commands or sessions without stamps"
hook pre-commit "$repo" "git status && echo commit"
hook pre-commit "$repo" "git commit -m nothing"
test -z "$(journal "$repo")" || fail "pre-commit recorded without stamps: $(journal "$repo")"
ok "no reason without stamps"

echo "== shell commands"
hook pre-shell "$repo" "echo made by a command >shell.txt"
echo "made by a command" >"$repo/shell.txt"
hook post-shell "$repo" "echo made by a command >shell.txt"
"$GIT" -C "$repo" add shell.txt
"$GIT" -C "$repo" commit -q -m shell
test "$(marks "$repo" shell.txt)" = "1 AI" || fail "shell.txt with shell stamps: $(marks "$repo" shell.txt)"
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.shell false
hook pre-shell "$repo" "echo again >shell2.txt"
echo "again" >"$repo/shell2.txt"
hook post-shell "$repo" "echo again >shell2.txt"
test -z "$(journal "$repo")" || fail "stamps with hook.shell false: $(journal "$repo")"
"$GIT" -C "$repo" add shell2.txt
"$GIT" -C "$repo" commit -q -m shell2
test "$(marks "$repo" shell2.txt)" = "1 HUMAN" || fail "shell2.txt without shell stamps: $(marks "$repo" shell2.txt)"
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.shell true
ok "shell stamps follow hook.shell"

echo "== no end without a begin"
echo "human change" >>"$repo/hello.txt"
hook post-shell "$repo" "true"
hook post-edit "$repo" "$repo/hello.txt"
test -z "$(journal "$repo")" || fail "end without begin: $(journal "$repo")"
"$GIT" -C "$repo" checkout -q -- hello.txt
ok "no end without a begin"

echo "== commands that move HEAD are not stamped"
hook pre-shell "$repo" "git checkout -b topic"
hook post-shell "$repo" "git checkout -b topic"
test -z "$(journal "$repo")" || fail "stamps around git checkout: $(journal "$repo")"
ok "git checkout not stamped"

echo "== pre-commit with hook.reason false"
hook pre-edit "$repo" "$repo/hello.txt"
echo five >>"$repo/hello.txt"
hook post-edit "$repo" "$repo/hello.txt"
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.reason false
hook pre-commit "$repo" "git commit -am five"
journal "$repo" | grep -q "^reason " && fail "reason recorded with hook.reason false"
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.reason true
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.transcript true
hook pre-commit "$repo" "git -C $repo commit -am five"
blob=$(journal "$repo" | awk '$1 == "reason" { print $5 }')
{ test -n "$blob" && "$GIT" -C "$repo" cat-file -p "$blob" | grep -q "Not part of the summary"; } ||
fail "the transcript was not recorded with hook.transcript true"
"$GIT" -C "$repo" commit -q -am five
"$GIT" config --file "$AGIT_HOME/setup.conf" --unset hook.transcript
ok "hook.reason and hook.transcript"

echo "== nothing happens outside a repository"
mkdir -p "$tmp/outside"
for ev in pre-edit post-edit pre-shell post-shell pre-commit
do
	hook "$ev" "$tmp/outside" "$tmp/outside/file.txt"
done
test -e "$AGIT_HOME/log/hook.log" && fail "log written outside a repository: $(cat "$AGIT_HOME/log/hook.log")"
ok "outside a repository"

echo "== nothing happens with provenance disabled"
new_repo off
"$GIT" -C "$tmp/off" config provenance.enabled false
hook session-start "$tmp/off"
test -s "$tmp/out" && fail "context with provenance disabled"
for ev in pre-edit post-edit pre-shell post-shell
do
	hook "$ev" "$tmp/off" "$tmp/off/hello.txt"
done
test -z "$(journal "$tmp/off")" || fail "stamps with provenance disabled"
ok "provenance disabled"

echo "== nothing happens with a git that is not agit"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
for a
do
	case "\$a" in
	stamp) echo "git: 'stamp' is not a git command. See 'git --help'." >&2; exit 1 ;;
	esac
done
exec "$GIT" "\$@"
EOF
chmod +x "$tmp/bin/git"
new_repo plain-git
AGIT_GIT=$tmp/bin/git
hook session-start "$tmp/plain-git"
test -s "$tmp/out" && fail "context with a git that is not agit"
for ev in pre-edit post-edit pre-shell post-shell
do
	hook "$ev" "$tmp/plain-git" "$tmp/plain-git/hello.txt"
done
AGIT_GIT=$GIT
test -z "$(journal "$tmp/plain-git")" || fail "stamps with a git that is not agit"
test -e "$AGIT_HOME/log/hook.log" && fail "log written for a git that is not agit"
ok "git is not agit"

echo "== malformed input"
for ev in session-start pre-edit post-edit pre-shell post-shell pre-commit session-end
do
	printf '{"session_id": ' | run_hook "$ev"
	test -s "$tmp/out" && fail "$ev printed for malformed input"
	printf '{"session_id": "bad id", "cwd": "%s"}' "$repo" | run_hook "$ev"
	test -s "$tmp/out" && fail "$ev printed for a bad session id"
done
grep -q "cannot read the hook input" "$AGIT_HOME/log/hook.log" || fail "malformed input not logged"
ok "malformed input"

echo "== jq missing"
mkdir -p "$tmp/nojq"
for t in mkdir date wc tail mv cat
do
	ln -s "$(command -v "$t")" "$tmp/nojq/$t"
done
rm -rf "$AGIT_HOME/log"
for _ in 1 2
do
	input pre-edit "$repo" "$repo/hello.txt" >"$tmp/in"
	PATH=$tmp/nojq /bin/sh "$hook" claude pre-edit <"$tmp/in" >"$tmp/out" 2>&1 ||
	fail "exit status without jq"
	test -s "$tmp/out" && fail "output without jq: $(cat "$tmp/out")"
done
test "$(grep -c "jq is not installed" "$AGIT_HOME/log/hook.log")" = 1 ||
fail "jq missing not logged once"
ok "jq missing"

echo "== the model from the transcript"
new_repo model
sid=other-session
hook pre-edit "$tmp/model" "$tmp/model/hello.txt"
journal "$tmp/model" | grep -q "^begin .* $sid .* model=claude-fixture-model tool=claude-code$" ||
fail "no model from the transcript: $(journal "$tmp/model")"
grep -qx "model=claude-fixture-model" "$AGIT_HOME/run/claude/$sid" ||
fail "the model from the transcript was not remembered"
hook session-end "$tmp/model"
sid=test-session
ok "the model from the transcript"

echo "== session-end"
hook session-end "$repo"
test -e "$AGIT_HOME/run/claude/$sid" && fail "session-end left the state file"
ok "session-end"

echo "== the log stays small"
rm -rf "$AGIT_HOME/log"
mkdir -p "$AGIT_HOME/log"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "%0100d\n", i }' >"$AGIT_HOME/log/hook.log"
printf '{' | run_hook pre-edit
size=$(wc -c <"$AGIT_HOME/log/hook.log")
test "$size" -lt 1048576 || fail "the log was not truncated ($size bytes)"
ok "log truncated to $((size)) bytes"

if test $failures -gt 0
then
	echo "== $failures failures"
	exit 1
fi
echo "== all tests passed"
