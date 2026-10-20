#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 M. Abdullah Onus
#
# Test bin/agit-hook with the hook input of each agent:
#
#   AGIT_GIT=<agit's git> test/hook-test.sh
#
# Without AGIT_GIT, the git on PATH must be agit.  Everything happens
# in a temporary directory; jq is required.  The hook input of the
# agents other than Claude Code comes from the payloads, documented by
# the agent, in test/fixtures/<agent>.

# shellcheck disable=SC2016 # jq filters with jq variables
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
transcript=$fixtures/claude/transcript.jsonl
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
# The agent whose hook input run_hook passes.
ag=claude

run_hook () {
	ev=$1
	test "$ev" = pre-notebook && ev=pre-edit
	if ! sh "$hook" "$ag" "$ev" >"$tmp/out" 2>"$tmp/err"
	then
		fail "agit-hook $ag $ev exited with $?"
	fi
	if test -s "$tmp/err"
	then
		fail "agit-hook $ag $ev wrote to stderr: $(cat "$tmp/err")"
	fi
	if test "$ev" != session-start && test -s "$tmp/out"
	then
		fail "agit-hook $ag $ev printed: $(cat "$tmp/out")"
	fi
}

# The fixture $1 of the agent $ag, with the jq filter $2 applied and
# the remaining arguments passed to jq.
fixture () {
	f=$fixtures/$ag/$1.json
	filter=$2
	shift 2
	jq -c "$@" "$filter" "$f"
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

# The marks of the + ranges (- with a third argument -) of <path> in
# the record of HEAD in <repo>, as "<range> <mark>" lines.
marks () {
	"$GIT" -C "$1" provenance show HEAD |
	awk -v p="$2" -v s="${3:-+}" '$1 == "file" { f = ($2 == p) } f && $1 == s { print $2, $3 }'
}

journal () {
	"$GIT" -C "$1" stamp list
}

repo=$tmp/repo

echo "== session-start"
new_repo repo
export CLAUDE_ENV_FILE="$tmp/env-file"
: >"$CLAUDE_ENV_FILE"
echo "# agit" >"$AGIT_HOME/env"
hook session-start "$repo"
jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$tmp/out" >/dev/null ||
fail "session-start printed no SessionStart JSON: $(cat "$tmp/out")"
ctx=$(jq -r .hookSpecificOutput.additionalContext "$tmp/out")
case "$ctx" in
*"git stamp reason --session $sid --summary -"*) ok "context" ;;
*) fail "unexpected context: $ctx" ;;
esac
grep -qx "export AGIT_SESSION=$sid" "$CLAUDE_ENV_FILE" || fail "AGIT_SESSION not in CLAUDE_ENV_FILE"
grep -qxF "if test -f '$AGIT_HOME/env'; then . '$AGIT_HOME/env'; fi" "$CLAUDE_ENV_FILE" ||
fail "the PATH of agit not in CLAUDE_ENV_FILE: $(cat "$CLAUDE_ENV_FILE")"
rm "$AGIT_HOME/env"
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
# hook.transcript, an option of earlier versions, is ignored.
"$GIT" config --file "$AGIT_HOME/setup.conf" hook.transcript true
hook pre-commit "$repo" "git -C $repo commit -am five"
journal "$repo" | grep -q "^reason .* $sid " || fail "no reason with git -C"
test -z "$(journal "$repo" | awk '$1 == "reason" { print $5 }')" ||
fail "a transcript was recorded: $(journal "$repo")"
"$GIT" -C "$repo" commit -q -am five
"$GIT" config --file "$AGIT_HOME/setup.conf" --unset hook.transcript
ok "hook.reason, and no transcript"

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
test "$(grep -c "is not agit; this session records nothing" "$AGIT_HOME/log/hook.log")" = 1 ||
fail "a git that is not agit not logged once: $(cat "$AGIT_HOME/log/hook.log")"
rm -f "$AGIT_HOME/log/hook.log"
ok "git is not agit, logged once"

