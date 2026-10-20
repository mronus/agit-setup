#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Install agit, a distribution of Git with the provenance extension,
# from the prebuilt tarballs of a release on github.com/mronus/agit,
# and agit-setup, which connects coding agents to it, from
# github.com/mronus/agit-setup.
#
#   curl -fsSL https://raw.githubusercontent.com/mronus/agit-setup/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version 2.56.0.agit.2
#
# Without root and without touching Homebrew or system files, the
# release is unpacked into $prefix/versions/<version>, $prefix/current
# is pointed at it, and $prefix/env, which puts its bin directory
# first on PATH, is sourced from the shell startup files.  This
# repository is unpacked into $prefix/setup, whose bin directory env
# also puts on PATH, and, on a terminal, agit-setup is offered to
# connect the coding agents.  Run with --help for the options.
#
# The body is a function called on the last line, so that a download
# cut short never runs part of the script.

REPO=https://github.com/mronus/agit
SETUP_TARBALL=https://codeload.github.com/mronus/agit-setup/tar.gz
MARKER='# added by agit install.sh'

usage () {
	cat <<EOF
usage: install.sh [<options>]

Install agit, Git with the provenance extension, and make it the
default git for your user.

    --version <version>  release to install, e.g. 2.56.0.agit.2
                         (default: \$AGIT_VERSION, else the latest)
    --prefix <dir>       where to install (default: \$AGIT_HOME,
                         else ~/.agit)
    --no-modify-path     do not change the shell startup files
    --no-agents          do not offer to connect coding agents
    --uninstall          disconnect the coding agents, and remove the
                         prefix and the lines this script added to the
                         shell startup files
    -y, --yes            do not prompt; coding agents are not connected
    -q, --quiet          print only warnings and errors
    -h, --help           show this help

Supported platforms: darwin-arm64, darwin-x86_64 (macOS 12 or later),
linux-x86_64, linux-aarch64 (glibc 2.31 or later, with libcurl and
zlib).

agit-setup is taken from the branch or tag \$AGIT_SETUP_REF of
github.com/mronus/agit-setup (default: main).
EOF
}

say () {
	test -n "$quiet" || printf '%s\n' "$*"
}

warn () {
	printf '%s\n' "warning: $*" >&2
}

die () {
	printf '%s\n' "error: $*" >&2
	exit 1
}

need () {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found"
}

# Print "<os>-<arch>" in the form the release assets use.
detect_platform () {
	os=$(uname -s)
	arch=$(uname -m)
	case "$os,$arch" in
	Darwin,arm64)
		echo darwin-arm64 ;;
	Darwin,x86_64)
		# An x86_64 shell under Rosetta on Apple silicon.
		if test "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1
		then
			echo darwin-arm64
		else
			echo darwin-x86_64
		fi ;;
	Linux,x86_64|Linux,amd64)
		echo linux-x86_64 ;;
	Linux,aarch64|Linux,arm64)
		echo linux-aarch64 ;;
	*)
		die "no prebuilt agit for $os $arch; supported platforms:" \
			"darwin-arm64, darwin-x86_64, linux-x86_64, linux-aarch64" ;;
	esac
}

# Succeed if version $1 (major.minor) is at least $2.$3.
version_at_least () {
	major=${1%%.*}
	minor=${1#*.}
	minor=${minor%%.*}
	case "$major$minor" in
	''|*[!0-9]*) return 1 ;;
	esac
	test "$major" -gt "$2" || { test "$major" -eq "$2" && test "$minor" -ge "$3"; }
}

check_system () {
	case "$1" in
	darwin-*)
		v=$(sw_vers -productVersion 2>/dev/null) || v=
		version_at_least "$v" 12 0 ||
		die "agit needs macOS 12 or later (this is ${v:-unknown})"
		;;
	linux-*)
		libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || libc=
		libc=${libc#glibc }
		if test -z "$libc"
		then
			out=$(ldd --version 2>&1 | head -1)
			case "$out" in
			*musl*)
				die "agit needs glibc; musl-based systems such as" \
					"Alpine are not supported" ;;
			esac
			libc=${out##* }
		fi
		version_at_least "$libc" 2 31 ||
		die "agit needs glibc 2.31 or later (found ${libc:-none})"

		ldconfig=$(command -v ldconfig 2>/dev/null) || ldconfig=/sbin/ldconfig
		if test -x "$ldconfig" &&
		   ! "$ldconfig" -p 2>/dev/null | grep -q 'libcurl\.so\.4 '
		then
			warn "libcurl.so.4 not found; git needs it for https" \
				"(install libcurl4 or libcurl)"
		fi
		;;
	esac
}

