# agit-setup

[agit](https://github.com/mronus/agit) is a distribution of Git with
the provenance extension, which records, for each commit, the AI
reasoning behind it and, for each changed line, whether an AI agent, a
human, or both wrote it. The executable is still `git`, and the
repositories it works on stay plain Git repositories.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mronus/agit-setup/main/install.sh | sh
```

The script downloads the prebuilt release for your platform from
[mronus/agit releases](https://github.com/mronus/agit/releases),
checks it against the release's `SHA256SUMS`, and makes it the default
`git` for your user. It needs no root, builds nothing, and leaves
Homebrew and the system's Git alone.

Supported platforms: macOS 12 or later (Apple silicon and Intel), and
Linux on x86_64 and aarch64 with glibc 2.31 or later, libcurl and zlib
(Debian 11, Ubuntu 20.04, RHEL 9, Fedora and newer). Alpine and other
musl-based systems are not supported.

What it changes:

```
~/.agit/versions/<version>/   the release (bin/, libexec/git-core/, share/)
~/.agit/current               symbolic link to versions/<version>
~/.agit/env                   puts ~/.agit/versions/<version>/bin first on PATH
```

and it adds one line, `. "$HOME/.agit/env" # added by agit install.sh`
(with your home directory spelled out), to the startup files of your
shells: `~/.zshrc` and `~/.zprofile` for zsh, `~/.bashrc` and
`~/.bash_profile` (or `~/.profile`) for bash, `~/.profile` otherwise.
For fish it writes `~/.config/fish/conf.d/agit.fish`. Open a new shell,
or run `. ~/.agit/env`, to start using it.

Options, after `sh -s --` when piping:

```
--version <version>   install that release (default: the latest)
--prefix <dir>        install there instead of ~/.agit
--no-modify-path      leave the shell startup files alone
--uninstall           remove ~/.agit and the lines added above
-q, --quiet           print only warnings and errors
```

For example:

```sh
curl -fsSL https://raw.githubusercontent.com/mronus/agit-setup/main/install.sh | sh -s -- --version 2.56.0.agit.2
```

Running it again installs the requested version next to the others
and points `current` at it; older versions are kept until you remove
them. `AGIT_VERSION` and `AGIT_HOME` can stand in for `--version` and
`--prefix`.

Editors: VS Code and Cursor take `PATH` from your login shell, so they
find agit after a restart. JetBrains IDEs need the path to Git set to
`~/.agit/current/bin/git`.

Integrations that connect coding agents to agit through their hooks
are coming to this repository.

## License

GPL version 2; see COPYING.
