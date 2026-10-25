import Citadel
import Foundation
import NIOCore

struct TmuxSession: Identifiable, Hashable {
    let name: String
    let windows: Int
    let attachedClients: Int
    let lastActivity: Date
    /// This window's own tmux client is attached to this session.
    var isThisWindow: Bool
    /// Its windows, in order.
    var windowList: [TmuxWindow] = []

    var id: String { name }
}

/// A window in a tmux session.
struct TmuxWindow: Identifiable, Hashable {
    let index: Int
    let name: String
    /// The session's current window.
    let isActive: Bool
    let panes: Int

    var id: Int { index }

    /// "list-windows -F '#{window_index}\t#{window_active}\t#{window_panes}\t#{window_name}'", one line.
    init?(_ line: Substring) {
        let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let index = Int(fields[0]), let panes = Int(fields[2]) else { return nil }
        self.index = index
        isActive = fields[1] == "1"
        self.panes = panes
        name = String(fields[3])
    }
}

/// Lists, switches and kills tmux sessions on a host over short-lived SSH exec connections.
/// "This window" is found by the tag every AgentTerm shell carries (mosh: AGENTTERM_TAG in
/// mosh-server's environment; SSH: LC_AGENTTERM_TAG, which sshd's default AcceptEnv LC_* allows),
/// inherited by the tmux client process.
enum TmuxService {
    /// Each window's terminal tty on the host ("/dev/pts/2", "/dev/ttys001"), by tag, once its
    /// session has found it (TerminalSession.findTTY): its tmux client is the one on that tty.
    nonisolated(unsafe) private static var ttys: [String: String] = [:]
    private static let ttyLock = NSLock()

    static func setTTY(_ tty: String?, for tag: String) {
        ttyLock.lock()
        defer { ttyLock.unlock() }
        ttys[tag] = tty
    }

    private static func tty(for tag: String) -> String? {
        ttyLock.lock()
        defer { ttyLock.unlock() }
        return ttys[tag]
    }

    /// `ours PID TTY`: whether a tmux client (its pid and tty) is this window's: on its tty,
    /// else (Linux) carrying its tag in its environment.
    private static let ours = ##"ours() { if [ -n "${CLIENT_TTY:-}" ]; then [ "$2" = "$CLIENT_TTY" ]; else envmatch "$1" "(LC_)?AGENTTERM_TAG=$AGENTTERM_MATCH"; fi; }; "##