# Download $1 into the file $2; print the HTTP status on failure.
download () {
	if command -v curl >/dev/null 2>&1
	then
		if test -n "$quiet" || ! test -t 2
		then
			progress=-sS
		else
			progress=-#
		fi
		code=$(curl -fSL "$progress" --proto '=https' --tlsv1.2 \
			-o "$2" -w '%{http_code}' "$1") && return 0
		test "$code" = 404 && return 4
		return 1
	else
		wget -q -O "$2" "$1" && return 0
		# wget exits with 8 when the server answered with an error.
		test $? = 8 && return 4
		return 1
	fi
}

# Print the tag of the latest release, found by following the
# redirect of /releases/latest, which is not rate limited like the
# GitHub API.
latest_tag () {
	if command -v curl >/dev/null 2>&1
	then
		url=$(curl -fsSLI --proto '=https' -o /dev/null \
			-w '%{url_effective}' "$REPO/releases/latest") || return 1
	else
		url=$(wget -q -S --spider "$REPO/releases/latest" 2>&1 |
			sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r')
	fi
	case "$url" in
	*/releases/tag/v*) echo "${url##*/}" ;;
	*) return 1 ;;
	esac
}

sha256 () {
	if command -v sha256sum >/dev/null 2>&1
	then
		sha256sum "$1"
	elif command -v shasum >/dev/null 2>&1
	then
		shasum -a 256 "$1"
	else
		return 1
	fi | cut -d ' ' -f 1
}

# Point $prefix/current at versions/$1, replacing the link atomically
# where mv can do it (GNU mv -T, BSD mv -h).
point_current () {
	ln -s "versions/$1" "$prefix/.current.$$" || exit 1
	mv -T -f "$prefix/.current.$$" "$prefix/current" 2>/dev/null ||
	mv -h -f "$prefix/.current.$$" "$prefix/current" 2>/dev/null ||
	{
		rm -f "$prefix/.current.$$"
		ln -s -f -n "versions/$1" "$prefix/current"
	} || die "cannot point $prefix/current at versions/$1"
}

write_env () {
	if ! cat >"$prefix/env.$$" <<EOF
# agit
case ":\$PATH:" in
	*:"$prefix/setup/bin":*) ;;
	*) export PATH="$prefix/setup/bin:\$PATH" ;;
esac
case "\$PATH" in
	"$bindir":*) ;;
	*) export PATH="$bindir:\$PATH" ;;
esac
EOF
	then
		die "cannot write $prefix/env"
	fi
	mv -f "$prefix/env.$$" "$prefix/env" ||
	die "cannot write $prefix/env"
}

# Print the startup files that may source $prefix/env.
rc_files () {
	zdot=${ZDOTDIR:-$HOME}
	echo "$zdot/.zshrc"
	echo "$zdot/.zprofile"
	echo "$HOME/.bashrc"
	echo "$HOME/.bash_profile"
	echo "$HOME/.profile"
}

fish_file () {
	echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/agit.fish"
}

# Append the line that sources $prefix/env to the file $1, unless it
# is already there.
add_rc_line () {
	if test -f "$1" && grep -qxF "$rc_line" "$1"
	then
		return 0
	fi
	# Start on a new line if the file does not end with one.
	if test -n "$(tail -c 1 "$1" 2>/dev/null)"
	then
		nl='
'
	else
		nl=
	fi
	printf '%s%s\n' "$nl" "$rc_line" >>"$1" ||
	{ warn "could not update $1"; return 0; }
	say "updated $1"
}

