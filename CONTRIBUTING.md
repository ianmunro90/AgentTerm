# Contributing

Thanks for helping with AgentTerm. It's GPLv3 (or later); contributions are accepted under the same licence.

- **Building**: see *Build* in the README. Put your own team and bundle prefix in `Config/Local.xcconfig` (ignored by git); never commit signing identities.
- **The project file** is generated: edit `project.yml`, then run `xcodegen generate`, and commit both.
- **Code style**: match the surrounding code. Comments say why, not what; UI text is plain, sentence-case English.
- **Servers**: everything the app runs on a host must work on Linux (GNU and BusyBox) and macOS (BSD tools, Homebrew). Prefer POSIX `sh`; when a GNU-only option is unavoidable, fall back (see `TmuxService`, `ExplorerModel.hasChanged`). Test against more than one, e.g. throwaway containers.
- **Testing in the simulator**: Debug builds accept launch arguments (`-testHost user@host:port`, `-openEditor`, `-openFile`, `-checkServer`, …) so flows can be driven and screenshotted without taps.
- **Dependencies**: keep packages pinned; after changing them, run `scripts/update-acknowledgements.py`.
- **Privacy**: AgentTerm collects nothing. New uses of Apple's required-reason APIs need an entry in `AgentTerm/PrivacyInfo.xcprivacy` (and the Share extension's).