echo "== agit is found in AGIT_HOME"
# A git that is not agit first on PATH, and agit installed in
# $AGIT_HOME as install.sh does it.
v=$AGIT_HOME/versions/9.9.9.agit.1
mkdir -p "$v/bin" "$v/libexec/git-core"
: >"$v/libexec/git-core/git-stamp"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$GIT" >"$v/bin/git"
chmod +x "$v/bin/git"
ln -s versions/9.9.9.agit.1 "$AGIT_HOME/current"
unset AGIT_GIT
new_repo found
old_path=$PATH
PATH="$tmp/bin:$PATH"
hook pre-edit "$tmp/found" "$tmp/found/hello.txt"
echo "by the agent" >>"$tmp/found/hello.txt"
hook post-edit "$tmp/found" "$tmp/found/hello.txt"
PATH=$old_path
test "$(journal "$tmp/found" | grep -c " $sid ")" = 2 ||
fail "agit in AGIT_HOME not used: $(journal "$tmp/found")"
test -e "$AGIT_HOME/log/hook.log" && fail "log written: $(cat "$AGIT_HOME/log/hook.log")"
rm "$AGIT_HOME/current"
rm -rf "$AGIT_HOME/versions"
export AGIT_GIT="$GIT"
ok "agit in AGIT_HOME"

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

echo "== Codex"
ag=codex
sid=019a0000-0000-7000-8000-000000000001
new_repo codex
cx=$tmp/codex
printf 'keep\n' >"$cx/delete-me.txt"
printf 'a\nb\nc\nd\ne\n' >"$cx/old-name.txt"
"$GIT" -C "$cx" add .
"$GIT" -C "$cx" commit -q -m files
mkdir -p "$cx/src"
# codex_patch <event> <cwd> <patch>: the hook for apply_patch.
codex_patch () {
	case "$1" in
	pre-edit) fx=pre-tool-use-apply-patch ;;
	*) fx=post-tool-use-apply-patch ;;
	esac
	fixture "$fx" '.session_id = $s | .cwd = $c | .tool_input.command = $p' \
		--arg s "$sid" --arg c "$2" --arg p "$3" | run_hook "$1"
}
codex_bash () {
	case "$1" in
	pre-shell) fx=pre-tool-use-bash ;;
	*) fx=post-tool-use-bash ;;
	esac
	fixture "$fx" '.session_id = $s | .cwd = $c | .tool_input.command = $x' \
		--arg s "$sid" --arg c "$2" --arg x "$3" | run_hook "$1"
}
fixture session-start '.session_id = $s | .cwd = $c' --arg s "$sid" --arg c "$cx" |
run_hook session-start
if ! jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$tmp/out" >/dev/null ||
   ! jq -r .hookSpecificOutput.additionalContext "$tmp/out" |
   grep -qF "git stamp reason --session $sid --summary -"
then
	fail "codex session-start: $(cat "$tmp/out")"
fi
# One patch from the subdirectory src, with relative paths: it adds a
# file in a new directory, updates one, deletes one, and moves one.
patch="*** Begin Patch
*** Add File: new/added.txt
+added by codex
+second line
*** Update File: ../hello.txt
@@
 one
-two
+TWO by codex
 three
*** Delete File: ../delete-me.txt
*** Update File: ../old-name.txt
*** Move to: ../new-name.txt
@@
 d