modify_path () {
	login_shell=${SHELL##*/}
	zdot=${ZDOTDIR:-$HOME}

	# For each shell that is installed, update the startup files that
	# exist, and create them for the login shell.
	files=
	if command -v zsh >/dev/null 2>&1
	then
		for f in "$zdot/.zshrc" "$zdot/.zprofile"
		do
			if test -f "$f" || test "$login_shell" = zsh
			then
				files="$files$f
"
			fi
		done
	fi
	if command -v bash >/dev/null 2>&1
	then
		if test -f "$HOME/.bash_profile"
		then
			profile=$HOME/.bash_profile
		else
			profile=$HOME/.profile
		fi
		for f in "$HOME/.bashrc" "$profile"
		do
			if test -f "$f" || test "$login_shell" = bash
			then
				files="$files$f
"
			fi
		done
	fi
	if test -z "$files" || test -f "$HOME/.profile"
	then
		files="$files$HOME/.profile
"
	fi

	rc_line=". \"$prefix/env\" $MARKER"
	old_ifs=$IFS
	IFS='
'
	for f in $(printf '%s' "$files" | awk '!seen[$0]++')
	do
		IFS=$old_ifs
		add_rc_line "$f"
	done
	IFS=$old_ifs

	if command -v fish >/dev/null 2>&1
	then
		f=$(fish_file)
		content="$MARKER
fish_add_path -g -m \"$prefix/setup/bin\"
fish_add_path -g -m \"$bindir\""
		if ! test -f "$f" || test "$(cat "$f")" != "$content"
		then
			if mkdir -p "${f%/*}" && printf '%s\n' "$content" >"$f"
			then
				say "updated $f"
			else
				warn "could not write $f"
			fi
		fi
	fi
}

# Install this repository, at $AGIT_SETUP_REF, into $prefix/setup.
# agit works without it, so a failure is only a warning.
install_setup () {
	ref=${AGIT_SETUP_REF:-main}
	stmp=$(mktemp -d "$prefix/.setup.XXXXXX") || {
		warn "cannot create a temporary directory in $prefix"
		return 1
	}
	say "downloading agit-setup ($ref)"
	if ! download "$SETUP_TARBALL/$ref" "$stmp/setup.tar.gz"
	then
		warn "cannot download agit-setup from $SETUP_TARBALL/$ref"
		rm -rf "$stmp"
		return 1
	fi
	if ! { mkdir "$stmp/new" &&
	       tar -xzf "$stmp/setup.tar.gz" -C "$stmp/new" --strip-components 1 &&
	       test -f "$stmp/new/bin/agit-setup"; }
	then
		warn "cannot unpack agit-setup"
		rm -rf "$stmp"
		return 1
	fi
	# Swap the directories, so that the old one stays whole until the
	# new one is in place.
	if test -d "$prefix/setup"
	then
		mv "$prefix/setup" "$stmp/old" || {
			warn "cannot replace $prefix/setup"
			rm -rf "$stmp"
			return 1
		}
	fi
	if ! mv "$stmp/new" "$prefix/setup"
	then
		test -d "$stmp/old" && mv "$stmp/old" "$prefix/setup"
		warn "cannot move agit-setup into $prefix/setup"
		rm -rf "$stmp"
		return 1
	fi
	rm -rf "$stmp"
	say "installed agit-setup in $prefix/setup"
}

# Offer to run agit-setup, on the terminal.
connect_agents () {
	setup=$prefix/setup/bin/agit-setup
	test -f "$setup" || return 0
	if test -z "$yes" && test -z "$no_agents" && (: </dev/tty) 2>/dev/null
	then
		printf 'Connect your coding agents now? [Y/n] '
		read -r answer </dev/tty || answer=n
		case "$answer" in
		[Nn]*) ;;
		*)
			PATH="$bindir:$prefix/setup/bin:$PATH" AGIT_HOME=$prefix \
				sh "$setup" </dev/tty ||
			warn "agit-setup failed; run it again with: agit-setup"
			return 0 ;;
		esac
	fi
	say ""
	say "to connect your coding agents (Claude Code) to agit, run"
	say "    agit-setup"
	say "in a new shell"
}

