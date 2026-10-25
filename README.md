# AgentTerm

An SSH and mosh terminal for iPad and iPhone, with a read-only VS Code-like editor on the host and hooks into Claude Code.

- Terminal: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (xterm-256color, truecolor, hardware keyboard, esc/ctrl/arrow key bar)
- SSH: [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.0 on SwiftNIO SSH. 0.12.1 is deliberately skipped: it moves the SSH core to an individual contributor's fork.
- Login: this device's Ed25519 key first (generated on first launch and kept in the Keychain, `ThisDeviceOnly`; an existing OpenSSH Ed25519 key can be imported instead, passphrase-protected or not), then a password if the server takes one: saved in the Keychain from Edit Host, or asked for at login (*Log In* remembers it until the app quits, *Log In and Save* keeps it). After a password login the app offers to add its key to `~/.ssh/authorized_keys`, as `ssh-copy-id` does (also in Edit Host). Background connections (tmux sidebar, editor, uploads) never try a host that refuses the key without a password to give, so they don't run up OpenSSH's penalties or fail2ban. Not supported: RSA keys (Citadel signs with `ssh-rsa`/SHA-1, which current servers refuse), ECDSA keys, keyboard-interactive login (one-time codes; swift-nio-ssh doesn't implement it).
- Host keys: trust on first use. A changed key is refused unless you explicitly replace it.
- Sessions: Edit Host → *Keep Sessions in tmux* runs `tmux new -A -s main{window}` after login. Over SSH, iOS suspending the app kills the connection, so the app reconnects when it comes back (after 20 s away) and tmux restores the screen. Press Return on a dead session to reconnect; ⌘R also reconnects.
- Windows: every iPad window (Split View, Stage Manager, sidebar → *Open in New Window*) has its own sessions and a window number. `{window}` in the startup command expands to nothing in window 1 and `-2`, `-3`, … in later windows, so each window attaches to its own tmux session (`main`, `main-2`, …).
- Themes: nine built-in colour schemes (Settings → Default theme, or per host in Edit Host → Appearance).
- tmux: the sidebar lists each host's tmux sessions (tap to switch, long-press to kill, *New Session*); tap a pane to select it, drag borders, close panes from the toolbar's tmux menu. Copy is tmux's own (OSC 52, see below); paste with the toolbar button or ⌘V.
- Touch: pinch for text size, two-finger drag to scroll (tmux copy mode when it has the mouse), held backspace repeats. A snippets panel inserts common commands.
- Files: share sheet, drag and drop, or paste a screenshot to upload it to the host's upload folder (`~/uploads` unless set in Edit Host) and paste its path, so Claude Code attaches it as an image. Face ID can lock the app (Settings → Security).
- iPhone: one screen at a time (hosts → terminal or editor; Explorer → file, with back buttons), the editor's view toggles in a *More* menu, diffs inline by default, docs and Problems as sheets, 11 pt text by default (about 55 columns in portrait; landscape gives about 120).
- Narrow editors (under 480 pt: iPhone and iPad mini in portrait beside the side bar, Split View) show diffs inline, without the side-by-side toggle.
- Lock: Face ID / passcode is off until turned on (Settings → Security, or the setup guide).
- mosh: per-host toggle. The app logs in over SSH only to run `MOSH_SERVER_NETWORK_TMOUT=86400 mosh-server new -s -c 256 -l LANG=en_US.UTF-8`, then speaks mosh over UDP 60000–61000. It survives app suspension and network changes without reconnecting, and closing the session shuts the server down. Not implemented: mosh's predictive local echo.

## Editor

**Editor** in the terminal's toolbar (⇧⌘E) switches the window to a read-only, VS Code-like editor on the folder of the tmux pane it shows (its git repository, if it's in one). Everything happens over SSH on the host; nothing is copied to the device.

