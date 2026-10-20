#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 M. Abdullah Onus
#
# Test install.sh on this machine, for the user in $HOME:
#
#   test/install-test.sh <version> <version-without-tarballs>
#
# installs <version> into ~/.agit, checks that a new login shell of
# $SHELL runs it as git, installs it again, uninstalls it, and checks
# that installing <version-without-tarballs> fails with a clear
# message.  It changes the shell startup files in $HOME, so run it on
# a throwaway machine or with HOME pointing at an empty directory.

set -e

test $# = 2 || { echo >&2 "usage: $0 <version> <version-without-tarballs>"; exit 1; }
version=$1
bad_version=$2
script=$(cd "$(dirname "$0")/.." && pwd)/install.sh
prefix=$HOME/.agit
marker='# added by agit install.sh'
: "${SHELL:?SHELL must name the login shell to test}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail () {
	echo >&2 "FAIL: $*"
	exit 1
}

# Print, for each startup file, how many lines install.sh added.
marker_lines () {
	for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" \
		 "$HOME/.bash_profile" "$HOME/.profile"
	do
		test -f "$f" || continue
		echo "$f $(grep -cF "$marker" "$f" || :)"
	done
}

# Run the shell command $1 in a new login shell with the PATH a fresh
# session would start from.
login_shell () {
	PATH=/usr/bin:/bin "$SHELL" -lc "$1" </dev/null
}

echo "== install $version"
sh "$script" --version "$version"

marker_lines
first=$(marker_lines)
case "$first" in
*" 1"*) ;;
*) fail "no startup file sources $prefix/env" ;;
esac
case "$first" in
*" "[2-9]*) fail "a startup file has more than one agit line" ;;
esac

echo "== check a new $SHELL login shell"
git=$(login_shell 'command -v git')
echo "git: $git"
test "$git" = "$prefix/versions/$version/bin/git" ||
fail "git in a login shell is $git, not $prefix/versions/$version/bin/git"
out=$(login_shell 'git version')
echo "$out"
test "$out" = "git version $version" || fail "unexpected version: $out"
for path in exec-path man-path
do
	out=$(login_shell "git --$path")
	echo "--$path: $out"
	case "$out" in
	"$prefix/versions/$version"/*) ;;
	*) fail "--$path is outside $prefix/versions/$version" ;;
	esac
	# Through the symbolic link, for information only.
	echo "--$path through current: $("$prefix/current/bin/git" "--$path")"
done
login_shell 'git stamp -h' >"$tmp/stamp.out" 2>&1 || :
grep "usage: git stamp" "$tmp/stamp.out" || fail "git stamp -h does not work"
login_shell 'git ls-remote https://github.com/mronus/agit.git HEAD' ||
fail "git ls-remote over https does not work"

echo "== install again"
sh "$script" --version "$version"
test "$(marker_lines)" = "$first" || fail "the second install changed the startup files"
test "$(login_shell 'git version')" = "git version $version" ||
fail "the second install broke git"

echo "== uninstall"
sh "$script" --uninstall
test ! -e "$prefix" || fail "$prefix is still there"
marker_lines
case "$(marker_lines)" in
*" "[1-9]*) fail "agit lines are left in the startup files" ;;
esac

echo "== install $bad_version"
if sh "$script" --version "$bad_version" --prefix "$HOME/.agit-bad" \
	--no-modify-path 2>"$tmp/bad.err"
then
	fail "installing $bad_version succeeded"
fi
cat "$tmp/bad.err"
grep "release v$bad_version has no prebuilt tarball for" "$tmp/bad.err" ||
fail "no clear message for a release without tarballs"
test ! -e "$HOME/.agit-bad" || fail "the failed install left $HOME/.agit-bad"

echo "== all tests passed"
