import Citadel
import Foundation

/// What a server has of the tools AgentTerm uses, and the script that installs the missing
/// ones: the system's package manager (with sudo) for tmux, mosh, git, ripgrep, Node.js and
/// ShellCheck; npm into ~/.local for the language servers; Microsoft's dotnet-install into
/// ~/.dotnet for C#; Anthropic's installer for Claude Code. Linux and macOS (Homebrew).
enum ServerCheck {
    enum Tool: String, CaseIterable, Identifiable {
        case tmux, mosh, git, ripgrep, node, shellcheck, languageServers, csharp, claude

        var id: String { rawValue }

        var name: String {
            switch self {
            case .tmux: "tmux"
            case .mosh: "mosh"
            case .git: "git"
            case .ripgrep: "ripgrep"
            case .node: "Node.js and npm"
            case .shellcheck: "ShellCheck"
            case .languageServers: "Language servers"
            case .csharp: "C# (.NET SDK and csharp-ls)"
            case .claude: "Claude Code"
            }
        }

        var purpose: String {
            switch self {
            case .tmux: "Keeps sessions running when the app is suspended; panes, windows and the session sidebar."
            case .mosh: "A connection that survives network changes and sleep (turn it on in Edit Host)."
            case .git: "Source Control in the editor."
            case .ripgrep: "Fast search in the editor (it falls back to grep)."
            case .node: "Needed to install the language servers."
            case .shellcheck: "Problems in shell scripts."
            case .languageServers: "Problems, docs and go to definition for TypeScript/JavaScript, Python, shell, YAML, JSON, CSS, HTML and Dockerfiles."
            case .csharp: "Problems and code navigation for C# (installs the .NET 10 SDK, a few hundred MB)."
            case .claude: "Anthropic's coding agent, which the editor hands files, selections and problems to."
            }
        }

        var symbol: String {
            switch self {
            case .tmux: "rectangle.split.3x1"
            case .mosh: "antenna.radiowaves.left.and.right"
            case .git: "arrow.triangle.branch"
            case .ripgrep: "magnifyingglass"
            case .node: "shippingbox"
            case .shellcheck: "checkmark.seal"
            case .languageServers: "curlybraces"
            case .csharp: "number"
            case .claude: "sparkles"
            }
        }
    }

    /// The npm language servers, pinned to versions that run on Node 20 (and the command each
    /// installs, to tell which are there).
    static let npmServers: [(package: String, command: String)] = [
        ("typescript-language-server@5.3.0", "typescript-language-server"),
        ("typescript@6.0.3", "tsserver"),
        ("pyright@1.1.414", "pyright-langserver"),
        ("bash-language-server@5.8.1", "bash-language-server"),
        ("yaml-language-server@1.19.2", "yaml-language-server"),
        ("vscode-langservers-extracted@4.10.0", "vscode-json-language-server"),
        ("dockerfile-language-server-nodejs@0.15.0", "docker-langserver"),
    ]

    struct Report {
        var system = ""
        var architecture = ""
        /// apt-get, dnf, yum, pacman, zypper, apk or brew; nil if none was found.
        var packageManager: String?
        var isRoot = false
        var hasSudo = false
        var hasCurl = false
        var hasBash = false
        var hasSystemDotnet = false
        /// Each tool found, with its version line ("" if it has none).
        var found: [Tool: String] = [:]
        /// The language servers' commands that are there.
        var servers: Set<String> = []
        /// Node.js that's there but too old for the language servers (they need 18).
        var oldNode: String?

        func isInstalled(_ tool: Tool) -> Bool { found[tool] != nil }

        /// Whether the app can install it here.
        func canInstall(_ tool: Tool) -> Bool {
            switch tool {
            case .languageServers: return isInstalled(.node) || canInstall(.node)
            case .csharp, .claude: return (hasCurl && hasBash) || packageManager != nil
            default: return packageManager != nil && (packageManager == "brew" || isRoot || hasSudo)
            }
        }

