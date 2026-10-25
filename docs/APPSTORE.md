# App Store listing

Drafts for App Store Connect. Character limits are Apple's; counts are for this text. Items in
⟨angle brackets⟩ are still to fill in.

## Identity

| Field | Value |
|---|---|
| Name (30) | AgentTerm |
| Subtitle (30) | SSH & mosh terminal, editor (27) |
| Bundle ID | com.mudhoax.agentterm (Share extension com.mudhoax.agentterm.share) |
| Primary category | Developer Tools |
| Secondary category | Utilities |
| Price | Free |
| Copyright | 2026 Ian Munro |
| Devices | iPad and iPhone (iOS 17 or later) |

No app called AgentTerm appeared in an App Store search on 2026-10-25; the name is only secured
when the App Store Connect record is created.

## Promotional text (170)

> Your servers, in your pocket: an SSH and mosh terminal with tmux at its heart, and a read-only code editor that hands files, selections and problems to Claude Code.

## Description (4000)

> AgentTerm is a terminal for the computers you work on: Linux servers, virtual machines and Macs, over SSH or mosh. It's built for keeping long-running work, such as coding agents like Claude Code, within reach from an iPad or iPhone.
>
> TERMINAL
> • SSH with a password or this device's own key (generated on the device; import your own Ed25519 key, passphrase-protected or not)
> • mosh: stays connected through network changes and sleep
> • tmux built in: your sessions, windows and panes in the sidebar; switch, split, zoom, rename and close from menus; each iPad window gets its own session
> • Copy and paste that works with tmux, a key bar with Esc, Ctrl, Tab, arrows and function keys, pinch for text size, nine colour themes
> • Drag, drop, paste or share files and screenshots to the server
> • Snippets for the commands you use most
>
> EDITOR
> • A read-only, VS Code-style editor that works on the server itself: file tree with git status, tabs, syntax highlighting, Markdown preview, search, Go to File
> • Source Control: diffs side by side or inline, stage, commit, push, pull, branches, stash and a commit graph
> • Language servers on your server for TypeScript, JavaScript, Python, C#, shell, YAML, JSON, CSS, HTML and Dockerfiles: problems underlined as you'd expect, docs on tap, go to definition, find references
>
> WORKS WITH CLAUDE CODE
> • Ask Claude about a file, a selection or a symbol, or have it fix the problems in a file or review a change: AgentTerm makes sure Claude Code is running in your tmux session and hands it the request, ready for your question
> • Claude Code is Anthropic's coding agent; it runs on your server and needs its own account. AgentTerm doesn't include an AI and works without it.
>
> SET UP IN A MINUTE
> • A setup guide connects to your first server, checks its key, and shows which tools it has (tmux, mosh, git, ripgrep, the language servers, Claude Code), installing the ones you want in a terminal you can watch
>
> PRIVATE BY DESIGN
> • No account, no tracking, no data collected: AgentTerm only connects to servers you add. Your key never leaves the device; passwords stay in its Keychain. Face ID lock optional.
>
> Free and open source (GPLv3).

## Keywords (100)

`ssh,mosh,terminal,tmux,shell,server,linux,editor,git,developer,claude,lsp,remote,console,vps` (92)

## URLs

- Support: https://github.com/ianmunro90/AgentTerm/blob/main/docs/SUPPORT.md (or a page built from it)
- Privacy policy: https://github.com/ianmunro90/AgentTerm/blob/main/docs/PRIVACY.md
- Marketing (optional): https://github.com/ianmunro90/AgentTerm

## Age rating

Answer *None* / *No* throughout: no violence, mature themes, gambling, user-generated content
shared with others, or in-app web browsing (Markdown previews show files from the user's own
server, with links opening in Safari). Expected rating: 4+.

## App Privacy

*Data Not Collected.* The app has no analytics, crash reporting or accounts, and talks only to
the servers the user adds.

## App Review information

Sign-in required: yes, to the demo server below (not an account with us: an SSH login). The
demo server's details and password go only in App Store Connect, never in this public repository.

- Server: ⟨demo host⟩, port ⟨22⟩
- Username: ⟨demo user⟩
- Password: ⟨demo password⟩
- Host key fingerprint: ⟨ED25519 SHA256:…⟩

Notes:

> AgentTerm is an SSH/mosh terminal for the user's own servers. To review it:
> 1. On first launch the setup guide opens. Tap Add a Server, enter the server and username above, choose Password, enter the password, and tap Connect.
> 2. Check that the fingerprint shown matches the one above and tap Trust. Choose Not Now when offered to add this device's key.
> 3. The Tools step lists what the demo server has installed. Tap Open Terminal.
> 4. In the terminal, try commands (ls, htop). The sidebar lists tmux sessions; the toolbar's tmux menu splits and zooms panes.
> 5. Type `cd weather-api` (a small demo project), then tap the </> button: the code editor opens on that folder. Open src/server.ts to see a problem underlined, tap a name such as `summarise` for its documentation, and open Source Control (the branch icon) to see the uncommitted change and the commit graph.
>
> Claude Code (mentioned in the app) is Anthropic's coding agent, a separate product that runs on the user's server with its own account; the demo server doesn't include it, and AgentTerm works fully without it. AgentTerm has no accounts, collects no data, and uses standard encryption (SSH, mosh) only to talk to the user's servers.

## Screenshots

In `docs/screenshots/`, at the required sizes: iPad 13" (2064 × 2752) and iPhone 6.9"
(1320 × 2868). Taken in the simulator against a demo project with a neutral host name
(`scripts/screenshots/`). Suggested order and captions:

| # | iPad | iPhone | Caption |
|---|---|---|---|
| 1 | `ipad-1-terminal` | `iphone-1-terminal` | Your servers, with tmux built in |
| 2 | `ipad-2-editor` | `iphone-2-editor` | Problems and docs from real language servers |
| 3 | `ipad-3-changes` | `iphone-3-changes` | Review, stage and commit |
| 4 | `ipad-4-markdown` | `iphone-4-markdown` | Read Markdown as it's meant to look |
| 5 | `ipad-5-tools` | `iphone-5-tools` | Set up a server in a minute |
| 6 | | `iphone-6-sessions` | Every tmux session, a tap away |
