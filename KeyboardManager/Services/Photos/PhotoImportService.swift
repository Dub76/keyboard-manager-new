import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExternalImageFetchResult: Sendable {
    var data: Data
    var responseURL: URL
    var mimeType: String?
    var suggestedFileName: String?
}

protocol ExternalImageFetching: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> ExternalImageFetchResult
}

struct PreparedPhoto: Hashable, Sendable {
    var record: PhotoRecord
    var data: Data
}

enum PhotoImportError: LocalizedError, Sendable {
    case unreadable(String)
    case tooLarge(String)
    case unsupported(String)
    case encode(String)
    case unsafeFileName
    case invalidExternalURL
    case externalDownloadFailed(String)
    case invalidExternalResponse(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            L10n.text("„%@“ konnte nicht als Bild gelesen werden.", arguments: name)
        case let .tooLarge(name):
            L10n.text("„%@“ überschreitet das Limit von 30 MiB.", arguments: name)
        case let .unsupported(name):
            L10n.text("Das Bildformat von „%@“ wird nicht unterstützt.", arguments: name)
        case let .encode(name):
            L10n.text("„%@“ konnte nicht für die Mediathek aufbereitet werden.", arguments: name)
        case .unsafeFileName:
            L10n.text("Ein interner Fotodateiname war ungültig.")
        case .invalidExternalURL:
            L10n.text("Externe Importbilder müssen vollständige HTTPS-Adressen ohne Zugangsdaten verwenden.")
        case let .externalDownloadFailed(host):
            L10n.text("Das externe Importbild von „%@“ konnte nicht geladen werden.", arguments: host)
        case let .invalidExternalResponse(host):
            L10n.text("„%@“ hat keine gültige HTTPS-Bildantwort geliefert.", arguments: host)
        }
    }
}

