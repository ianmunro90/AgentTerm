import Foundation
import UIKit
import UniformTypeIdentifiers

/// Turns shared, dropped or pasted item providers (files, photos, screenshots) into local files
/// ready for `Uploader`.
enum ItemLoader {
    static func load(_ providers: [NSItemProvider]) async -> [Uploader.Item] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [Uploader.Item] = []
        for provider in providers {
            if let item = await load(provider, into: directory) { items.append(item) }
        }
        return items
    }

    /// Image formats Claude accepts; Claude Code only attaches a pasted path ([Image #1]) for
    /// these, so e.g. a HEIC path stays plain text (checked against Claude Code).
    private static let claudeImageTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    private static func load(_ provider: NSItemProvider, into directory: URL) async -> Uploader.Item? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        // Images: a format Claude reads if one is on offer (screenshots offer PNG next to HEIC),
        // otherwise convert to JPEG.
        if let type = claudeImageTypes.first(where: types.contains),
           let url = await copyFile(from: provider, type: type, into: directory) {
            return Uploader.Item(localURL: url, filename: filename(for: provider, type: type))
        }
        if let type = types.first(where: { $0.conforms(to: .image) }),
           let source = await copyFile(from: provider, type: type, into: directory),
           let image = UIImage(contentsOfFile: source.path), let jpeg = image.jpegData(compressionQuality: 0.9) {
            let url = directory.appendingPathComponent(UUID().uuidString)
            guard (try? jpeg.write(to: url)) != nil else { return nil }
            return Uploader.Item(localURL: url, filename: filename(for: provider, type: .jpeg))
        }
        // Anything else: the richest concrete data type on offer.
        if let type = types.first(where: { $0.conforms(to: .data) && $0 != .data }) ?? types.first(where: { $0.conforms(to: .data) }),
           let url = await copyFile(from: provider, type: type, into: directory) {
            return Uploader.Item(localURL: url, filename: filename(for: provider, type: type))
        }
        // Screenshots straight from the markup editor can arrive as an image object only.
        if provider.canLoadObject(ofClass: UIImage.self),
           let image = await loadImage(from: provider), let data = image.pngData() {
            let name = filename(for: provider, type: .png)
            let url = directory.appendingPathComponent(UUID().uuidString)
            guard (try? data.write(to: url)) != nil else { return nil }
            return Uploader.Item(localURL: url, filename: name)
        }
        return nil
    }

    private static func copyFile(from provider: NSItemProvider, type: UTType, into directory: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The provider deletes its file when this returns, so copy it out first.
                guard let url else { return continuation.resume(returning: nil) }
                let copy = directory.appendingPathComponent(UUID().uuidString)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func filename(for provider: NSItemProvider, type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "bin"
        guard let suggested = provider.suggestedName, !suggested.isEmpty else {
            return Uploader.generatedName(extension: ext)
        }
        let current = (suggested as NSString).pathExtension
        // Images may have been converted (e.g. .HEIC to .jpeg): the extension must match the bytes.
        if type.conforms(to: .image), !current.isEmpty {
            return (suggested as NSString).deletingPathExtension + "." + ext
        }
        return current.isEmpty ? "\(suggested).\(ext)" : suggested
    }
}