install_agit () {
	need uname
	need tar
	need gzip
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1
	then
		die "curl or wget is required but neither was found"
	fi

	platform=$(detect_platform) || exit 1
	check_system "$platform"

	if test -z "$version"
	then
		tag=$(latest_tag) ||
		die "cannot find the latest release at $REPO/releases/latest"
		version=${tag#v}
	fi
	tag=v$version
	name=agit-$version-$platform
	dest=$prefix/versions/$version

	mkdir -p "$prefix/versions" || die "cannot create $prefix/versions"

	if test "$("$dest/bin/git" version 2>/dev/null)" = "git version $version"
	then
		say "agit $version is already installed in $dest"
	else
		tmp=$(mktemp -d "$prefix/versions/.install.XXXXXX") ||
		die "cannot create a temporary directory in $prefix/versions"
		# On failure, also remove the directories made for a first
		# install, if they are still empty.
		trap 'rm -rf "$tmp"; rmdir "$prefix/versions" "$prefix" 2>/dev/null' EXIT
		trap 'exit 1' HUP INT TERM

		say "downloading agit $version for $platform"
		download "$REPO/releases/download/$tag/$name.tar.gz" "$tmp/$name.tar.gz"
		case $? in
		0) ;;
		4) die "release $tag has no prebuilt tarball for $platform" ;;
		*) die "cannot download $REPO/releases/download/$tag/$name.tar.gz" ;;
		esac
		download "$REPO/releases/download/$tag/SHA256SUMS" "$tmp/SHA256SUMS" ||
		die "cannot download the checksums of release $tag"

		expected=$(awk -v f="$name.tar.gz" '$2 == f || $2 == "*" f { print $1 }' \
			"$tmp/SHA256SUMS")
		test -n "$expected" || die "SHA256SUMS of $tag has no entry for $name.tar.gz"
		if ! actual=$(sha256 "$tmp/$name.tar.gz") || test -z "$actual"
		then
			die "sha256sum or shasum is required to verify the download"
		fi
		test "$actual" = "$expected" ||
		die "checksum mismatch for $name.tar.gz (expected $expected, got $actual)"
		say "verified sha256 $actual"

		tar -xzf "$tmp/$name.tar.gz" -C "$tmp" ||
		die "cannot unpack $name.tar.gz"
		# macOS may kill a binary run the moment it is unpacked, so
		# give it a few tries.
		tries=0
		until test "$("$tmp/$name/bin/git" version 2>/dev/null)" = "git version $version"
		do
			tries=$((tries + 1))
			test $tries -lt 5 ||
			die "the unpacked git does not run on this system"
			sleep 1
		done

		if ! { rm -rf "$dest" && mv "$tmp/$name" "$dest"; }
		then
			die "cannot move the release into $dest"
		fi
		say "installed agit $version in $dest"
	fi

	point_current "$version"
	test "$("$prefix/current/bin/git" version 2>/dev/null)" = "git version $version" ||
	die "$prefix/current/bin/git does not report version $version"

	# PATH names the version directory itself rather than current/bin:
	# on macOS, git finds libexec/git-core relative to the path it was
	# started by, without resolving symbolic links, so a git started
	# through current/bin could mix two versions while current is
	# switched.
	bindir=$prefix/versions/$version/bin
	install_setup
	write_env

	if test -z "$no_modify_path"
	then
		modify_path
	fi

	say ""
	say "agit $version is installed: $bindir/git"
	others=
	for d in "$prefix/versions"/*
	do
		test -d "$d" && test "${d##*/}" != "$version" && others=1
	done
	if test -n "$others"
	then
		say "older versions are kept in $prefix/versions; remove one with"
		say "    rm -rf \"$prefix/versions/<version>\""
	fi

	now=$(command -v git 2>/dev/null) || now=
	say "git on PATH in this shell: ${now:-none}"
	if test "$now" != "$bindir/git"
	then
		say "to use agit in this shell, run:"
		say "    . \"$prefix/env\""
	fi

	if test -n "$no_modify_path"
	then
		say ""
		say "your shell startup files were not changed; to use agit, add"
		say "    . \"$prefix/env\""
		say "to them"
	else
		# What a new login shell finds, for the shells whose startup
		# files we know.
		case "${SHELL##*/}" in
		zsh|bash)
			next=$(PATH=/usr/bin:/bin "$SHELL" -lc 'command -v git' \
				</dev/null 2>/dev/null) || next=
			say "git on PATH in a new ${SHELL##*/} login shell: ${next:-none}"
			if test -n "$next" && test "$next" != "$bindir/git"
			then
				warn "a new ${SHELL##*/} login shell still finds $next" \
					"first; check for PATH changes after the agit line" \
					"in your startup files"
			fi ;;
		esac
	fi

	say ""
	say "editors: VS Code and Cursor take PATH from your login shell;"
	say "restart them to pick up agit. In JetBrains IDEs set the path to"
	say "Git to $prefix/current/bin/git"

	connect_agents
}

