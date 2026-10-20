#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 M. Abdullah Onus
#
# Test the commands of bin/agit-setup that do not ask questions, with a
# fake claude on PATH that records its arguments:
#
#   test/setup-test.sh
#
# Everything happens in a temporary directory; jq and git are required.

set -e

root=$(cd "$(dirname "$0")/.." && pwd -P)
setup=$root/bin/agit-setup
command -v jq >/dev/null || { echo >&2 "jq is required"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
export HOME="$tmp/home"
export AGIT_HOME="$tmp/agit-home"
mkdir -p "$HOME" "$tmp/bin" "$tmp/project"
conf=$AGIT_HOME/setup.conf
calls=$tmp/claude-calls
failures=0

fail () {
	echo "FAIL: $*"
	failures=$((failures + 1))
}

ok () {
	echo "ok: $*"
}

# A claude that records "<directory>: <arguments>" and keeps the
# installed scopes in a file, for plugin list --json.  It also records
# in $stdin when its stdin is a terminal or has anything to read: the
# real claude (Bun) fails on macOS with "EINVAL: invalid argument,
# kqueue" when its stdin is /dev/tty, as it is under curl | sh.
stdin=$tmp/claude-stdin
cat >"$tmp/bin/claude" <<EOF
#!/bin/sh
echo "\$(pwd -P): \$*" >>"$calls"
if test -t 0
then
	echo "terminal: \$*" >>"$stdin"
elif IFS= read -r line
then
	echo "input: \$*" >>"$stdin"
fi
state="$tmp/claude-installed"
case "\$*" in
--version) echo "9.9.9 (Claude Code)" ;;
"plugin install agit@agit-setup --scope "*) echo "\$4" >>"\$state" ;;
"plugin uninstall agit@agit-setup --scope "*) : >"\$state" ;;
"plugin list --json")
	if test -s "\$state"
	then
		echo '[{"id": "agit@agit-setup", "version": "0.1.0", "scope": "user", "enabled": true}]'
	else
		echo '[]'
	fi ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/claude"
# A git that passes for agit.
real_git=$(command -v git)
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
test "\$*" = "stamp -h" && { echo "usage: git stamp begin"; exit 129; }
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
PATH=$tmp/bin:$PATH

# Run agit-setup, with input on its stdin that claude must not see;
# check its exit status against $1 (0 or 1).
run () {
	want=$1
	shift
	if echo "not for claude" | sh "$setup" "$@" >"$tmp/out" 2>&1
	then
		got=0
	else
		got=1
	fi
	cat "$tmp/out"
	test "$got" = "$want" || fail "agit-setup $* exited with $got"
}

# Check that the fake claude was called, in the directory $1, with the
# arguments $2.
called () {
	grep -qxF "$1: $2" "$calls" || fail "claude not called in $1 with: $2"
}

echo "== --help"
run 0 --help
grep -q "usage: agit-setup" "$tmp/out" || fail "no usage"

echo "== add claude-code"
cd "$tmp/project"
run 0 add claude-code --yes
called "$tmp/project" "plugin marketplace add $root"
called "$tmp/project" "plugin install agit@agit-setup --scope user -y"
test "$(git config --file "$conf" hook.shell)" = true || fail "hook.shell"
test "$(git config --file "$conf" hook.reason)" = true || fail "hook.reason"
test "$(git config --file "$conf" hook.transcript)" = false || fail "hook.transcript"
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = user ||
fail "the user install was not recorded"
grep -q "done: Claude Code records" "$tmp/out" || fail "the self-check did not pass"
ok "add claude-code"

echo "== add claude-code again"
run 0 add claude-code --yes
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = user ||
fail "the user install was recorded twice"
ok "add is idempotent"

echo "== add claude-code with options, project scope"
: >"$calls"
run 0 add claude-code --scope project --no-shell --no-reason --transcripts -y
called "$tmp/project" "plugin install agit@agit-setup --scope project -y"
test "$(git config --file "$conf" hook.shell)" = false || fail "hook.shell"
test "$(git config --file "$conf" hook.reason)" = false || fail "hook.reason"
test "$(git config --file "$conf" hook.transcript)" = true || fail "hook.transcript"
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = "user
project:$tmp/project" || fail "installs: $(git config --file "$conf" --get-all agent.claude-code.install)"
ok "options and scope"

echo "== status"
mkdir -p "$AGIT_HOME/log"
echo "2026-01-01T00:00:00Z claude pre-edit: an error" >"$AGIT_HOME/log/hook.log"
run 0 status
for want in "Claude Code:  $tmp/bin/claude (9.9.9 (Claude Code))" \
	"agit@agit-setup 0.1.0, user scope, enabled" \
	"installed by agit-setup: project:$tmp/project" \
	"transcripts: yes" "an error" "agit-setup:   $root (plugin "
do
	grep -qF "$want" "$tmp/out" || fail "status does not show: $want"
done
ok "status"

echo "== remove claude-code"
: >"$calls"
cd "$tmp"
run 0 remove claude-code
called "$tmp" "plugin uninstall agit@agit-setup --scope user -y"
called "$tmp/project" "plugin uninstall agit@agit-setup --scope project -y"
called "$tmp" "plugin marketplace remove agit-setup"
git config --file "$conf" --get-all agent.claude-code.install &&
fail "installs are still recorded"
ok "remove claude-code"

echo "== remove without a record"
: >"$calls"
run 0 remove claude-code
called "$tmp" "plugin uninstall agit@agit-setup --scope user -y"
called "$tmp" "plugin marketplace remove agit-setup"
ok "remove without a record"

echo "== claude does not read the stdin of agit-setup"
# install.sh runs agit-setup with its stdin from /dev/tty.
if (: </dev/tty) 2>/dev/null
then
	cd "$tmp/project"
	for args in "add claude-code --yes" status "remove claude-code"
	do
		# shellcheck disable=SC2086
		sh "$setup" $args </dev/tty >"$tmp/out" 2>&1 ||
		{ cat "$tmp/out"; fail "agit-setup $args failed"; }
	done
	cd "$tmp"
else
	echo "no terminal; only checked with input on a pipe"
fi
if test -s "$stdin"
then
	cat "$stdin"
	fail "claude ran with the stdin of agit-setup"
fi
ok "claude runs with its stdin from /dev/null"

echo "== errors"
run 1 add
run 1 add codex --yes
grep -q "not supported yet" "$tmp/out" || fail "no message for codex"
run 1 add claude-code --scope everywhere --yes
run 1 frobnicate
mkdir -p "$tmp/no-claude"
for t in dirname grep mkdir sed tail cat jq
do
	ln -s "$(command -v "$t")" "$tmp/no-claude/$t"
done
ln -s "$tmp/bin/git" "$tmp/no-claude/git"
if PATH=$tmp/no-claude /bin/sh "$setup" add claude-code --yes >"$tmp/out" 2>&1
then
	fail "add succeeded without claude"
fi
cat "$tmp/out"
grep -q "claude is not on PATH" "$tmp/out" || fail "no message without claude"
rm "$tmp/no-claude/jq"
if PATH=$tmp/no-claude /bin/sh "$setup" add claude-code --yes >"$tmp/out" 2>&1
then
	fail "add succeeded without jq"
fi
cat "$tmp/out"
grep -q "the hooks need jq" "$tmp/out" || fail "no message without jq"
ok "errors"

if test $failures -gt 0
then
	echo "== $failures failures"
	exit 1
fi
echo "== all tests passed"