        /// "4 of 7", for the language servers.
        var serverSummary: String {
            let present = ServerCheck.npmServers.filter { servers.contains($0.command) }.count
            return "\(present) of \(ServerCheck.npmServers.count) installed"
        }
    }

    /// Looks at the host over a background connection (its key must be trusted, and a key or
    /// password must log in). PATH is the login shell's, plus where the installers put things.
    static func check(_ host: HostProfile) async throws -> Report {
        let client = try await TrustedSSH.connect(to: host, timeout: 10)
        defer { Task { try? await client.close() } }
        let commands = npmServers.map(\.command).joined(separator: " ")
        var output = try await client.executeCommand("SERVERS='\(commands)' sh -c \(TmuxService.shellQuote(probeScript))")
        return parse(output.readString(length: output.readableBytes) ?? "")
    }

    /// Prints key=value lines about the host (see `parse`); $SERVERS lists the language
    /// servers' commands.
    static let probeScript = ##"""
        P="$PATH"; L=
        case "${SHELL:-}" in
            *fish) L=$("$SHELL" -lc 'string join : $PATH' 2>/dev/null </dev/null) ;;
            *bash|*zsh|*ksh|*/sh|*dash) L=$("$SHELL" -lc 'printf %s "$PATH"' 2>/dev/null </dev/null) ;;
        esac
        PATH="$HOME/.local/bin:$HOME/.dotnet/tools:$HOME/.dotnet:/opt/homebrew/bin:/usr/local/bin:${L:-$P}:$P"; export PATH
        echo "system=$(uname -s)"; echo "arch=$(uname -m)"
        if [ -r /etc/os-release ]; then (. /etc/os-release; echo "distro=${PRETTY_NAME:-$NAME}"); fi
        if command -v sw_vers >/dev/null 2>&1; then echo "distro=macOS $(sw_vers -productVersion)"; fi
        for pm in apt-get dnf yum pacman zypper apk brew; do
            if command -v $pm >/dev/null 2>&1; then echo "pm=$pm"; break; fi
        done
        [ "$(id -u)" = 0 ] && echo "root=1"
        command -v sudo >/dev/null 2>&1 && echo "sudo=1"
        command -v curl >/dev/null 2>&1 && echo "curl=1"
        command -v bash >/dev/null 2>&1 && echo "bash=1"
        [ -x /usr/bin/dotnet ] || [ -x /usr/share/dotnet/dotnet ] || [ -x /usr/local/share/dotnet/dotnet ] && echo "systemdotnet=1"
        v() { k=$1; shift; if command -v "$1" >/dev/null 2>&1; then echo "$k=$("$@" 2>&1 </dev/null | head -n 1)"; fi; }
        v tmux tmux -V
        command -v mosh-server >/dev/null 2>&1 && echo "mosh=$(mosh-server --version 2>&1 </dev/null | head -n 1)"
        v git git --version
        v ripgrep rg --version
        command -v npm >/dev/null 2>&1 && v node node --version
        command -v shellcheck >/dev/null 2>&1 && echo "shellcheck=ShellCheck $(shellcheck --version 2>/dev/null </dev/null | sed -n 's/^version: //p')"
        command -v csharp-ls >/dev/null 2>&1 && command -v dotnet >/dev/null 2>&1 && echo "csharp=.NET $(dotnet --version 2>/dev/null </dev/null)"
        v claude claude --version
        for s in $SERVERS; do command -v "$s" >/dev/null 2>&1 && echo "server=$s"; done
        true
        """##

    static func parse(_ output: String) -> Report {
        var report = Report()
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "system": report.system = value == "Darwin" ? "macOS" : value
            case "arch": report.architecture = value
            case "distro": report.system = value
            case "pm": report.packageManager = value
            case "root": report.isRoot = true
            case "sudo": report.hasSudo = true
            case "curl": report.hasCurl = true
            case "bash": report.hasBash = true
            case "systemdotnet": report.hasSystemDotnet = true
            case "server": report.servers.insert(value)
            case "node":
                // "v16.20.2": the language servers need 18 or later.
                if let major = Int(value.dropFirst().prefix { $0.isNumber }), major < 18 {
                    report.oldNode = value
                } else {
                    report.found[.node] = value
                }
            default:
                if let tool = Tool(rawValue: key) { report.found[tool] = value }
            }
        }
        // The group counts as installed when all of them are.
        if npmServers.allSatisfy({ report.servers.contains($0.command) }) {
            report.found[.languageServers] = report.serverSummary
        }
        return report
    }

    // MARK: Installing

    /// The system packages for `tools` with this package manager.
    private static func packages(_ tools: [Tool], _ manager: String) -> [String] {
        tools.flatMap { tool -> [String] in
            switch tool {
            case .tmux: ["tmux"]
            case .mosh: ["mosh"]
            case .git: ["git"]
            case .ripgrep: ["ripgrep"]
            case .node: manager == "brew" ? ["node"] : ["nodejs", "npm"]
            case .shellcheck: [["zypper", "dnf", "yum"].contains(manager) ? "ShellCheck" : "shellcheck"]
            default: []
            }
        }
    }

    private static func icuPackage(_ manager: String) -> String? {
        switch manager {
        case "apt-get": "'^libicu[0-9]+$'"   // versioned (libicu76): apt takes a regular expression
        case "dnf", "yum": "libicu"
        case "pacman": "icu"
        case "apk": "icu-libs"
        default: nil   // zypper: libicuNN comes with the base system; macOS has its own
        }
    }

    /// Refreshes the package lists, then installs each package on its own, so one that isn't
    /// available here (mosh without EPEL, say) doesn't stop the rest.
    private static func installCommands(_ manager: String, _ packages: [String]) -> String {
        let install: String
        var refresh: String?
        switch manager {
        case "apt-get":
            refresh = "$S apt-get update"
            install = "$S env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
        case "dnf", "yum":
            install = "$S \(manager) install -y"
            // RHEL, Rocky, Alma: mosh, ripgrep and ShellCheck are in EPEL, and Node.js 20 is a
            // module stream (the default, 16 on EL9, is too old for the language servers).
            refresh = "if grep -qiE '^ID_LIKE=.*(rhel|centos)' /etc/os-release 2>/dev/null; then "
                + "$S \(manager) install -y epel-release || failed epel-release; "
                + "$S \(manager) -y module switch-to nodejs:20 >/dev/null 2>&1 || $S \(manager) -y module enable nodejs:20 >/dev/null 2>&1; true; fi"
        case "pacman": install = "$S pacman -S --needed --noconfirm"
        case "zypper":
            refresh = "$S zypper --non-interactive refresh"
            install = "$S zypper --non-interactive install"
        case "apk":
            refresh = "$S apk update"
            install = "$S apk add"
        default: install = "brew install"
        }
        let each = "for p in \(packages.joined(separator: " ")); do \(install) \"$p\" || failed \"$p\"; done"
        return [refresh.map { "\($0) || failed \"\(manager) update\"" }, each].compactMap { $0 }.joined(separator: "\n")
    }

    /// A POSIX shell script that installs `tools`, step by step, saying what each step does.
    static func installScript(_ tools: Set<Tool>, report: Report) -> String {
        var steps: [String] = []
        var system = Tool.allCases.filter { tools.contains($0) && packages([$0], report.packageManager ?? "").count > 0 }
        // npm for the language servers, curl for the installers.
        if tools.contains(.languageServers), !report.isInstalled(.node), !system.contains(.node) { system.append(.node) }
        var names = packages(system, report.packageManager ?? "")
        // The .NET and Claude Code installers are bash scripts fetched with curl.
        if tools.contains(.csharp) || tools.contains(.claude) {
            if !report.hasCurl { names.append("curl") }
            if !report.hasBash { names.append("bash") }
        }
        // A downloaded .NET needs the system's ICU (Fedora's minimal installs lack it).
        if tools.contains(.csharp), !report.hasSystemDotnet, let icu = icuPackage(report.packageManager ?? "") {
            names.append(icu)
        }
        if let manager = report.packageManager, !names.isEmpty {
            steps.append("""
                step "Installing \(names.map { $0.contains("libicu") ? "libicu" : $0 }.joined(separator: ", ")) with \(manager)"
                \(installCommands(manager, names))
                """)
        }
        if tools.contains(.languageServers) {
            let missing = npmServers.filter { !report.servers.contains($0.command) }.map(\.package)
            steps.append("""
                step "Installing language servers with npm (into ~/.local, no sudo)"
                npm install -g --prefix "$HOME/.local" \((missing.isEmpty ? npmServers.map(\.package) : missing).joined(separator: " ")) || failed npm
                """)
        }
        if tools.contains(.csharp) {
            let sdk = report.hasSystemDotnet ? "" : """
                installer https://dot.net/v1/dotnet-install.sh --channel 10.0 --install-dir "$HOME/.dotnet" || failed dotnet-install
                export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH"

                """
            steps.append("""
                step "Installing C#: \(report.hasSystemDotnet ? "" : ".NET 10 SDK into ~/.dotnet, then ")csharp-ls"
                \(sdk)dotnet tool install --global csharp-ls --version 0.28.0 || dotnet tool update --global csharp-ls --version 0.28.0 || failed csharp-ls
                """)
        }
        if tools.contains(.claude) {
            steps.append("""
                step "Installing Claude Code (Anthropic's installer, into ~/.local)"
                installer https://claude.ai/install.sh || failed "Claude Code"
                """)
        }
        return """
            S=; [ "$(id -u)" = 0 ] || S=sudo
            PATH="$HOME/.local/bin:$HOME/.dotnet/tools:$HOME/.dotnet:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
            problems=
            step() { printf '\\n\\033[1;36m== %s\\033[0m\\n' "$1"; }
            failed() { printf '\\033[1;31m!! %s failed\\033[0m\\n' "$1"; problems="$problems $1"; }
            # Downloads an installer, then runs it with bash (piped, a failed download would pass).
            installer() { u=$1; shift; t=$(mktemp) && curl -fsSL "$u" -o "$t" && bash "$t" "$@"; r=$?; rm -f "$t"; return $r; }
            \(steps.joined(separator: "\n"))
            if [ -n "$problems" ]; then
                printf '\\n\\033[1;31m== Finished with problems:%s\\033[0m\\n' "$problems"
            else
                printf '\\n\\033[1;32m== Done.\\033[0m Close this to check the server again.\\n'
            fi
            """
    }

    /// Puts `script` in a temporary file on the host (over a background connection: typed
    /// into a terminal it would pass the tty's 4 KB line limit) and returns the short command
    /// that runs then removes it, so prompts (sudo's password) read the keyboard, not the
    /// script. Works from any login shell, fish included.
    static func prepare(_ script: String, on host: HostProfile) async throws -> String {
        let client = try await TrustedSSH.connect(to: host, timeout: 10)
        defer { Task { try? await client.close() } }
        let encoded = Data(script.utf8).base64EncodedString()
        let write = #"umask 077; f=$(mktemp "${TMPDIR:-/tmp}/agentterm-install.XXXXXX") && "#
            + #"{ printf %s "$B" | base64 -d > "$f" 2>/dev/null || printf %s "$B" | base64 -D > "$f"; } && echo "$f""#
        var output = try await client.executeCommand("B=\(encoded) sh -c \(TmuxService.shellQuote(write))")
        let path = (output.readString(length: output.readableBytes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw PrepareFailed() }
        return "sh \(TmuxService.shellQuote(path)); rm -f \(TmuxService.shellQuote(path))"
    }

    struct PrepareFailed: LocalizedError {
        var errorDescription: String? { "Couldn't write the install script on the server." }
    }
}
