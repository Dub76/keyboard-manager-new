import AppKit
import CoreTransferable
import UniformTypeIdentifiers

/// Reads photos from the clipboard: image files copied in Finder are used
/// where they are, image data (screenshots, "Copy Image" in a browser or in
/// Photos) is written to a private temporary folder first.
@MainActor
enum PhotoPasteboard {
    /// Formats the photo import understands, in order of preference. TIFF is
    /// what many apps put on the clipboard; it is converted to PNG.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        .tiff
    ]

    static func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(DroppedPhotoLoader.isImageFile)
    }

    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        !imageFileURLs(in: pasteboard).isEmpty || pasteboard.availableType(from: imageTypes) != nil
    }

    /// ⌘V in a text field should paste text. The clipboard is taken as photos
    /// there only if it holds image files or nothing that could be text.
    static func shouldPasteAsPhotos(_ pasteboard: NSPasteboard, textHasFocus: Bool) -> Bool {
        guard containsImages(pasteboard) else { return false }
        guard textHasFocus else { return true }
        return !imageFileURLs(in: pasteboard).isEmpty || pasteboard.availableType(from: [.string]) == nil
    }

    static func imageURLs(from pasteboard: NSPasteboard, temporaryDirectory: URL) throws -> [URL] {
        let files = imageFileURLs(in: pasteboard)
        if !files.isEmpty { return files }

        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let type = item.availableType(from: imageTypes),
                  var data = item.data(forType: type) else { continue }
            var fileExtension = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
            if type == .tiff {
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                    continue
                }
                data = png
                fileExtension = "png"
            }
            let folder = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(L10n.text("Eingefügtes Foto") + "." + fileExtension)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}

/// An image dropped onto an entry in the overview or gallery. Image data is
/// copied into a private temporary folder; the caller removes it afterwards.
struct DroppedImageFile: Transferable {
    var url: URL
    var isTemporary: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeyboardManagerDrop-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return DroppedImageFile(url: target, isTemporary: true)
        }
        ProxyRepresentation(importing: { (url: URL) in
            DroppedImageFile(url: url, isTemporary: false)
        })
    }

    /// Local image files only; web addresses and other files are dropped.
    static func usableURLs(_ files: [DroppedImageFile]) -> [URL] {
        files.map(\.url).filter { $0.isFileURL && DroppedPhotoLoader.isImageFile($0) }
    }

    static func removeTemporaryCopies(_ files: [DroppedImageFile]) {
        for file in files where file.isTemporary {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
    }
}

/// Moving a photo inside the editor's photo strip. The prefix keeps a
/// dragged photo from being mistaken for text dropped from elsewhere.
enum PhotoReorderDrag {
    static let prefix = "keyboard-manager-photo:"

    static func payload(for photoID: String) -> String {
        prefix + photoID
    }

    static func photoID(from payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        return String(payload.dropFirst(prefix.count))
    }
}