-e
+E by codex
*** End Patch"
codex_patch pre-edit "$cx/src" "$patch"
mkdir -p "$cx/src/new"
printf 'added by codex\nsecond line\n' >"$cx/src/new/added.txt"
printf 'one\nTWO by codex\nthree\n' >"$cx/hello.txt"
rm "$cx/delete-me.txt"
rm "$cx/old-name.txt"
printf 'a\nb\nc\nd\nE by codex\n' >"$cx/new-name.txt"
codex_patch post-edit "$cx/src" "$patch"
journal "$cx"
test "$(journal "$cx" | grep -c "^begin .* $sid .* model=gpt-5.5-codex tool=codex$")" = 1 ||
fail "codex: expected one begin with the model and tool"
test "$(journal "$cx" | grep -c "^end .* $sid ")" = 1 || fail "codex: expected one end"
# An absolute path, and a patch with CRLF line ends and indented markers.
patch=$(printf '*** Begin Patch\r\n  *** Update File: %s\r\n@@\r\n-three\r\n+three by codex\r\n*** End Patch\r\n' "$cx/hello.txt")
codex_patch pre-edit "$cx" "$patch"
printf 'one\nTWO by codex\nthree by codex\n' >"$cx/hello.txt"
codex_patch post-edit "$cx" "$patch"
# A shell command, and a line changed by a human.
codex_bash pre-shell "$cx" "printf 'made by a command\\n' >shell.txt"
echo "made by a command" >"$cx/shell.txt"
codex_bash post-shell "$cx" "printf 'made by a command\\n' >shell.txt"
echo "by a human" >>"$cx/hello.txt"
"$GIT" -C "$cx" add -A
"$GIT" -C "$cx" commit -q -m "codex"
"$GIT" -C "$cx" provenance show HEAD
test "$(marks "$cx" src/new/added.txt)" = "1-2 AI" || fail "added.txt: $(marks "$cx" src/new/added.txt)"
test "$(marks "$cx" hello.txt)" = "2-3 AI
4 HUMAN" || fail "codex hello.txt: $(marks "$cx" hello.txt)"
test "$(marks "$cx" delete-me.txt -)" = "1 AI" || fail "delete-me.txt: $(marks "$cx" delete-me.txt -)"
test "$(marks "$cx" new-name.txt)" = "1-5 AI" || fail "new-name.txt: $(marks "$cx" new-name.txt)"
test "$(marks "$cx" shell.txt)" = "1 AI" || fail "codex shell.txt: $(marks "$cx" shell.txt)"
"$GIT" -C "$cx" provenance show HEAD | grep -q "model=gpt-5.5-codex tool=codex session=$sid" ||
fail "codex: no actor with the model and tool"
ok "codex edits and shell commands"
# A patch with files in two worktrees: one begin and one end in each.
new_repo codex2
patch="*** Begin Patch
*** Update File: hello.txt
@@
-one
+ONE
*** Update File: $tmp/codex2/hello.txt
@@
-one
+ONE
*** End Patch"
codex_patch pre-edit "$cx" "$patch"
printf 'ONE\nTWO by codex\nthree by codex\nby a human\n' >"$cx/hello.txt"
printf 'ONE\ntwo\nthree\n' >"$tmp/codex2/hello.txt"
codex_patch post-edit "$cx" "$patch"
for r in "$cx" "$tmp/codex2"
do
	test "$(journal "$r" | awk '{ print $1 }' | tr '\n' ' ')" = "begin end " ||
	fail "codex, two worktrees: $(journal "$r")"
done
"$GIT" -C "$cx" commit -q -am two
"$GIT" -C "$tmp/codex2" commit -q -am two
test "$(marks "$tmp/codex2" hello.txt)" = "1 AI" || fail "codex2: $(marks "$tmp/codex2" hello.txt)"
ok "codex, a patch in two worktrees"
# Paths outside a repository, a patch that names no file, and a git
# commit, which is not stamped.
mkdir -p "$tmp/codex-outside"
codex_patch pre-edit "$tmp/codex-outside" "*** Begin Patch
*** Add File: x.txt
+x
*** End Patch"
codex_patch pre-edit "$cx" "not a patch"
codex_bash pre-shell "$cx" "git commit -am x"
test -z "$(journal "$cx")" || fail "codex stamps: $(journal "$cx")"
for ev in session-start pre-edit post-edit pre-shell post-shell session-end
do
	printf '{"session_id": ' | run_hook "$ev"
done
fixture session-end '.session_id = $s | .cwd = $c' --arg s "$sid" --arg c "$cx" |
run_hook session-end
test -e "$AGIT_HOME/run/codex/$sid" && fail "codex session-end left the state file"
ok "codex: nothing outside a repository, malformed input"
ag=claude
sid=test-session

echo "== Cursor"
ag=cursor
sid=5f0e9d1c-2b7a-4c3e-9a51-6d2f8e4b7c10
new_repo cursor
cu=$tmp/cursor
printf 'one\ntwo\ntwo\nthree\n' >"$cu/twice.txt"
printf 'kept\n' >"$cu/whole.txt"
"$GIT" -C "$cu" add .
"$GIT" -C "$cu" commit -q -m files
# cursor_edit <file> <edits>: the hook after the edit, made already.
cursor_edit () {
	fixture after-file-edit \
		'.conversation_id = $s | .workspace_roots = [$w] | .file_path = $f | .edits = $e' \
		--arg s "$sid" --arg w "$cu" --arg f "$1" --argjson e "$2" | run_hook edit
}
cursor_shell () {
	case "$1" in
	pre-shell)
		fixture before-shell-execution \
			'.conversation_id = $s | .workspace_roots = [$w] | .cwd = $c | .command = $x' \
			--arg s "$sid" --arg w "$cu" --arg c "$2" --arg x "$3" ;;
	*)
		fixture after-shell-execution \
			'.conversation_id = $s | .workspace_roots = [$w] | .command = $x' \
			--arg s "$sid" --arg w "$cu" --arg x "$3" ;;
	esac | run_hook "$1"
}
# One replacement.
printf 'one\nTWO by cursor\nthree\n' >"$cu/hello.txt"
cursor_edit "$cu/hello.txt" '[{"old_string": "two", "new_string": "TWO by cursor"}]'
# Two replacements in one edit, the second inside the text of the first.
printf 'one\nTWO by cursor\nthree, 3 by cursor\n' >"$cu/hello.txt"
cursor_edit "$cu/hello.txt" '[{"old_string": "three", "new_string": "three, 3"},
	{"old_string": "3", "new_string": "3 by cursor"}]'