- **Explorer**: the file tree with git status colours and badges, VS Code-style file icons. Files open in tabs (italic preview tabs, as VS Code), syntax-highlighted in the window's terminal theme, without wrapping. Changed files show change marks beside the line numbers and on an overview ruler (tap or drag it to jump). Markdown renders (tables, task lists, images from the repo), with a toggle to its source. Pinch for text size.
- **Search** (⇧⌘F): ripgrep on the host (grep without it), case/word/regex and include/exclude globs; tap a result to open the file at the match. **Go to File** (⌘P), **Find in File** (⌘F).
- **Code navigation**: tap a name for its docs card (signature, doc comment, where it's declared), ⌘-tap or the edit menu for Go to Definition and Find All References. TypeScript/JavaScript, Python, C#, shell, YAML, JSON, CSS/SCSS/Less, HTML and Dockerfiles use real language servers on the host (below); other languages, and diffs, search the repository for declarations.
- **Problems**: open files are checked by their language server and problems are underlined as in VS Code (red errors, yellow warnings, blue information; unused code faded), with ticks on the overview ruler, counts on the tab and in the toolbar, and in the Explorer (a red squiggle under files with errors and the folders holding them; warnings aren't marked there: files opened since the folder was, which their servers keep checking after their tabs close and re-check when they change on the host, plus every file of a C# solution). Tap an underline for the message; the toolbar count lists them all (tap one to jump there). *Fix with Claude* pastes the problems at the terminal's prompt. They update as the file changes on the host.
- **Source Control**: staged and unstaged changes (side-by-side or inline diffs), stage/unstage/discard, commit (amend, undo, commit & push), fetch/pull/push/sync, branches (switch, create, publish), stash, and a commit graph: tap a commit for its files, a file for its diff. git runs on the host with no prompts, so its credentials must already work there.
- **Claude Code hooks**: *Ask Claude* (toolbar, menus, selections), *Fix with Claude* and the review actions paste a reference to the file, lines, problems, change or commit at Claude Code's prompt (no Return), then switch back to the terminal to type the question. Claude Code is made sure of first (in tmux): the active pane if it's running there; else a pane anywhere in the session that is (switched to); else started in the active pane if it's an idle shell, or in a new window "claude" if something else is running there, in the editor's folder. The paste waits for its prompt, and for you to answer its folder-trust question, which the app never answers. Paths are relative to Claude Code's folder.
- While the editor is showing it checks the host every 10 s (one hashed `git status`/`stat`) and refreshes when something changed, so it keeps up with what Claude Code is doing.

### Language servers

Problems, the docs card, definitions and references come from language servers on the host, one per language and folder, started when a file of that language opens (over its own SSH channel) and stopped with the session. **Check Server…** installs them; by hand, as the login user (no sudo):

```sh
npm install -g --prefix ~/.local typescript-language-server@5.3.0 typescript@6.0.3 pyright@1.1.414 \
  bash-language-server@5.8.1 yaml-language-server@1.19.2 vscode-langservers-extracted@4.10.0 \
  dockerfile-language-server-nodejs@0.15.0
sudo apt install shellcheck   # bash-language-server's problems come from ShellCheck

# C#: the .NET 10 SDK (Microsoft's apt repository), then csharp-ls as a global tool
curl -sSLO https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb && sudo apt update && sudo apt install dotnet-sdk-10.0
dotnet tool install --global csharp-ls --version 0.28.0   # ~/.dotnet/tools, on PATH via /etc/profile.d
```

| Files | Server | Notes |
|---|---|---|
| `.ts` `.tsx` `.js` `.jsx` `.mjs` `.cjs` | typescript-language-server | 6.x needs Node 22 (Debian 13 has 20); TypeScript 7 is the native port and has no `tsserver` |
| `.py` `.pyi` | pyright | |
| `.cs` `.csx` | csharp-ls (Roslyn) | loads the `.sln`/`.slnx` in the folder (or its `.csproj` files); started as soon as the editor opens a folder with one, to check the whole solution for the Explorer, and told which files changed after each refresh |
| `.sh` `.bash`, `.bashrc`, `.profile` | bash-language-server | man pages on hover; ShellCheck for problems |
| `.yml` `.yaml` | yaml-language-server | schemas from SchemaStore (Compose, GitHub/Gitea workflows…); 2.x needs Node 22 |
| `.json` `.jsonc` | vscode-json-language-server | schemas for well-known files (package.json, tsconfig, …) fetched from SchemaStore |
| `.css` `.scss` `.less`, `.html` | vscode-css/html-language-server | |
| `Dockerfile`, `Containerfile` | docker-langserver | |

A language whose server isn't installed falls back to the search-based lookup, with no problems shown (and the app doesn't retry the server for two minutes).

## mosh client

`AgentTerm/Mosh` is a from-scratch Swift port of the parts of mosh 1.4 a client needs, checked against mosh's source (`src/network`, `src/terminal`, `src/statesync`):

- `MoshCrypto.swift`: AES-128-OCB3 (RFC 7253) on CommonCrypto's AES block cipher, plus mosh's nonce and packet framing. Verified against Python `cryptography`'s `AESOCB3`.
- `MoshWire.swift`: the three protobuf messages, hand-encoded, and zlib framing.
- `MoshClient.swift`: the State Synchronization Protocol (sender timers, acks, throwaway, fragments, RTT/RTO, port hopping, shutdown), on Network.framework UDP.
- `MoshTerminal.swift`: a value-type framebuffer that interprets what mosh-server's `Display::new_frame` emits. The server diffs against whichever earlier state it believes the client has, so the client keeps several states and copies are cheap.
- `MoshCharWidth.swift`: glibc 2.41 `wcwidth` ranges generated on Debian 13, so cell widths match a typical Linux server exactly.
- `MoshRenderer.swift`: redraws changed rows into SwiftTerm using absolute positioning.

## Build

Requires Xcode 27 (iOS 17+ deployment target) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig`, then set your Apple team ID and a bundle-identifier prefix you own. The app becomes `<prefix>.agentterm`, its Share extension `<prefix>.agentterm.share`, and their App Group `group.<prefix>.agentterm`. Simulator builds work without it (`com.example`).
2. Generate the project and build:

```sh
xcodegen generate
xcodebuild -downloadComponent MetalToolchain   # once; SwiftTerm has Metal shaders
xcodebuild -project AgentTerm.xcodeproj -scheme AgentTerm -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -skipPackagePluginValidation -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <device UDID> build/Build/Products/Release-iphoneos/AgentTerm.app
```

`-skipPackagePluginValidation` approves SwiftTerm's `SwiftTermBuildInfoPlugin`, which only writes the package's git tag and commit into a generated Swift file. Debug builds take launch arguments that drive the app for simulator testing; they're listed in `AgentTerm/Views/Editor/EditorDebug.swift`, `AgentTerm/App/HostStore.swift` and `AgentTerm/App/AgentTermApp.swift`. After changing packages, run `scripts/update-acknowledgements.py` to refresh the licences shown in Settings → About.

## First connection

A first launch opens the setup guide (also **+** in the sidebar):

1. **Server**: address, username, port, and a name.
2. **Login**: a password (saved in the Keychain or not), or this device's key (its public key to copy into `~/.ssh/authorized_keys` first).
3. **Connecting**: a first connection, showing the host key's fingerprint to trust (and warning if it changed).
4. After a password login, **Add Key** puts this device's key in `~/.ssh/authorized_keys`, so later logins don't need the password.
5. **Tools**: what the server has of the tools AgentTerm uses (tmux, mosh, git, ripgrep, Node.js, ShellCheck, the language servers, C#, Claude Code), with the missing ones to tick and install, and whether to keep sessions in tmux.

**Check Server…** (a host's context menu) shows the same list later. Installing runs in a terminal sheet of its own, so every command shows and sudo can ask for your password: the system's package manager (apt-get, dnf, yum, pacman, zypper, apk, or Homebrew without sudo) for tmux, mosh, git, ripgrep, Node.js and ShellCheck; npm into `~/.local` for the language servers; Microsoft's `dotnet-install.sh` into `~/.dotnet` for C# (unless .NET is already installed); Anthropic's installer for Claude Code. The script is copied to a temporary file over a background connection and removed after it runs. Language servers are started with `~/.local/bin`, `~/.dotnet/tools` and `~/.dotnet` on the PATH, whatever the login shell's own.

### Servers

Linux and macOS. The setup guide's installs were tested on clean Debian 13, Fedora 42, Rocky Linux 9, Arch, Alpine 3.22 and openSUSE Tumbleweed (every tool, as a non-root sudo user):

- Packages install one at a time, so one that isn't available doesn't stop the rest.
- On RHEL-family systems EPEL is enabled (mosh, ripgrep, ShellCheck) and Node.js 20 is switched to (EL9's default 16 is too old for the language servers; Check Server flags Node older than 18).
- A downloaded .NET gets the system's ICU library.
- On Alpine, bash comes first (the .NET and Claude Code installers need it).

macOS needs Remote Login on (System Settings → General → Sharing) and Homebrew for the tools. Tested against macOS 27 (Homebrew tmux, mosh, ripgrep): login, Check Server, tmux sidebar and menu, the editor following the pane, search, Source Control, auto-refresh, mosh. What the app runs on servers avoids GNU-only commands: this window's tmux client is the one on its terminal's tty, found right after login by a command over the same SSH connection (the sshd-session's other child with a tty) or, with mosh, as mosh-server's shell's tty (macOS no longer shows other processes' environments to `ps -E`; Linux also falls back to the tag in `/proc/PID/environ`); a reconnecting window's old mosh-server is found from a pid file in `~/.cache/agentterm`; file stamps use GNU or BSD `stat`; git's network commands use `timeout` only where it exists; "changed since" is a stamp file for `find -newer`; grep falls back from `rg` with `--null`. Commands run over exec add `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin` to the PATH, since a non-login shell's PATH leaves Homebrew out.

### tmux settings

Pane selection, border dragging and two-finger scrolling need tmux's mouse mode, and copying needs tmux to send the selection as OSC 52 in the form mosh passes on (`52;c;…`; tmux's default leaves the selection parameter empty). In `~/.tmux.conf` on the host:

```tmux
set -g mouse on
set -as terminal-overrides ',xterm*:Ms=\E]52;c%p1%.0s;%p2%s\7'
```

## Licence

Copyright © 2026 Ian Munro.

AgentTerm is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

The mosh client in `AgentTerm/Mosh` is a port of parts of [mosh](https://mosh.org) (GPLv3 or later, © Keith Winstein and contributors). Packages it builds on, all GPL-compatible: SwiftTerm and Citadel (MIT), SwiftNIO, SwiftNIO SSH, swift-crypto and swift-markdown (Apache 2.0).