# Run agit-setup remove for each agent that agit-setup connected.
disconnect_agents () {
	setup=$prefix/setup/bin/agit-setup
	conf=$prefix/setup.conf
	test -f "$setup" && test -f "$conf" || return 0
	git=$prefix/current/bin/git
	test -x "$git" || git=git
	agents=$("$git" config --file "$conf" --name-only --get-regexp \
		'^agent\..*\.install$' 2>/dev/null |
		sed -e 's/^agent\.//' -e 's/\.install$//' | sort -u)
	for agent in $agents
	do
		AGIT_HOME=$prefix AGIT_GIT=$git sh "$setup" remove "$agent" ||
		warn "could not disconnect $agent; see agit-setup --help"
	done
}

uninstall_agit () {
	disconnect_agents
	if ! test -d "$prefix"
	then
		say "nothing to remove at $prefix"
	elif test -f "$prefix/env" || test -d "$prefix/versions" || test -L "$prefix/current"
	then
		rm -rf "$prefix" || die "cannot remove $prefix"
		say "removed $prefix"
	else
		die "$prefix does not look like an agit installation; not removing it"
	fi

	rc_line=". \"$prefix/env\" $MARKER"
	old_ifs=$IFS
	IFS='
'
	for f in $(rc_files)
	do
		IFS=$old_ifs
		if ! test -f "$f" || ! grep -qxF "$rc_line" "$f"
		then
			continue
		fi
		grep -vxF "$rc_line" "$f" >"$f.agit.$$"
		# Write in place, keeping the file's mode, owner and links.
		if ! cat "$f.agit.$$" >"$f"
		then
			die "cannot update $f (its old content is in $f.agit.$$)"
		fi
		rm -f "$f.agit.$$"
		say "removed the agit line from $f"
	done
	IFS=$old_ifs

	f=$(fish_file)
	if test -f "$f" && grep -qxF "$MARKER" "$f"
	then
		rm -f "$f" && say "removed $f"
	fi
}

main () {
	version=${AGIT_VERSION-}
	prefix=${AGIT_HOME:-${HOME:?HOME is not set}/.agit}
	no_modify_path=
	no_agents=
	yes=
	uninstall=
	quiet=

	while test $# -gt 0
	do
		case "$1" in
		--version)
			test $# -gt 1 || die "--version needs a value"
			version=$2; shift ;;
		--version=*)
			version=${1#*=} ;;
		--prefix)
			test $# -gt 1 || die "--prefix needs a value"
			prefix=$2; shift ;;
		--prefix=*)
			prefix=${1#*=} ;;
		--no-modify-path)
			no_modify_path=1 ;;
		--uninstall)
			uninstall=1 ;;
		--no-agents)
			no_agents=1 ;;
		-y|--yes)
			yes=1 ;;
		-q|--quiet)
			quiet=1 ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			printf '%s\n' "error: unknown option: $1" >&2
			usage >&2; exit 1 ;;
		esac
		shift
	done

	version=${version#v}
	case "$version" in
	*[!0-9A-Za-z.-]*|-*|.*)
		die "not a release version: $version" ;;
	esac

	case "$prefix" in
	'') die "the prefix is empty" ;;
	/*) ;;
	*) prefix=$(pwd)/$prefix ;;
	esac
	prefix=${prefix%/}
	case "$prefix" in
	''|*[\"\\\$\`]*|*'
'*)
		die "the prefix must be a non-root path without quotes, backslashes," \
			"dollar signs, backquotes or newlines" ;;
	esac

	if test -n "$uninstall"
	then
		uninstall_agit
	else
		install_agit
	fi
}

main "$@"