# The editor's agent tells the whole file before and after.
printf 'one\ntwo\ntwo\nthree by cursor\n' >"$cu/twice.txt"
cursor_edit "$cu/twice.txt" '[{"old_string": "one\ntwo\ntwo\nthree\n",
	"new_string": "one\ntwo\ntwo\nthree by cursor\n"}]'
# A new file, written whole.
mkdir -p "$cu/sub"
printf 'new by cursor\n' >"$cu/sub/new.txt"
cursor_edit "$cu/sub/new.txt" '[{"old_string": "", "new_string": "new by cursor\n"}]'
journal "$cu"
test "$(journal "$cu" | grep -c "^edit .* $sid ")" = 4 || fail "cursor: expected 4 edits"
test "$(journal "$cu" | grep -c "^begin .* $sid .* model=claude-4.5-sonnet tool=cursor$")" = 1 ||
fail "cursor: expected one begin with the model and tool"
# Not recorded: a replacement whose new text is twice in the file, one
# whose new text is not there, one with an empty new text, the whole
# write of a tracked file, and a file that is not UTF-8.
printf 'one\ntwo\ntwo\nthree by cursor\nfour\n' >"$cu/twice.txt"
cursor_edit "$cu/twice.txt" '[{"old_string": "", "new_string": "two"}]'
cursor_edit "$cu/twice.txt" '[{"old_string": "x", "new_string": "not there"}]'
cursor_edit "$cu/twice.txt" '[{"old_string": "five\n", "new_string": ""}]'
printf 'rewritten by cursor\n' >"$cu/whole.txt"
cursor_edit "$cu/whole.txt" '[{"old_string": "", "new_string": "rewritten by cursor\n"}]'
printf 'caf\351\n' >"$cu/latin1.txt"
cursor_edit "$cu/latin1.txt" '[{"old_string": "", "new_string": "x"}]'
cursor_edit "$cu/hello.txt" '"not an array"'
test "$(journal "$cu" | grep -c "^edit ")" = 4 || fail "cursor: uncertain edits recorded: $(journal "$cu")"
for want in "twice.txt: the replacements cannot be undone" "whole.txt: a write of the whole file" \
	"latin1.txt: not UTF-8 text" "hello.txt: the replacements cannot be undone"
do
	grep -qF "$want" "$AGIT_HOME/log/hook.log" || fail "cursor: not logged: $want"
done
rm -f "$AGIT_HOME/log/hook.log"
# A shell command: afterShellExecution has no cwd.
cursor_shell pre-shell "$cu/sub" "echo made by a command >../shell.txt"
echo "made by a command" >"$cu/shell.txt"
cursor_shell post-shell "" "echo made by a command >../shell.txt"
cursor_shell pre-shell "$cu" "git commit -am x"
cursor_shell post-shell "" "git commit -am x"
echo "by a human" >>"$cu/hello.txt"
"$GIT" -C "$cu" add -A
"$GIT" -C "$cu" commit -q -m cursor
"$GIT" -C "$cu" provenance show HEAD
test "$(marks "$cu" hello.txt)" = "2-3 AI
4 HUMAN" || fail "cursor hello.txt: $(marks "$cu" hello.txt)"
test "$(marks "$cu" twice.txt)" = "4 AI
5 HUMAN" || fail "cursor twice.txt: $(marks "$cu" twice.txt)"
test "$(marks "$cu" sub/new.txt)" = "1 AI" || fail "cursor new.txt: $(marks "$cu" sub/new.txt)"
test "$(marks "$cu" whole.txt)" = "1 HUMAN" || fail "cursor whole.txt: $(marks "$cu" whole.txt)"
test "$(marks "$cu" shell.txt)" = "1 AI" || fail "cursor shell.txt: $(marks "$cu" shell.txt)"
"$GIT" -C "$cu" provenance show HEAD | grep -q "model=claude-4.5-sonnet tool=cursor session=$sid" ||
fail "cursor: no actor with the model and tool"
ok "cursor edits and shell commands"
mkdir -p "$tmp/cursor-outside"
printf 'x\n' >"$tmp/cursor-outside/x.txt"
cursor_edit "$tmp/cursor-outside/x.txt" '[{"old_string": "", "new_string": "x\n"}]'
fixture after-file-edit '.conversation_id = ""' | run_hook edit
for ev in edit pre-shell post-shell
do
	printf '{"conversation_id": ' | run_hook "$ev"
