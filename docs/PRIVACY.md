# AgentTerm privacy policy

*Last updated: 25 October 2026*

AgentTerm doesn't collect, store or share any information about you, and has no accounts,
analytics, advertising or crash reporting.

**What stays on your device.** The servers you add, your settings, this device's SSH private key
and any passwords you choose to save are kept on your device only (passwords and the key in the
iOS Keychain, marked so they never leave this device). Uninstalling AgentTerm removes them, apart
from Keychain items, which iOS may keep until you erase the device.

**Where AgentTerm connects.** Only to the servers you add, over SSH (and, if you turn it on,
mosh). What it sends there is what you type or ask for: commands, files you upload, and the
requests the editor makes to read files and run git and language servers on that server. The
setup guide's installers download software from the server itself, from your package manager,
npm, Microsoft (.NET) and Anthropic (Claude Code) when you choose to install them; those
downloads are between your server and them.

**Third parties.** AgentTerm has no third-party SDKs that collect data. If you use Claude Code
through AgentTerm, it runs on your server under your own Anthropic account and Anthropic's terms.

**Children.** AgentTerm isn't directed at children and collects no data from anyone.

**Changes.** Any change to this policy will be published here with a new date.

**Contact.** ian.munro@mudhoax.com, or open an issue at https://github.com/ianmunro90/AgentTerm.