    /// The tty of the process with a terminal whose parent is the SSH connection's
    /// sshd-session, found from a command run over that same connection (its own parent chain
    /// leads there): the terminal's shell.
    static let siblingTTY = ##"""
        p=$$
        while [ -n "$p" ] && [ "$p" -gt 1 ]; do
            case "$(ps -o command= -p "$p" 2>/dev/null)" in sshd*) break ;; esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        done
        ps -A -o ppid=,tty= 2>/dev/null | awk -v p="$p" '$1 == p && $2 != "?" && $2 != "??" { print "/dev/" $2; exit }'
        """##

    /// The tty of a child of process `$PARENT` that has a terminal (mosh-server's shell).
    static let childTTY = ##"ps -A -o ppid=,tty= 2>/dev/null | awk -v p="$PARENT" '$1 == p && $2 != "?" && $2 != "??" { print "/dev/" $2; exit }'"##

    /// `envmatch PID PATTERN`: whether that process's environment has a line matching PATTERN
    /// (an extended regex, whole line): /proc on Linux, `ps -E` on macOS and the BSDs.
    static let envMatch = ##"envmatch() { if [ -r "/proc/$1/environ" ]; then tr '\0' '\n' < "/proc/$1/environ"; "##
        + ##"else ps -wwE -p "$1" -o command= 2>/dev/null | tr ' ' '\n'; fi | grep -Eqx "$2"; }; "##

    static func list(on host: HostProfile, tag: String) async throws -> [TmuxSession] {
        // No tmux at all: no session list (rather than an empty one offering New Session).
        let script = ##"command -v tmux >/dev/null 2>&1 || { echo AGENTTERM-NO-TMUX; exit 0; }; "## + envMatch + ours + ##"tmux ls -F "#{session_windows} #{session_attached} #{session_activity} #{session_name}" 2>/dev/null; "##
            + "echo --; "
            + ##"for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}:#{session_name}" 2>/dev/null); do "##
            + ##"t=${c#*:}; ours "${c%%:*}" "${t%%:*}" && echo "${t#*:}"; done; "##
            + "echo --; "
            + ##"tmux list-windows -a -F "#{session_name}\##t#{window_index}\##t#{window_active}\##t#{window_panes}\##t#{window_name}" 2>/dev/null; true"##
        let output = try await run(script, on: host, variables: ["AGENTTERM_MATCH": tag])
        if output.hasPrefix("AGENTTERM-NO-TMUX") { throw NoTmux() }

        // A leading newline keeps the split working when there are no sessions ("--" first).
        let parts = ("\n" + output).components(separatedBy: "\n--\n")
        let ours = Set((parts.count > 1 ? parts[1] : "").split(separator: "\n").map(String.init))
        var windows: [String: [TmuxWindow]] = [:]
        for line in (parts.count > 2 ? parts[2] : "").split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let window = TmuxWindow(line[line.index(after: tab)...]) else { continue }
            windows[String(line[..<tab]), default: []].append(window)
        }
        return parts[0].split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let count = Int(fields[0]), let attached = Int(fields[1]),
                  let activity = TimeInterval(fields[2]) else { return nil }
            let name = String(fields[3])
            return TmuxSession(
                name: name, windows: count, attachedClients: attached,
                lastActivity: Date(timeIntervalSince1970: activity), isThisWindow: ours.contains(name),
                windowList: windows[name] ?? []
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct NoTmux: LocalizedError {
        var errorDescription: String? { "tmux isn't installed on this host." }
    }

    /// Moves this window's tmux client to `session`. Returns false if this window has no tmux client.
    static func switchClient(on host: HostProfile, tag: String, to session: String) async throws -> Bool {
        let script = envMatch + ours + ##"for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}" 2>/dev/null); do "##
            + ##"if ours "${c%%:*}" "${c#*:}"; then "##
            + ##"tmux switch-client -c "${c#*:}" -t "=$AGENTTERM_TARGET" && echo switched; fi; done; true"##
        let output = try await run(script, on: host, variables: ["AGENTTERM_MATCH": tag, "AGENTTERM_TARGET": session])
        return output.contains("switched")
    }

    enum PaneAction {
        case splitSideBySide, splitTopAndBottom, zoom, unzoom, newWindow, close
        case nextWindow, previousWindow, selectWindow(Int), renameWindow(String), closeWindow

        /// Runs against `$pane`, the pane this window's tmux client is showing.
        fileprivate var command: String {
            switch self {
            case .splitSideBySide: return ##"tmux split-window -h -t "$pane" -c "#{pane_current_path}""##
            case .splitTopAndBottom: return ##"tmux split-window -v -t "$pane" -c "#{pane_current_path}""##
            // resize-pane -Z toggles, so check first: a menu that's a little out of date (zoomed
            // with prefix-z meanwhile) never toggles the wrong way.
            case .zoom: return ##"{ [ "$(tmux display -p -t "$pane" "#{window_zoomed_flag}")" = 1 ] || tmux resize-pane -Z -t "$pane"; }"##
            case .unzoom: return ##"{ [ "$(tmux display -p -t "$pane" "#{window_zoomed_flag}")" = 0 ] || tmux resize-pane -Z -t "$pane"; }"##
            case .newWindow:
                return ##"tmux new-window -a -t "$(tmux display -p -t "$pane" "#{window_id}")" -c "#{pane_current_path}""##
            // Never the window's last pane (that would close the window, or end the session).
            case .close: return ##"{ [ "$(tmux display -p -t "$pane" "#{window_panes}")" -gt 1 ] && tmux kill-pane -t "$pane"; true; }"##
            case .nextWindow: return ##"tmux next-window -t "$(tmux display -p -t "$pane" "#{session_id}")""##
            case .previousWindow: return ##"tmux previous-window -t "$(tmux display -p -t "$pane" "#{session_id}")""##
            case .selectWindow(let index): return ##"tmux select-window -t "$(tmux display -p -t "$pane" "#{session_id}"):"## + "\(index)\""
            case .renameWindow(let name):
                return ##"tmux rename-window -t "$pane" -- "##  + TmuxService.shellQuote(name)
            // Never the session's last window (that would end the session).
            case .closeWindow:
                return ##"{ [ "$(tmux display -p -t "$pane" "#{session_windows}")" -gt 1 ] && tmux kill-window -t "$pane"; true; }"##
            }
        }
    }

    /// Acts on the pane this window's tmux client is showing. Uses tmux commands rather than
    /// prefix keys, so it doesn't depend on key bindings or tmux's y/n prompt.
    /// Returns false if this window has no tmux client.
    static func perform(_ action: PaneAction, on host: HostProfile, tag: String) async throws -> Bool {
        let script = envMatch + ours + ##"for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}" 2>/dev/null); do "##
            + ##"if ours "${c%%:*}" "${c#*:}"; then "##
            + ##"pane=$(tmux display -p -c "${c#*:}" "#{pane_id}") && "##
            + action.command + " && echo done; break; fi; done; true"
        let output = try await run(script, on: host, variables: ["AGENTTERM_MATCH": tag])
        return output.contains("done")
    }

    /// The window this window's tmux client shows: how many panes, whether one is zoomed, and
    /// the session's windows.
    struct WindowState: Equatable {
        let panes: Int
        let isZoomed: Bool
        var windows: [TmuxWindow] = []
    }

    /// The state of the tmux window this window's client is showing, or nil if this window has
    /// no tmux client.
    static func windowState(on host: HostProfile, tag: String) async throws -> WindowState? {
        let script = envMatch + ours + ##"for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}" 2>/dev/null); do "##
            + ##"if ours "${c%%:*}" "${c#*:}"; then "##
            + ##"tmux display -p -c "${c#*:}" "#{window_panes} #{window_zoomed_flag}"; "##
            + ##"tmux list-windows -t "$(tmux display -p -c "${c#*:}" "#{session_id}")" "##
            + ##"-F "#{window_index}\##t#{window_active}\##t#{window_panes}\##t#{window_name}"; break; fi; done; true"##
        let lines = try await run(script, on: host, variables: ["AGENTTERM_MATCH": tag]).split(separator: "\n")
        let fields = (lines.first ?? "").split(separator: " ").compactMap { Int($0) }
        guard fields.count == 2 else { return nil }
        return WindowState(panes: fields[0], isZoomed: fields[1] == 1, windows: lines.dropFirst().compactMap(TmuxWindow.init))
    }

    /// The working directory of the pane this window's tmux client is showing, or nil if this
    /// window has no tmux client.
    static func currentPath(on host: HostProfile, tag: String) async throws -> String? {
        let script = envMatch + ours + ##"for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}" 2>/dev/null); do "##
            + ##"if ours "${c%%:*}" "${c#*:}"; then "##
            + ##"tmux display -p -c "${c#*:}" "#{pane_current_path}"; break; fi; done; true"##
        let output = try await run(script, on: host, variables: ["AGENTTERM_MATCH": tag])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Where an editor hand-off to Claude Code goes: the pane it runs in, and its folder (for
    /// paths relative to it).
    struct ClaudeTarget {
        let pane: String
        let folder: String
        /// Just started: wait for its prompt before pasting.
        let started: Bool
    }

    /// Makes sure Claude Code is running for this window, and shows it: the active pane if it's
    /// Claude Code; else a pane anywhere in the session that is (this window's panes first),
    /// selected; else started in the active pane if that's an idle shell (in `folder`); else
    /// started in a new window "claude" (something else is running there). nil if this window
    /// has no tmux client.
    static func prepareClaude(on host: HostProfile, tag: String, folder: String) async throws -> ClaudeTarget? {
        let script = envMatch + ours + ##"""
            tty=
            for c in $(tmux list-clients -F "#{client_pid}:#{client_tty}" 2>/dev/null); do
                if ours "${c%%:*}" "${c#*:}"; then tty=${c#*:}; break; fi
            done
            [ -n "$tty" ] || exit 0
            pane=$(tmux display -p -c "$tty" "#{pane_id}")
            info() { tmux display -p -t "$1" "#{pane_current_command}"; }
            if [ "$(info "$pane")" = claude ]; then
                echo "ready $pane"; tmux display -p -t "$pane" "#{pane_current_path}"; exit 0
            fi
            other=$(tmux list-panes -s -t "$(tmux display -p -t "$pane" "#{session_id}")"                 -F "#{window_active} #{pane_id} #{pane_current_command}" | awk '$3 == "claude"' | sort -r | head -n 1 | cut -d " " -f 2)
            if [ -n "$other" ]; then
                tmux select-window -t "$other"; tmux select-pane -t "$other"
                echo "ready $other"; tmux display -p -t "$other" "#{pane_current_path}"; exit 0
            fi
            case "$(info "$pane")" in
                bash|zsh|sh|dash|fish|ksh)
                    if [ "$(tmux display -p -t "$pane" "#{pane_current_path}")" = "$FOLDER" ]; then
                        tmux send-keys -t "$pane" -l claude
                    else
                        tmux send-keys -t "$pane" -l "$CD_LINE"
                    fi
                    tmux send-keys -t "$pane" Enter
                    echo "started $pane"; echo "$FOLDER"; exit 0 ;;
            esac
            new=$(tmux new-window -P -F "#{pane_id}" -a -t "$(tmux display -p -t "$pane" "#{window_id}")" -n claude -c "$FOLDER")
            tmux send-keys -t "$new" -l claude; tmux send-keys -t "$new" Enter
            echo "started $new"; echo "$FOLDER"
            """##
        let output = try await run(script, on: host, variables: [
            "AGENTTERM_MATCH": tag, "FOLDER": folder, "CD_LINE": "cd \(shellQuote(folder)) && claude",
        ])
        let lines = output.split(separator: "\n").map(String.init)
        let first = (lines.first ?? "").split(separator: " ")
        guard lines.count >= 2, first.count == 2 else { return nil }
        return ClaudeTarget(pane: String(first[1]), folder: lines[1], started: first[0] == "started")
    }

    enum ClaudeReadiness: String {
        /// Its prompt is showing (past the folder-trust question, which is left to the user).
        case ready
        /// It exited (say, "No, exit" at the trust question), or the pane closed.
        case gone
        /// It never started (not installed?), or no prompt within three minutes.
        case missing, timeout
    }

    /// Waits on the host (one connection) until Claude Code in `pane` shows its input prompt.
    static func waitForClaude(on host: HostProfile, pane: String) async throws -> ClaudeReadiness {
        let script = ##"""
            seen=0; i=0
            while [ $i -lt 360 ]; do
                cmd=$(tmux display -p -t "$PANE" "#{pane_current_command}" 2>/dev/null) || { echo gone; exit 0; }
                if [ "$cmd" = claude ]; then
                    seen=1
                    screen=$(tmux capture-pane -p -t "$PANE" | tail -n 30)
                    if ! printf '%s\n' "$screen" | grep -q "trust this folder" && printf '%s\n' "$screen" | grep -q '^❯'; then
                        echo ready; exit 0
                    fi
                elif [ $seen = 1 ]; then
                    echo gone; exit 0
                elif [ $i -ge 40 ]; then
                    echo missing; exit 0
                fi
                sleep 0.5; i=$((i + 1))
            done
            echo timeout
            """##
        let output = try await run(script, on: host, variables: ["PANE": pane])
        return ClaudeReadiness(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .gone
    }

    static func create(on host: HostProfile, session: String) async throws {
        _ = try await run(##"tmux new -d -s "$AGENTTERM_TARGET""##, on: host, variables: ["AGENTTERM_TARGET": session])
    }

    /// tmux rejects ':' and '.' in session names.
    static func sanitizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    struct KillRefused: LocalizedError {
        var errorDescription: String? { "That's the only tmux session on this host, so it's kept." }
    }

    /// Makes `index` the current window of `session` (whoever is attached sees it).
    static func selectWindow(on host: HostProfile, session: String, index: Int) async throws {
        _ = try await run(##"tmux select-window -t "=$AGENTTERM_TARGET:$AGENTTERM_INDEX""##, on: host,
                          variables: ["AGENTTERM_TARGET": session, "AGENTTERM_INDEX": String(index)])
    }

    static func renameWindow(on host: HostProfile, session: String, index: Int, to name: String) async throws {
        _ = try await run(##"tmux rename-window -t "=$AGENTTERM_TARGET:$AGENTTERM_INDEX" -- "$AGENTTERM_NAME""##, on: host,
                          variables: ["AGENTTERM_TARGET": session, "AGENTTERM_INDEX": String(index), "AGENTTERM_NAME": name])
    }

    /// Closes a window, but never a session's last one.
    static func closeWindow(on host: HostProfile, session: String, index: Int) async throws {
        _ = try await run(##"""
            [ "$(tmux display -p -t "=$AGENTTERM_TARGET:" "#{session_windows}")" -gt 1 ] && tmux kill-window -t "=$AGENTTERM_TARGET:$AGENTTERM_INDEX"; true
            """##, on: host, variables: ["AGENTTERM_TARGET": session, "AGENTTERM_INDEX": String(index)])
    }

    /// Kills a session, but never the host's last one. Clients attached to it (this window,
    /// say) move to another session first instead of being disconnected.
    static func kill(on host: HostProfile, session: String) async throws {
        let output = try await run(##"""
            [ "$(tmux list-sessions 2>/dev/null | wc -l)" -gt 1 ] || { echo AGENTTERM-LAST; exit 0; }
            other=$(tmux list-sessions -F "#{session_name}" | grep -vxF -- "$AGENTTERM_TARGET" | head -n 1)
            for c in $(tmux list-clients -t "=$AGENTTERM_TARGET" -F "#{client_tty}" 2>/dev/null); do
                tmux switch-client -c "$c" -t "=$other"
            done
            tmux kill-session -t "=$AGENTTERM_TARGET"
            """##, on: host, variables: ["AGENTTERM_TARGET": session])
        if output.contains("AGENTTERM-LAST") { throw KillRefused() }
    }

    /// `tmux new -A -s <name>`, quoted for the remote shell.
    static func attachCommand(for session: String) -> String {
        "tmux new -A -s \(shellQuote(session))"
    }

    // MARK: Plumbing

    /// Runs `script` under `sh -c` with values passed as environment variables, so session names
    /// never need escaping inside the script itself.
    private static func run(_ script: String, on host: HostProfile, variables: [String: String]) async throws -> String {
        let client = try await TrustedSSH.connect(to: host)
        defer { Task { try? await client.close() } }

        var variables = variables
        if let tag = variables["AGENTTERM_MATCH"], let tty = tty(for: tag) { variables["CLIENT_TTY"] = tty }
        let assignments = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
        var output = try await client.executeCommand("\(assignments) sh -c \(shellQuote(toolPath + script))")
        return output.readString(length: output.readableBytes) ?? ""
    }

    /// Commands run over exec get a non-login shell's PATH, which on a Mac leaves out
    /// Homebrew (tmux, git, ripgrep); and the setup guide installs into ~/.local/bin.
    static let toolPath = #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; export PATH; "#

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