done
test -z "$(journal "$cu")" || fail "cursor stamps: $(journal "$cu")"
ok "cursor: nothing outside a repository, malformed input"
rm -f "$AGIT_HOME/log/hook.log"
ag=claude
sid=test-session

echo "== Gemini CLI"
ag=gemini
sid=8b2f7c4e-1d3a-4f5b-9e6c-7a8d9b0c1e2f
new_repo gemini
ge=$tmp/gemini
mkdir -p "$ge/sub"
# gemini_tool <event> <fixture> <jq filter> <jq args>...: a tool hook.
gemini_tool () {
	ev=$1 fx=$2 filter=$3
	shift 3
	fixture "$fx" ".session_id = \$s | .cwd = \$c | $filter" \
		--arg s "$sid" --arg c "$ge" "$@" | run_hook "$ev"
}
fixture session-start '.session_id = $s | .cwd = $c' --arg s "$sid" --arg c "$ge" |
run_hook session-start
if ! jq -r .hookSpecificOutput.additionalContext "$tmp/out" |
   grep -qF "git stamp reason --session $sid --summary -"
then
	fail "gemini session-start: $(cat "$tmp/out")"
fi
# write_file of a new file, with a relative path.
gemini_tool pre-edit before-tool-write-file '.tool_input.file_path = "sub/new.txt"'
printf 'new by gemini\n' >"$ge/sub/new.txt"
gemini_tool post-edit after-tool-write-file '.tool_input.file_path = "sub/new.txt"'
# replace in an existing file.
gemini_tool pre-edit before-tool-replace '.tool_input.file_path = $f' --arg f "$ge/hello.txt"
printf 'one\nTWO by gemini\nthree\n' >"$ge/hello.txt"
gemini_tool post-edit after-tool-replace '.tool_input.file_path = $f' --arg f "$ge/hello.txt"
# A shell command in a subdirectory.
gemini_tool pre-shell before-tool-run-shell-command \
	'.tool_input.command = "echo x >made.txt" | .tool_input.dir_path = "sub"'
echo "made by a command" >"$ge/sub/made.txt"
gemini_tool post-shell after-tool-run-shell-command \
	'.tool_input.command = "echo x >made.txt" | .tool_input.dir_path = "sub"'
journal "$ge"
test "$(journal "$ge" | grep -c "^begin .* $sid .* tool=gemini-cli$")" = 3 ||
fail "gemini: expected 3 begin entries with the tool"
echo "by a human" >>"$ge/hello.txt"
"$GIT" -C "$ge" add -A
"$GIT" -C "$ge" commit -q -m gemini
"$GIT" -C "$ge" provenance show HEAD
test "$(marks "$ge" sub/new.txt)" = "1 AI" || fail "gemini new.txt: $(marks "$ge" sub/new.txt)"
test "$(marks "$ge" hello.txt)" = "2 AI
4 HUMAN" || fail "gemini hello.txt: $(marks "$ge" hello.txt)"
test "$(marks "$ge" sub/made.txt)" = "1 AI" || fail "gemini made.txt: $(marks "$ge" sub/made.txt)"
"$GIT" -C "$ge" provenance show HEAD | grep -q "tool=gemini-cli session=$sid" ||
fail "gemini: no actor with the tool"
ok "gemini edits and shell commands"
mkdir -p "$tmp/gemini-outside"
fixture before-tool-write-file '.session_id = $s | .cwd = $c | .tool_input.file_path = "x.txt"' \
	--arg s "$sid" --arg c "$tmp/gemini-outside" | run_hook pre-edit
for ev in session-start pre-edit post-edit pre-shell post-shell session-end
do
	printf '{"session_id": ' | run_hook "$ev"
done
test -z "$(journal "$ge")" || fail "gemini stamps: $(journal "$ge")"
fixture session-end '.session_id = $s | .cwd = $c' --arg s "$sid" --arg c "$ge" |
run_hook session-end
ok "gemini: nothing outside a repository, malformed input"
ag=claude
sid=test-session

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
