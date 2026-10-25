import SwiftUI

/// The version, AgentTerm's licence (GPLv3 or later), and the licences of what it's built on:
/// Resources/Acknowledgements.json, made by scripts/update-acknowledgements.py.
struct AboutView: View {
    /// Where the source code is published; shown once there is one.
    static let sourceURL = URL(string: "https://github.com/ianmunro90/AgentTerm")

    struct Acknowledgement: Decodable, Identifiable {
        let name: String
        let url: String
        let license: String
        let text: String
        var id: String { name }
    }

    private let acknowledgements: [Acknowledgement] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Acknowledgement].self, from: data)) ?? []
    }()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                if let url = Self.sourceURL {
                    Link(destination: url) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
            } footer: {
                Text("AgentTerm is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3 or (at your option) any later version. It comes with no warranty.")
            }

            Section("Licence") {
                NavigationLink("AgentTerm (GPL 3.0 or later)") {
                    LicenceText(title: "AgentTerm", text: Self.bundled("LICENSE", "txt"))
                }
            }

            Section {
                ForEach(acknowledgements) { item in
                    NavigationLink {
                        LicenceText(title: item.name, text: item.text, link: URL(string: item.url))
                    } label: {
                        LabeledContent(item.name, value: item.license)
                    }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("AgentTerm is built on these open-source projects.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func bundled(_ name: String, _ ext: String) -> String {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

private struct LicenceText: View {
    let title: String
    let text: String
    var link: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let link {
                    Link(link.absoluteString, destination: link).font(.callout)
                }
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
