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
Homebrew and the system's Git alone. It also installs this repository,
whose `agit-setup` connects your coding agents to agit (see below),
and, on a terminal, offers to run it.

Requirements: `tar`, `gzip`, and `curl` or `wget`; `jq` for the
agent integration.

Supported platforms: macOS 12 or later (Apple silicon and Intel), and
Linux on x86_64 and aarch64 with glibc 2.31 or later, libcurl and zlib
(Debian 11, Ubuntu 20.04, RHEL 9, Fedora and newer). Alpine and other
musl-based systems are not supported.

What it changes:

```
~/.agit/versions/<version>/   the release (bin/, libexec/git-core/, share/)
~/.agit/current               symbolic link to versions/<version>
~/.agit/setup/                this repository (agit-setup, the agent hooks)
~/.agit/env                   puts ~/.agit/versions/<version>/bin first on PATH,
                              and ~/.agit/setup/bin after it
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
--no-agents           do not offer to connect coding agents
--uninstall           disconnect the agents, remove ~/.agit and the
                      lines added above
-y, --yes             do not prompt; agents are not connected
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

## Connect your agents

agit tells the lines an AI agent wrote from those a human wrote by
having the agent's hooks call `git stamp` around each edit; lines
changed outside them are recorded as human. `agit-setup` installs
those hooks:

```sh
agit-setup                          # choose agents and options on the terminal
agit-setup add claude-code          # or without questions
agit-setup status                   # what is installed, and the last hook errors
agit-setup remove claude-code
```

Claude Code is supported today; Codex, Cursor and Gemini CLI are
coming. For Claude Code, `agit-setup` installs the `agit` plugin of
this repository with `claude plugin install`, for all your projects
(`--scope user`, the default) or for the one in the current directory
(`--scope project` for everyone working on it, `--scope local` for you
only). The plugin's hooks run `bin/agit-hook`, which:

```
before and after each file edit    git stamp begin / end -- <file>
before and after each shell        git stamp begin / end on the whole tree,
command                            so files written by commands count as
                                   the agent's
before a git commit                if the agent recorded no reason, record
                                   a summary of its last turn as the
                                   commit's reasoning
at the start of a session          tell the agent to record why it made
                                   its changes, with git stamp reason
```

Options, asked by `agit-setup` and kept in `~/.agit/setup.conf`:

```
--no-shell        do not stamp around shell commands (default: stamp)
--no-reason       do not record a summary before commits (default: record)
```

The hooks never block the agent: they do nothing outside a Git
worktree, where `provenance.enabled` is false, or when they find no
agit, and they log their errors to `~/.agit/log/hook.log`. They run
the agit installed in `~/.agit` even when the agent was started from a
shell that does not have it on `PATH`, and they put it first on the
`PATH` of the agent's shell commands, so that its commits are made by
agit.

Without the installer, with agit and `jq` already on your `PATH`, add
the plugin from Claude Code itself:

```
/plugin marketplace add mronus/agit-setup
/plugin install agit@agit-setup
```

or from the shell with `claude plugin marketplace add mronus/agit-setup`
and `claude plugin install agit@agit-setup`. The options then keep
their defaults.

## License

GPL version 2; see COPYING.
