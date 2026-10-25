import SwiftUI

/// A file's icon by name and extension, in the spirit of VS Code's default (Seti) icons and
/// their colours.
struct FileIcon: View {
    let name: String
    @Environment(\.editorTheme) private var theme

    var body: some View {
        let style = Self.style(for: name)
        Group {
            switch style.glyph {
            case .symbol(let symbol):
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            case .text(let text):
                Text(text)
                    .font(.system(size: text.count > 2 ? 8 : 10, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(Color(uiColor: color(style.color)))
        .frame(width: 18, height: 16)
    }

    /// Seti's palette is made for dark backgrounds; darken it on light themes.
    private func color(_ hex: String) -> UIColor {
        let color = UIColor(hex: hex)
        return theme?.isLight == true ? color.blended(with: .black, 0.28) : color
    }

    enum Glyph {
        case symbol(String)
        case text(String)
    }

    struct Style {
        let glyph: Glyph
        let color: String
    }

    private static let blue = "#519ABA", yellow = "#CBCB41", orange = "#E37933", red = "#CC3E44", green = "#8DC149"
    private static let purple = "#A074C4", pink = "#F55385", grey = "#6D8086", white = "#D4D7D6"

    static func style(for name: String) -> Style {
        let lower = name.lowercased()
        if let style = byName[lower] { return style }
        if lower.hasPrefix("readme") { return Style(glyph: .symbol("info.circle.fill"), color: blue) }
        if lower.hasPrefix("license") || lower.hasPrefix("licence") || lower == "copying" {
            return Style(glyph: .symbol("checkmark.seal.fill"), color: yellow)
        }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return Style(glyph: .symbol("shippingbox.fill"), color: blue) }
        if lower.hasPrefix(".env") { return Style(glyph: .symbol("gearshape.fill"), color: grey) }
        if lower.hasPrefix("docker-compose") || lower.hasPrefix("compose.") { return Style(glyph: .symbol("shippingbox.fill"), color: blue) }
        return byExtension[(lower as NSString).pathExtension] ?? Style(glyph: .symbol("doc.text"), color: grey)
    }

    private static let byName: [String: Style] = {
        var names: [String: Style] = [
            "claude.md": Style(glyph: .symbol("sparkle"), color: orange),
            "agents.md": Style(glyph: .symbol("sparkle"), color: orange),
            "makefile": Style(glyph: .symbol("hammer.fill"), color: orange),
            "gnumakefile": Style(glyph: .symbol("hammer.fill"), color: orange),
            "cmakelists.txt": Style(glyph: .symbol("hammer.fill"), color: blue),
            "package.json": Style(glyph: .text("npm"), color: red),
            "package.resolved": Style(glyph: .symbol("lock.fill"), color: grey),
            "gemfile": Style(glyph: .symbol("diamond.fill"), color: red),
            "go.mod": Style(glyph: .text("GO"), color: blue),
            "go.sum": Style(glyph: .text("GO"), color: blue),
            "tsconfig.json": Style(glyph: .text("TS"), color: blue),
            ".editorconfig": Style(glyph: .symbol("gearshape.fill"), color: grey),
            ".npmrc": Style(glyph: .text("npm"), color: red),
            "requirements.txt": Style(glyph: .text("Py"), color: blue),
        ]
        for git in [".gitignore", ".gitattributes", ".gitmodules", ".gitkeep", ".git-blame-ignore-revs"] {
            names[git] = Style(glyph: .symbol("arrow.triangle.branch"), color: orange)
        }
        for lock in ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "podfile.lock", "gemfile.lock", "poetry.lock", "composer.lock", "flake.lock"] {
            names[lock] = Style(glyph: .symbol("lock.fill"), color: grey)
        }
        for docker in [".dockerignore"] {
            names[docker] = Style(glyph: .symbol("shippingbox.fill"), color: grey)
        }
        return names
    }()

    private static let byExtension: [String: Style] = {
        var map: [String: Style] = [:]
        func set(_ extensions: [String], _ glyph: Glyph, _ color: String) {
            for ext in extensions { map[ext] = Style(glyph: glyph, color: color) }
        }
        set(["swift"], .symbol("swift"), orange)
        set(["js", "mjs", "cjs"], .text("JS"), yellow)
        set(["ts", "mts", "cts"], .text("TS"), blue)
        set(["jsx", "tsx"], .symbol("atom"), blue)
        set(["json", "jsonc", "json5"], .text("{}"), yellow)
        set(["md", "markdown", "mdx"], .text("M↓"), blue)
        set(["py", "pyi", "pyw"], .text("Py"), blue)
        set(["ipynb"], .symbol("book.closed.fill"), orange)
        set(["rb", "erb", "gemspec"], .symbol("diamond.fill"), red)
        set(["go"], .text("GO"), blue)
        set(["rs"], .symbol("gearshape.2.fill"), orange)
        set(["c"], .text("C"), blue)
        set(["cpp", "cc", "cxx", "c++"], .text("C++"), blue)
        set(["h", "hpp", "hh", "hxx"], .text("h"), purple)
        set(["m", "mm"], .text("m"), blue)
        set(["cs", "csx"], .text("C#"), blue)
        set(["fs", "fsx"], .text("F#"), blue)
        set(["java", "jar"], .symbol("cup.and.saucer.fill"), red)
        set(["kt", "kts"], .text("K"), orange)
        set(["scala", "sc"], .text("S"), red)
        set(["dart"], .text("D"), blue)
        set(["php"], .text("php"), purple)
        set(["lua"], .symbol("moon.fill"), blue)
        set(["r"], .text("R"), blue)
        set(["pl", "pm"], .text("pl"), blue)
        set(["ex", "exs", "heex"], .symbol("drop.fill"), purple)
        set(["erl", "hrl"], .text("erl"), red)
        set(["hs", "lhs"], .text("λ"), purple)
        set(["ml", "mli"], .text("λ"), orange)
        set(["clj", "cljs", "cljc", "edn"], .text("λ"), green)
        set(["zig"], .text("Z"), orange)
        set(["nim"], .text("N"), yellow)
        set(["vue"], .text("V"), green)
        set(["svelte"], .text("S"), orange)
        set(["html", "htm", "xhtml"], .symbol("chevron.left.forwardslash.chevron.right"), orange)
        set(["xml", "xsd", "xsl", "xib", "storyboard", "csproj", "props", "resx"], .symbol("chevron.left.forwardslash.chevron.right"), orange)
        set(["plist", "entitlements"], .symbol("list.bullet.rectangle.fill"), grey)
        set(["css"], .text("#"), blue)
        set(["scss", "sass"], .text("#"), pink)
        set(["less"], .text("#"), blue)
        set(["sh", "bash", "zsh", "fish", "ksh", "command"], .text(">_"), green)
        set(["ps1", "psm1", "bat", "cmd"], .text(">_"), blue)
        set(["yml", "yaml"], .symbol("list.bullet.indent"), purple)
        set(["toml", "ini", "cfg", "conf", "config", "properties", "env"], .symbol("gearshape.fill"), grey)
        set(["lock"], .symbol("lock.fill"), grey)
        set(["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns"], .symbol("photo"), purple)
        set(["svg"], .symbol("square.on.circle"), yellow)
        set(["pdf"], .symbol("doc.richtext.fill"), red)
        set(["zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst"], .symbol("doc.zipper"), yellow)
        set(["txt", "text", "rtf"], .symbol("doc.plaintext"), white)
        set(["log"], .symbol("list.bullet.rectangle"), grey)
        set(["csv", "tsv", "xlsx", "xls", "numbers"], .symbol("tablecells"), green)
        set(["sql", "db", "sqlite", "sqlite3", "prisma"], .symbol("cylinder.split.1x2.fill"), pink)
        set(["graphql", "gql"], .symbol("hexagon.fill"), pink)
        set(["proto"], .symbol("hexagon"), blue)
        set(["mp4", "mov", "webm", "mkv", "avi", "m4v"], .symbol("film"), pink)
        set(["mp3", "wav", "m4a", "flac", "aac", "ogg"], .symbol("waveform"), pink)
        set(["ttf", "otf", "woff", "woff2"], .symbol("textformat"), red)
        set(["pem", "key", "crt", "cer", "pub", "p12", "gpg", "asc"], .symbol("key.fill"), yellow)
        set(["pbxproj", "xcodeproj", "xcworkspace", "xcconfig", "xcscheme"], .symbol("hammer.fill"), blue)
        set(["gradle"], .symbol("hammer.fill"), blue)
        set(["tf", "tfvars", "hcl"], .text("tf"), purple)
        set(["nix"], .symbol("snowflake"), blue)
        set(["diff", "patch"], .symbol("plusminus"), orange)
        set(["mk", "cmake"], .symbol("hammer.fill"), orange)
        set(["wasm"], .text("wa"), purple)
        return map
    }()
}
