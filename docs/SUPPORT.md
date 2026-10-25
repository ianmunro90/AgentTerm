# AgentTerm support

**Help and bug reports:** open an issue at https://github.com/ianmunro90/AgentTerm/issues, or email ian.munro@mudhoax.com.
Include the app version (Settings → About), your device, and the server's operating system.

## Common questions

**It says the key wasn't accepted.** Add this device's public key (the key button at the bottom
of the sidebar → Copy Public Key) to `~/.ssh/authorized_keys` for your user on the server, or log
in once with a password and choose *Add Key*.

**"Couldn't connect" / no answer.** Check the address and port, and that the device can reach the
server: the same network, a VPN such as Tailscale, or a port opened in the firewall.

**The host key changed.** If you reinstalled the server, that's expected: check the new
fingerprint (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server) and trust it.
Otherwise, don't: someone may be intercepting the connection.

**Sessions disappear when I switch apps.** iOS stops apps in the background, which ends SSH
connections. Turn on *Keep Sessions in tmux* (Edit Host) so your work keeps running and reappears
when you return, or use mosh.

**Copying from tmux doesn't work.** Add to `~/.tmux.conf` on the server:

```tmux
set -g mouse on
set -as terminal-overrides ',xterm*:Ms=\E]52;c%p1%.0s;%p2%s\7'
```

**The editor shows no problems or docs.** Check Server (long-press the server in the sidebar)
shows which language servers are installed, and installs the missing ones.

**Which servers work?** Linux (Debian, Ubuntu, Fedora, RHEL/Rocky/Alma, Arch, Alpine, openSUSE)
and macOS with Remote Login on.