actor PhotoImportService {
    static let maximumSourceBytes = 30 * 1_024 * 1_024
    static let maximumPixelWidth = 1_920
    static let maximumPixelHeight = 1_080

    private let layout: MigrationStorageLayout
    private let fileManager: FileManager
    private let externalImageFetcher: any ExternalImageFetching

    init(
        layout: MigrationStorageLayout = .default,
        fileManager: FileManager = .default,
        externalImageFetcher: any ExternalImageFetching = URLSessionExternalImageFetcher()
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.externalImageFetcher = externalImageFetcher
    }

    func prepare(urls: [URL], owner: PhotoOwner) throws -> [PreparedPhoto] {
        try urls.map { url in
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try prepare(url: url, owner: owner)
        }
    }

    func prepareExternal(urlStrings: [String], owner: PhotoOwner) async throws -> [PreparedPhoto] {
        var seen = Set<URL>()
        var prepared: [PreparedPhoto] = []

        for value in urlStrings {
            try Task.checkCancellation()
            guard let url = Self.validHTTPSURL(value) else {
                throw PhotoImportError.invalidExternalURL
            }
            guard seen.insert(url).inserted else { continue }

            let host = url.host(percentEncoded: false) ?? "unbekannter Host"
            let result: ExternalImageFetchResult
            do {
                result = try await externalImageFetcher.fetch(
                    url,
                    maximumBytes: Self.maximumSourceBytes
                )
            } catch let error as PhotoImportError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw PhotoImportError.externalDownloadFailed(host)
            }

            try Task.checkCancellation()
            guard Self.validHTTPSURL(result.responseURL.absoluteString) != nil,
                  result.mimeType?.lowercased().hasPrefix("image/") == true else {
                throw PhotoImportError.invalidExternalResponse(host)
            }
            guard result.data.count <= Self.maximumSourceBytes else {
                throw PhotoImportError.tooLarge(Self.safeExternalName(result, fallbackURL: url))
            }

            prepared.append(
                try prepare(
                    data: result.data,
                    name: Self.safeExternalName(result, fallbackURL: url),
                    owner: owner
                )
            )
        }

        return prepared
    }

    /// Copies existing managed photos for a new owner, for example when an
    /// entry is duplicated. The data was already checked and cleaned on
    /// import, so it is taken over unchanged. Missing files are skipped.
    func duplicate(_ records: [PhotoRecord], owner: PhotoOwner) -> [(sourceID: String, photo: PreparedPhoto)] {
        records.compactMap { record in
            guard let url = try? safeURL(for: record),
                  let data = try? Data(contentsOf: url) else { return nil }
            let id = UUID().uuidString
            let copy = PhotoRecord(
                id: id,
                owner: owner,
                originalName: record.originalName,
                mimeType: record.mimeType,
                pixelWidth: record.pixelWidth,
                pixelHeight: record.pixelHeight,
                addedAt: .now,
                relativeFileName: "\(id).\(record.mimeType.fileExtension)"
            )
            return (record.id, PreparedPhoto(record: copy, data: data))
        }
    }

    func commit(_ photos: [PreparedPhoto]) throws {
        guard !photos.isEmpty else { return }
        try fileManager.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )

        var committed: [URL] = []
        do {
            for photo in photos {
                let target = try safeURL(for: photo.record)
                guard !fileManager.fileExists(atPath: target.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try photo.data.write(to: target, options: [.atomic])
                committed.append(target)
            }
        } catch {
            committed.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
    }

    func remove(_ records: [PhotoRecord]) {
        for record in records {
            guard let url = try? safeURL(for: record) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Moves photos of a deleted item aside so the deletion can be undone.
    /// Returns false if not all of them could be kept.
    func hold(_ records: [PhotoRecord], holdID: String) -> Bool {
        guard !records.isEmpty else { return true }
        let folder = layout.deletedPhotosRootURL.appendingPathComponent(holdID, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for record in records {
                let source = try safeURL(for: record)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(
                    at: source,
                    to: folder.appendingPathComponent(source.lastPathComponent)
                )
            }
            return true
        } catch {
            return false
        }
    }

    func restoreHeld(_ records: [PhotoRecord], holdID: String) throws {
        guard !records.isEmpty else { return }
        let folder = layout.deletedPhotosRootURL.appendingPathComponent(holdID, isDirectory: true)
        try fileManager.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
        for record in records {
            let target = try safeURL(for: record)
            let held = folder.appendingPathComponent(target.lastPathComponent)
            guard fileManager.fileExists(atPath: held.path),
                  !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.moveItem(at: held, to: target)
        }
    }

    func discardHold(_ holdID: String) {
        try? fileManager.removeItem(
            at: layout.deletedPhotosRootURL.appendingPathComponent(holdID, isDirectory: true)
        )
    }

    /// A deletion can only be undone while the app keeps running, so held
    /// photos left over from an earlier session are final.
    func discardAllHolds() {
        try? fileManager.removeItem(at: layout.deletedPhotosRootURL)
    }

    func fileURL(for record: PhotoRecord) -> URL? {
        try? safeURL(for: record)
    }

    func data(for record: PhotoRecord) -> Data? {
        guard let url = try? safeURL(for: record) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func prepare(url: URL, owner: PhotoOwner) throws -> PreparedPhoto {
        let name = url.lastPathComponent
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber,
           size.intValue > Self.maximumSourceBytes {
            throw PhotoImportError.tooLarge(name)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PhotoImportError.unreadable(name)
        }
        return try prepare(data: data, name: name, owner: owner)
    }

    private func prepare(data: Data, name: String, owner: PhotoOwner) throws -> PreparedPhoto {
        guard data.count <= Self.maximumSourceBytes else {
            throw PhotoImportError.tooLarge(name)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw PhotoImportError.unreadable(name)
        }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let sourceType = CGImageSourceGetType(source) as String?,
              let sourceMIME = mimeType(for: sourceType) else {
            throw PhotoImportError.unsupported(name)
        }

        let output: (data: Data, mime: PhotoMIMEType, width: Int?, height: Int?)
        if let width, let height,
           width > Self.maximumPixelWidth || height > Self.maximumPixelHeight {
            // Re-encoding drops all source metadata, including the location.
            output = try scaledImage(from: source, originalMIME: sourceMIME, name: name)
        } else if !PhotoMetadataSanitizer.containsLocation(source) {
            output = (data, sourceMIME, width, height)
        } else if let cleaned = PhotoMetadataSanitizer.removingLocation(from: source) {
            output = (cleaned, sourceMIME, width, height)
        } else {
            // No lossless copy for this format (for example WebP): re-encode
            // at the original size, which writes no location data.
            output = try scaledImage(from: source, originalMIME: sourceMIME, name: name)
        }
        guard output.data.count <= Self.maximumSourceBytes else {
            throw PhotoImportError.tooLarge(name)
        }

        let id = UUID().uuidString
        let record = PhotoRecord(
            id: id,
            owner: owner,
            originalName: name,
            mimeType: output.mime,
            pixelWidth: output.width,
            pixelHeight: output.height,
            addedAt: .now,
            relativeFileName: "\(id).\(output.mime.fileExtension)"
        )
        return PreparedPhoto(record: record, data: output.data)
    }

    private static func validHTTPSURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    private static func safeExternalName(
        _ result: ExternalImageFetchResult,
        fallbackURL: URL
    ) -> String {
        let candidate = result.suggestedFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackURL.lastPathComponent.removingPercentEncoding
        let rawName = candidate?.isEmpty == false ? candidate : fallback
        let fileName = URL(fileURLWithPath: rawName ?? "").lastPathComponent
        return fileName.isEmpty ? "Externes Importbild" : fileName
    }

    private func scaledImage(
        from source: CGImageSource,
        originalMIME: PhotoMIMEType,
        name: String
    ) throws -> (data: Data, mime: PhotoMIMEType, width: Int?, height: Int?) {
        let maxPixelSize = max(Self.maximumPixelWidth, Self.maximumPixelHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoImportError.encode(name)
        }

        let scale = min(
            1,
            min(
                Double(Self.maximumPixelWidth) / Double(image.width),
                Double(Self.maximumPixelHeight) / Double(image.height)
            )
        )
        let finalImage: CGImage
        if scale < 1 {
            let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
            let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw PhotoImportError.encode(name)
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let rendered = context.makeImage() else {
                throw PhotoImportError.encode(name)
            }
            finalImage = rendered
        } else {
            finalImage = image
        }

        let outputMIME: PhotoMIMEType = originalMIME == .png ? .png : .jpeg
        let destinationType = outputMIME == .png ? UTType.png.identifier : UTType.jpeg.identifier
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            destinationType as CFString,
            1,
            nil
        ) else {
            throw PhotoImportError.encode(name)
        }
        let properties: [CFString: Any] = outputMIME == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(destination, finalImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoImportError.encode(name)
        }
        return (mutableData as Data, outputMIME, finalImage.width, finalImage.height)
    }

    private func mimeType(for identifier: String) -> PhotoMIMEType? {
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .gif) { return .gif }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if identifier.lowercased().contains("webp") { return .webP }
        return nil
    }

    private func safeURL(for record: PhotoRecord) throws -> URL {
        guard let fileName = record.managedFileName else {
            throw PhotoImportError.unsafeFileName
        }
        return layout.currentPhotosDirectoryURL.appendingPathComponent(fileName)
    }
}

/// Removes GPS location data from photos so it never ends up in the library
/// or in backups. Camera orientation and other metadata stay intact.
enum PhotoMetadataSanitizer {
    static func containsLocation(_ source: CGImageSource) -> Bool {
        (0..<CGImageSourceGetCount(source)).contains { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyGPSDictionary] != nil
        }
    }

    static func containsLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return containsLocation(source)
    }

    /// Returns the image without its location and with orientation and all
    /// other metadata kept. First tries a lossless copy with the GPS tags
    /// removed (works for JPEG and HEIC); where the format keeps them anyway
    /// (PNG), the image is written again without the GPS dictionary, which
    /// is lossless for PNG. Returns nil if neither removes the location.
    static func removingLocation(from source: CGImageSource) -> Data? {
        guard let type = CGImageSourceGetType(source) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        if let copied = losslessCopyWithoutGPSTags(source, type: type, count: count),
           !containsLocation(copied) {
            return copied
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, count, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        for index in 0..<count {
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), !containsLocation(output as Data) else {
            return nil
        }
        return output as Data
    }

    /// `kCGImageMetadataShouldExcludeGPS` is not used on purpose: for JPEG it
    /// also drops the orientation, so photos would appear rotated.
    private static func losslessCopyWithoutGPSTags(
        _ source: CGImageSource,
        type: CFString,
        count: Int
    ) -> Data? {
        guard count == 1,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let edited = CGImageMetadataCreateMutableCopy(metadata) else {
            return nil
        }
        var gpsPaths: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            if (path as String).hasPrefix("exif:GPS")
                || (namespace.contains("exif") && name.hasPrefix("GPS")) {
                gpsPaths.append(path)
            }
            return true
        }
        guard !gpsPaths.isEmpty else { return nil }
        for path in gpsPaths {
            CGImageMetadataRemoveTagWithPath(edited, nil, path)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: edited,
            kCGImageDestinationMergeMetadata: false
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            return nil
        }
        return output as Data
    }

    static func removingLocation(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return removingLocation(from: source)
    }
}

private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct URLSessionExternalImageFetcher: ExternalImageFetching {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> ExternalImageFetchResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60

        let session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let responseURL = httpResponse.url else {
            throw PhotoImportError.invalidExternalResponse(
                url.host(percentEncoded: false) ?? "unbekannter Host"
            )
        }
        let tooLarge = PhotoImportError.tooLarge(
            httpResponse.suggestedFilename ?? url.lastPathComponent
        )
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            throw tooLarge
        }

        // Enforce the limit while streaming so an oversized or endless body
        // is cut off instead of being buffered completely first.
        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(Int(httpResponse.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw tooLarge
            }
            data.append(byte)
        }

        return ExternalImageFetchResult(
            data: data,
            responseURL: responseURL,
            mimeType: httpResponse.mimeType,
            suggestedFileName: httpResponse.suggestedFilename
        )
    }
}
