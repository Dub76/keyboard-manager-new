import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

enum V1BackupReaderError: LocalizedError, Sendable {
    case notARegularFile
    case archiveTooLarge
    case invalidArchive
    case missingManifest
    case manifestTooLarge
    case invalidManifest
    case unsupportedSchema(Int)
    case unsupportedFormat
    case tooManyEntries
    case unsafeArchiveEntry(String)
    case duplicateArchiveEntry(String)
    case entryTooLarge(String)
    case checksumMismatch(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case missingPhotoFile(String)
    case unsupportedPhotoType(String)
    case invalidPhoto(String)
    case photoDataTooLarge
    case unsupportedSource
    case invalidLegacyJSON
    case unsupportedLegacySchema(Int)
    case invalidLegacyPhoto(String)

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            L10n.text("Die ausgewählte Quelle ist keine reguläre Backup-Datei.")
        case .archiveTooLarge:
            L10n.text("Das Backup überschreitet das Limit von 500 MiB.")
        case .invalidArchive:
            L10n.text("Das ZIP-Archiv konnte nicht sicher geöffnet werden.")
        case .missingManifest:
            L10n.text("Das ZIP enthält kein manifest.json.")
        case .manifestTooLarge:
            L10n.text("Das Manifest überschreitet das Limit von 10 MiB.")
        case .invalidManifest:
            L10n.text("Das V1-Manifest ist nicht lesbar oder unvollständig.")
        case let .unsupportedSchema(schema):
            L10n.text(
                "ZIP-Backup-Schema %lld wird nicht unterstützt; erwartet wird Schema 3 bis 6.",
                arguments: schema
            )
        case .unsupportedFormat:
            L10n.text("Das Manifest ist kein Keyboard-Manager-ZIP-Backup.")
        case .tooManyEntries:
            L10n.text("Das Backup enthält mehr Einträge als erlaubt.")
        case let .unsafeArchiveEntry(path):
            L10n.text("Unsicherer oder unerwarteter ZIP-Eintrag: %@", arguments: path)
        case let .duplicateArchiveEntry(path):
            L10n.text("Doppelter ZIP-Eintrag: %@", arguments: path)
        case let .entryTooLarge(path):
            L10n.text("ZIP-Eintrag überschreitet sein Größenlimit: %@", arguments: path)
        case let .checksumMismatch(path):
            L10n.text("CRC-Prüfung fehlgeschlagen: %@", arguments: path)
        case let .invalidIdentifier(kind):
            L10n.text("Ungültige oder fehlende ID bei %@.", arguments: kind)
        case let .duplicateIdentifier(kind):
            L10n.text("Doppelte ID bei %@.", arguments: kind)
        case let .missingPhotoFile(path):
            L10n.text("Im ZIP fehlt eine referenzierte Fotodatei: %@", arguments: path)
        case let .unsupportedPhotoType(type):
            L10n.text("Nicht unterstützter Fototyp: %@", arguments: type)
        case let .invalidPhoto(path):
            L10n.text("Bilddaten konnten nicht dekodiert werden: %@", arguments: path)
        case .photoDataTooLarge:
            L10n.text("Die entpackten Fotodaten überschreiten das Limit von 500 MiB.")
        case .unsupportedSource:
            L10n.text("Bitte ein V1-ZIP-Backup, ein Legacy-JSON-Backup oder den V1-Datenordner auswählen.")
        case .invalidLegacyJSON:
            L10n.text("Das Legacy-JSON ist nicht lesbar oder kein vollständiges V1-Backup.")
        case let .unsupportedLegacySchema(schema):
            L10n.text("JSON-Schema %lld ist kein unterstütztes Legacy-Backup.", arguments: schema)
        case let .invalidLegacyPhoto(photoID):
            L10n.text("Eingebettete Bilddaten sind ungültig oder zu groß: %@", arguments: photoID)
        }
    }
}

struct V1BackupReader: Sendable {
    private static let maximumArchiveBytes: Int64 = 500 * 1_024 * 1_024
    private static let maximumManifestBytes: UInt64 = 10 * 1_024 * 1_024
    private static let maximumPhotoBytes: UInt64 = 30 * 1_024 * 1_024
    private static let maximumPhotoTotalBytes: UInt64 = 500 * 1_024 * 1_024
    private static let maximumItemsPerKind = 10_000
    private static let maximumPhotos = 50_000

    func inspect(at url: URL) async throws -> MigrationDryRunResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.inspectSynchronously(at: url)
        }.value
    }

    private static func inspectSynchronously(at url: URL) throws -> MigrationDryRunResult {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw V1BackupReaderError.notARegularFile
        }

        let sourceByteCount = Int64(resourceValues.fileSize ?? 0)
        guard sourceByteCount > 0, sourceByteCount <= maximumArchiveBytes else {
            throw V1BackupReaderError.archiveTooLarge
        }
        let sourceSHA256 = try sha256(of: url)

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw V1BackupReaderError.invalidArchive
        }

        let entries = Array(archive)
        guard entries.count <= maximumPhotos + 1 else {
            throw V1BackupReaderError.tooManyEntries
        }

        var entriesByPath: [String: Entry] = [:]
        for entry in entries {
            guard entry.type == .file, isAllowedArchivePath(entry.path) else {
                throw V1BackupReaderError.unsafeArchiveEntry(entry.path)
            }
            guard entriesByPath.updateValue(entry, forKey: entry.path) == nil else {
                throw V1BackupReaderError.duplicateArchiveEntry(entry.path)
            }
        }

        guard let manifestEntry = entriesByPath["manifest.json"] else {
            throw V1BackupReaderError.missingManifest
        }
        guard manifestEntry.uncompressedSize <= maximumManifestBytes else {
            throw V1BackupReaderError.manifestTooLarge
        }

        let manifestData = try read(entry: manifestEntry, from: archive, maximumBytes: maximumManifestBytes)
        let manifest: V1BackupManifest
        do {
            manifest = try JSONDecoder().decode(V1BackupManifest.self, from: manifestData)
        } catch {
            throw V1BackupReaderError.invalidManifest
        }

        guard let schemaVersion = manifest.schemaVersion else {
            throw V1BackupReaderError.invalidManifest
        }
        guard (3...6).contains(schemaVersion) else {
            throw V1BackupReaderError.unsupportedSchema(schemaVersion)
        }
        guard manifest.format == "keyboard-manager-zip" else {
            throw V1BackupReaderError.unsupportedFormat
        }

        let v1Boards = manifest.boards ?? []
        let v1KeycapSets = manifest.keycapSets ?? []
        let v1ArtisanSets = manifest.artisanSets ?? []
        let v1SwitchSets = manifest.switchSets ?? []
        let v1Photos = manifest.photos ?? []

        guard v1Boards.count <= maximumItemsPerKind,
              v1KeycapSets.count <= maximumItemsPerKind,
              v1ArtisanSets.count <= maximumItemsPerKind,
              v1SwitchSets.count <= maximumItemsPerKind,
              v1Photos.count <= maximumPhotos else {
            throw V1BackupReaderError.tooManyEntries
        }

        let boardIDs = try validatedIDs(v1Boards.map(\.id), kind: "Boards")
        let keycapIDs = try validatedIDs(v1KeycapSets.map(\.id), kind: "Keycap-Sets")
        let artisanIDs = try validatedIDs(v1ArtisanSets.map(\.id), kind: "Artisans")
        let switchIDs = try validatedIDs(v1SwitchSets.map(\.id), kind: "Switches")
        let photoIDs = try validatedIDs(v1Photos.map(\.id), kind: "Fotos")

        var issues: [MigrationIssue] = []
        addIssue(
            code: "legacy-zip-schema",
            severity: .warning,
            message: "Ein älteres V1-ZIP-Schema wird kontrolliert auf das aktuelle V2-Modell normalisiert.",
            count: schemaVersion < 6 ? 1 : 0,
            to: &issues
        )
        addEmptyNameIssue(v1Boards.map(\.name), kind: "Boards", code: "empty-board-name", to: &issues)
        addEmptyNameIssue(v1KeycapSets.map(\.name), kind: "Keycap-Sets", code: "empty-keycap-name", to: &issues)
        addEmptyNameIssue(v1ArtisanSets.map(\.name), kind: "Artisans", code: "empty-artisan-name", to: &issues)
        addEmptyNameIssue(v1SwitchSets.map(\.name), kind: "Switches", code: "empty-switch-name", to: &issues)

        validateEntityReferences(
            boards: v1Boards,
            keycapSets: v1KeycapSets,
            artisanSets: v1ArtisanSets,
            switchSets: v1SwitchSets,
            photos: v1Photos,
            boardIDs: boardIDs,
            keycapIDs: keycapIDs,
            artisanIDs: artisanIDs,
            switchIDs: switchIDs,
            photoIDs: photoIDs,
            issues: &issues
        )

        var validatedPhotoBytes: UInt64 = 0
        var photoRecords: [PhotoRecord] = []
        var photoPlans: [MigrationPhotoPlan] = []
        var dimensionMismatchCount = 0
        var mimeMismatchCount = 0

        for photo in v1Photos {
            let id = photo.id ?? ""
            let mimeType = try photoMIMEType(photo.type)
            let expectedPath = "photos/\(id).\(mimeType.fileExtension)"
            guard photo.file == expectedPath, let entry = entriesByPath[expectedPath] else {
                throw V1BackupReaderError.missingPhotoFile(expectedPath)
            }
            guard entry.uncompressedSize <= maximumPhotoBytes else {
                throw V1BackupReaderError.entryTooLarge(expectedPath)
            }
            validatedPhotoBytes += entry.uncompressedSize
            guard validatedPhotoBytes <= maximumPhotoTotalBytes else {
                throw V1BackupReaderError.photoDataTooLarge
            }

            let data = try read(entry: entry, from: archive, maximumBytes: maximumPhotoBytes)
            let imageInfo = try inspectImage(data: data, path: expectedPath)
            if imageInfo.mimeType != mimeType {
                mimeMismatchCount += 1
            }
            if let declaredWidth = photo.width,
               let declaredHeight = photo.height,
               (declaredWidth != imageInfo.width || declaredHeight != imageInfo.height) {
                dimensionMismatchCount += 1
            }

            guard let owner = photoOwner(
                for: photo,
                boardIDs: boardIDs,
                keycapIDs: keycapIDs,
                artisanIDs: artisanIDs,
                switchIDs: switchIDs
            ) else {
                continue
            }

            photoRecords.append(PhotoRecord(
                id: id,
                owner: owner,
                originalName: trimmed(photo.name),
                mimeType: imageInfo.mimeType,
                pixelWidth: imageInfo.width,
                pixelHeight: imageInfo.height,
                addedAt: date(fromMilliseconds: photo.addedAt),
                relativeFileName: "\(id).\(imageInfo.mimeType.fileExtension)"
            ))
            photoPlans.append(MigrationPhotoPlan(
                photoID: id,
                sourceEntryPath: expectedPath,
                destinationRelativeFileName: "\(id).\(imageInfo.mimeType.fileExtension)",
                uncompressedByteCount: Int64(entry.uncompressedSize),
                checksum: entry.checksum
            ))
        }

        addIssue(
            code: "photo-dimension-mismatch",
            severity: .warning,
            message: "Dekodierte Bildabmessungen weichen von V1-Metadaten ab.",
            count: dimensionMismatchCount,
            to: &issues
        )
        addIssue(
            code: "photo-mime-mismatch",
            severity: .warning,
            message: "Der dekodierte Bildtyp weicht von V1 ab und wird anhand der Bilddaten normalisiert.",
            count: mimeMismatchCount,
            to: &issues
        )

        let boards = v1Boards.map(mapBoard)
        let keycapSets = v1KeycapSets.map { mapKeycapSet($0, boardIDs: boardIDs, issues: &issues) }
        let artisanSets = v1ArtisanSets.map { mapArtisanSet($0, boardIDs: boardIDs, issues: &issues) }
        let switchSets = v1SwitchSets.map(mapSwitchSet)
        let switchInstallations = normalizeInstallations(
            boards: v1Boards,
            switchSets: v1SwitchSets,
            boardIDs: boardIDs,
            switchIDs: switchIDs,
            issues: &issues
        )

        let preservedImportWarnings = v1SwitchSets.filter { !($0.importWarnings ?? []).isEmpty }.count
        addIssue(
            code: "preserved-v1-import-warnings",
            severity: .warning,
            message: "V1-Importhinweise werden zur späteren Prüfung erhalten.",
            count: preservedImportWarnings,
            to: &issues
        )

        let metadata = AppMetadata(
            schemaVersion: 1,
            createdAt: date(fromMilliseconds: manifest.meta?.createdAt),
            updatedAt: date(fromMilliseconds: manifest.meta?.updatedAt),
            preferredLanguage: manifest.meta?.language == "en" ? "en" : "de"
        )

        let snapshot = InventorySnapshot(
            metadata: metadata,
            libraryValues: LibraryValues(valuesByKey: manifest.lists ?? [:]),
            boards: boards,
            keycapSets: keycapSets,
            artisanSets: artisanSets,
            switchSets: switchSets,
            switchInstallations: switchInstallations,
            photos: photoRecords
        )

        let report = MigrationDryRunReport(
            sourceKind: .zipBackup,
            sourceFileName: url.lastPathComponent,
            sourceByteCount: sourceByteCount,
            sourceSHA256: sourceSHA256,
            sourceVersion: manifest.meta?.version ?? "unbekannt",
            schemaVersion: schemaVersion,
            counts: snapshot.counts,
            validatedPhotoByteCount: Int64(validatedPhotoBytes),
            inspectedAt: .now,
            issues: issues.sorted {
                if $0.severity != $1.severity { return $0.severity == .error }
                return $0.code < $1.code
            }
        )

        return MigrationDryRunResult(report: report, snapshot: snapshot, photoPlans: photoPlans)
    }

    private static func isAllowedArchivePath(_ path: String) -> Bool {
        if path == "manifest.json" { return true }
        guard path.hasPrefix("photos/"), !path.contains("\\"), !path.contains("..") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "photos" else { return false }
        let filenameParts = components[1].split(separator: ".", omittingEmptySubsequences: false)
        guard filenameParts.count == 2, isValidIdentifier(String(filenameParts[0])) else { return false }
        return ["jpg", "png", "webp", "gif"].contains(String(filenameParts[1]).lowercased())
    }

    private static func read(entry: Entry, from archive: Archive, maximumBytes: UInt64) throws -> Data {
        guard entry.uncompressedSize <= maximumBytes, entry.uncompressedSize <= UInt64(Int.max) else {
            throw V1BackupReaderError.entryTooLarge(entry.path)
        }

        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        let checksum = try archive.extract(entry, skipCRC32: false) { chunk in
            guard result.count <= Int(maximumBytes) - chunk.count else {
                throw V1BackupReaderError.entryTooLarge(entry.path)
            }
            result.append(chunk)
        }
        guard checksum == entry.checksum else {
            throw V1BackupReaderError.checksumMismatch(entry.path)
        }
        return result
    }

    private static func validatedIDs(_ values: [String?], kind: String) throws -> Set<String> {
        var result = Set<String>()
        for value in values {
            let id = trimmed(value)
            guard isValidIdentifier(id) else {
                throw V1BackupReaderError.invalidIdentifier(kind)
            }
            guard result.insert(id).inserted else {
                throw V1BackupReaderError.duplicateIdentifier(kind)
            }
        }
        return result
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    private static func photoMIMEType(_ rawValue: String?) throws -> PhotoMIMEType {
        guard let rawValue, let type = PhotoMIMEType(rawValue: rawValue) else {
            throw V1BackupReaderError.unsupportedPhotoType(rawValue ?? "")
        }
        return type
    }

    private static func inspectImage(data: Data, path: String) throws -> (width: Int, height: Int, mimeType: PhotoMIMEType) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw V1BackupReaderError.invalidPhoto(path)
        }

        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier) else {
            throw V1BackupReaderError.invalidPhoto(path)
        }

        let mimeType: PhotoMIMEType
        if type.conforms(to: .jpeg) {
            mimeType = .jpeg
        } else if type.conforms(to: .png) {
            mimeType = .png
        } else if type.conforms(to: .webP) {
            mimeType = .webP
        } else if type.conforms(to: .gif) {
            mimeType = .gif
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            mimeType = .heic
        } else {
            throw V1BackupReaderError.unsupportedPhotoType(type.preferredMIMEType ?? typeIdentifier)
        }
        return (image.width, image.height, mimeType)
    }

    private static func photoOwner(
        for photo: V1Photo,
        boardIDs: Set<String>,
        keycapIDs: Set<String>,
        artisanIDs: Set<String>,
        switchIDs: Set<String>
    ) -> PhotoOwner? {
        let rawType = trimmed(photo.ownerType).nilIfEmpty ?? "board"
        let ownerID = trimmed(photo.ownerId).nilIfEmpty ?? trimmed(photo.boardId)

        switch rawType {
        case "board" where boardIDs.contains(ownerID):
            return PhotoOwner(type: .board, id: ownerID)
        case "keycapSet" where keycapIDs.contains(ownerID):
            return PhotoOwner(type: .keycapSet, id: ownerID)
        case "artisanSet" where artisanIDs.contains(ownerID):
            return PhotoOwner(type: .artisanSet, id: ownerID)
        case "switchSet" where switchIDs.contains(ownerID):
            return PhotoOwner(type: .switchSet, id: ownerID)
        default:
            return nil
        }
    }

    private static func validateEntityReferences(
        boards: [V1Board],
        keycapSets: [V1KeycapSet],
        artisanSets: [V1ArtisanSet],
        switchSets: [V1SwitchSet],
        photos: [V1Photo],
        boardIDs: Set<String>,
        keycapIDs: Set<String>,
        artisanIDs: Set<String>,
        switchIDs: Set<String>,
        photoIDs: Set<String>,
        issues: inout [MigrationIssue]
    ) {
        let allOwners: [(PhotoOwnerType, String, [String], String?)] =
            boards.map { (.board, trimmed($0.id), $0.photoIds ?? [], $0.mainPhotoId) } +
            keycapSets.map { (.keycapSet, trimmed($0.id), $0.photoIds ?? [], $0.mainPhotoId) } +
            artisanSets.map { (.artisanSet, trimmed($0.id), $0.photoIds ?? [], $0.mainPhotoId) } +
            switchSets.map { (.switchSet, trimmed($0.id), $0.photoIds ?? [], $0.mainPhotoId) }

        let missingPhotoReferences = allOwners.reduce(0) { partial, owner in
            partial + owner.2.filter { !photoIDs.contains($0) }.count
        }
        addIssue(
            code: "missing-photo-reference",
            severity: .error,
            message: "Inventareinträge referenzieren nicht vorhandene Fotos.",
            count: missingPhotoReferences,
            to: &issues
        )

        let invalidMainPhotos = allOwners.filter { owner in
            guard let mainPhotoID = owner.3, !mainPhotoID.isEmpty else { return false }
            return !owner.2.contains(mainPhotoID)
        }.count
        addIssue(
            code: "invalid-main-photo",
            severity: .error,
            message: "Hauptfotos gehören nicht zur Fotoliste ihres Eintrags.",
            count: invalidMainPhotos,
            to: &issues
        )

        let missingKeycapLinks = boards.filter {
            let id = trimmed($0.keycapSetId)
            return !id.isEmpty && !keycapIDs.contains(id)
        }.count
        addIssue(
            code: "missing-keycap-link",
            severity: .error,
            message: "Boards referenzieren nicht vorhandene Keycap-Sets.",
            count: missingKeycapLinks,
            to: &issues
        )

        let missingSwitchLinks = boards.reduce(0) { partial, board in
            partial + normalizedSwitchIDs(board).filter { !switchIDs.contains($0) }.count
        }
        addIssue(
            code: "missing-switch-link",
            severity: .error,
            message: "Boards referenzieren nicht vorhandene Switch-Sets.",
            count: missingSwitchLinks,
            to: &issues
        )

        let missingMountedBoards = keycapSets.compactMap(\.mountedBoardId).filter {
            !$0.isEmpty && !boardIDs.contains($0)
        }.count + artisanSets.compactMap(\.mountedBoardId).filter {
            !$0.isEmpty && !boardIDs.contains($0)
        }.count
        addIssue(
            code: "missing-mounted-board",
            severity: .error,
            message: "Komponenten referenzieren nicht vorhandene Boards.",
            count: missingMountedBoards,
            to: &issues
        )

        let invalidPhotoOwners = photos.filter {
            photoOwner(for: $0, boardIDs: boardIDs, keycapIDs: keycapIDs, artisanIDs: artisanIDs, switchIDs: switchIDs) == nil
        }.count
        addIssue(
            code: "invalid-photo-owner",
            severity: .error,
            message: "Fotos besitzen keinen gültigen Inventar-Eigentümer.",
            count: invalidPhotoOwners,
            to: &issues
        )
    }

    private static func mapBoard(_ value: V1Board) -> Board {
        Board(
            id: trimmed(value.id),
            name: trimmed(value.name),
            manufacturer: trimmed(value.manufacturer),
            format: trimmed(value.format),
            color: trimmed(value.color),
            weightMaterial: trimmed(value.weightMaterial),
            status: BoardStatus(rawValue: trimmed(value.status)) ?? .owned,
            purchasePrice: value.purchasePrice,
            purchaseDate: value.purchaseDate.map { Date(timeIntervalSince1970: $0 / 1_000) },
            purchaseShop: trimmed(value.purchaseShop),
            mounting: trimmed(value.mounting),
            caseMaterial: trimmed(value.caseMaterial),
            layout: trimmed(value.layout),
            typingAngle: trimmed(value.typingAngle),
            weightGrams: value.weightGrams,
            plate: trimmed(value.plate),
            pcb: trimmed(value.pcb),
            stabilizers: trimmed(value.stabs),
            remark: trimmed(value.remark),
            legacyKeycapsName: trimmed(value.keycaps),
            keycapSetID: trimmed(value.keycapSetId).nilIfEmpty,
            legacySwitchesName: trimmed(value.switches),
            photoIDs: value.photoIds ?? [],
            mainPhotoID: trimmed(value.mainPhotoId).nilIfEmpty,
            createdAt: date(fromMilliseconds: value.createdAt),
            updatedAt: date(fromMilliseconds: value.updatedAt)
        )
    }

    private static func mapKeycapSet(
        _ value: V1KeycapSet,
        boardIDs: Set<String>,
        issues: inout [MigrationIssue]
    ) -> KeycapSet {
        let sourceURL = safeHTTPS(value.sourceUrl, issues: &issues)
        let coverURL = safeHTTPS(value.coverUrl, issues: &issues)
        let externalURLs = (value.externalImageUrls ?? []).compactMap { safeHTTPS($0, issues: &issues).nilIfEmpty }
        let mountedBoardID = trimmed(value.mountedBoardId)

        return KeycapSet(
            id: trimmed(value.id),
            name: trimmed(value.name),
            manufacturer: trimmed(value.manufacturer),
            profile: trimmed(value.profile),
            material: trimmed(value.material),
            status: trimmed(value.status).nilIfEmpty ?? "owned",
            kits: value.kits ?? [],
            sourceURL: sourceURL,
            sourceShop: trimmed(value.sourceShop),
            mountedBoardID: boardIDs.contains(mountedBoardID) ? mountedBoardID : nil,
            notes: value.notes ?? "",
            photoIDs: value.photoIds ?? [],
            mainPhotoID: trimmed(value.mainPhotoId).nilIfEmpty,
            coverURL: coverURL,
            externalImageURLs: externalURLs,
            trelloCardID: trimmed(value.trelloCardId),
            trelloListName: trimmed(value.trelloListName),
            createdAt: date(fromMilliseconds: value.createdAt),
            updatedAt: date(fromMilliseconds: value.updatedAt)
        )
    }

    private static func mapArtisanSet(
        _ value: V1ArtisanSet,
        boardIDs: Set<String>,
        issues: inout [MigrationIssue]
    ) -> ArtisanSet {
        let sourceURL = safeHTTPS(value.sourceUrl, issues: &issues)
        let coverURL = safeHTTPS(value.coverUrl, issues: &issues)
        let externalURLs = (value.externalImageUrls ?? []).compactMap { safeHTTPS($0, issues: &issues).nilIfEmpty }
        let mountedBoardID = trimmed(value.mountedBoardId)

        return ArtisanSet(
            id: trimmed(value.id),
            name: trimmed(value.name),
            manufacturer: trimmed(value.manufacturer),
            profile: trimmed(value.profile),
            material: trimmed(value.material),
            status: trimmed(value.status).nilIfEmpty ?? "owned",
            tags: value.tags ?? [],
            sourceURL: sourceURL,
            sourceShop: trimmed(value.sourceShop),
            mountedBoardID: boardIDs.contains(mountedBoardID) ? mountedBoardID : nil,
            notes: value.notes ?? "",
            photoIDs: value.photoIds ?? [],
            mainPhotoID: trimmed(value.mainPhotoId).nilIfEmpty,
            coverURL: coverURL,
            externalImageURLs: externalURLs,
            trelloCardID: trimmed(value.trelloCardId),
            trelloListName: trimmed(value.trelloListName),
            createdAt: date(fromMilliseconds: value.createdAt),
            updatedAt: date(fromMilliseconds: value.updatedAt)
        )
    }

    private static func mapSwitchSet(_ value: V1SwitchSet) -> SwitchSet {
        SwitchSet(
            id: trimmed(value.id),
            name: trimmed(value.name),
            switchType: trimmed(value.switchType),
            topHousingMaterial: trimmed(value.topHousingMaterial),
            bottomHousingMaterial: trimmed(value.bottomHousingMaterial),
            stemMaterial: trimmed(value.stemMaterial),
            springLength: trimmed(value.springLength),
            springType: trimmed(value.springType),
            preTravel: trimmed(value.preTravel),
            totalTravel: trimmed(value.totalTravel),
            operatingForce: trimmed(value.operatingForce),
            bottomOutForce: trimmed(value.bottomOutForce),
            pins: SwitchPins(rawValue: trimmed(value.pins).uppercased()) ?? .five,
            hasLEDDiffuser: value.ledDiffuser ?? false,
            isFactoryLubed: value.factoryLubed ?? false,
            quantity: max(value.quantity ?? 0, 0),
            importedBoardText: trimmed(value.importedBoardText),
            importedBoardAllocations: (value.importedBoardAllocations ?? []).map {
                ImportedBoardAllocation(
                    boardName: trimmed($0.board),
                    quantity: max($0.quantity ?? 0, 0),
                    inferred: $0.inferred ?? false
                )
            },
            importSource: trimmed(value.importSource),
            importRow: max(value.importRow ?? 0, 0),
            importKey: trimmed(value.importKey),
            importWarnings: value.importWarnings ?? [],
            notes: value.notes ?? "",
            photoIDs: value.photoIds ?? [],
            mainPhotoID: trimmed(value.mainPhotoId).nilIfEmpty,
            createdAt: date(fromMilliseconds: value.createdAt),
            updatedAt: date(fromMilliseconds: value.updatedAt)
        )
    }

    private static func normalizeInstallations(
        boards: [V1Board],
        switchSets: [V1SwitchSet],
        boardIDs: Set<String>,
        switchIDs: Set<String>,
        issues: inout [MigrationIssue]
    ) -> [SwitchInstallation] {
        var installations: [String: SwitchInstallation] = [:]
        var explicitPairs = Set<String>()
        var duplicatePairs = 0

        for switchSet in switchSets {
            let switchID = trimmed(switchSet.id)
            var sourceInstallations = switchSet.installations ?? []
            let legacyBoardID = trimmed(switchSet.mountedBoardId)
            if !legacyBoardID.isEmpty,
               !sourceInstallations.contains(where: { trimmed($0.boardId) == legacyBoardID }) {
                sourceInstallations.append(V1SwitchInstallation(
                    boardId: legacyBoardID,
                    quantity: switchSet.mountedQuantity
                ))
            }

            for source in sourceInstallations {
                let boardID = trimmed(source.boardId)
                guard boardIDs.contains(boardID), switchIDs.contains(switchID) else { continue }
                let key = installationKey(switchID: switchID, boardID: boardID)
                let candidate = SwitchInstallation(
                    switchSetID: switchID,
                    boardID: boardID,
                    quantity: source.quantity ?? 0
                )
                if let existing = installations[key] {
                    duplicatePairs += 1
                    installations[key] = SwitchInstallation(
                        switchSetID: switchID,
                        boardID: boardID,
                        quantity: max(existing.quantity, candidate.quantity)
                    )
                } else {
                    installations[key] = candidate
                }
                explicitPairs.insert(key)
            }
        }

        var boardLinkPairs = Set<String>()
        var quantityConflicts = 0
        for board in boards {
            let boardID = trimmed(board.id)
            for switchID in normalizedSwitchIDs(board) where switchIDs.contains(switchID) {
                let key = installationKey(switchID: switchID, boardID: boardID)
                boardLinkPairs.insert(key)
                let boardQuantity = max(board.switchSetQuantities?[switchID] ?? 0, 0)
                if let existing = installations[key] {
                    if board.switchSetQuantities?[switchID] != nil, existing.quantity != boardQuantity {
                        quantityConflicts += 1
                    }
                } else {
                    installations[key] = SwitchInstallation(
                        switchSetID: switchID,
                        boardID: boardID,
                        quantity: boardQuantity
                    )
                }
            }
        }

        let oneSidedExplicitLinks = explicitPairs.subtracting(boardLinkPairs).count
        addIssue(
            code: "one-sided-switch-installation",
            severity: .warning,
            message: "Switch-Installationen werden als kanonische Beziehung übernommen, obwohl die Board-Rückseite fehlt.",
            count: oneSidedExplicitLinks,
            to: &issues
        )
        addIssue(
            code: "duplicate-switch-installation",
            severity: .warning,
            message: "Doppelte Switch-/Board-Installationen wurden zusammengeführt.",
            count: duplicatePairs,
            to: &issues
        )
        addIssue(
            code: "switch-quantity-conflict",
            severity: .warning,
            message: "Explizite Switch-Installationen gewinnen bei widersprüchlichen Board-Mengen.",
            count: quantityConflicts,
            to: &issues
        )

        return installations.values.sorted {
            if $0.switchSetID != $1.switchSetID { return $0.switchSetID < $1.switchSetID }
            return $0.boardID < $1.boardID
        }
    }

    private static func normalizedSwitchIDs(_ board: V1Board) -> [String] {
        var result: [String] = []
        for id in board.switchSetIds ?? [] where !id.isEmpty && !result.contains(id) {
            result.append(id)
        }
        let legacyID = trimmed(board.switchSetId)
        if !legacyID.isEmpty, !result.contains(legacyID) {
            result.insert(legacyID, at: 0)
        }
        return result
    }

    private static func installationKey(switchID: String, boardID: String) -> String {
        "\(switchID)::\(boardID)"
    }

    private static func safeHTTPS(_ rawValue: String?, issues: inout [MigrationIssue]) -> String {
        let value = trimmed(rawValue)
        guard !value.isEmpty else { return "" }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            addIssue(
                code: "unsafe-external-url",
                severity: .warning,
                message: "Nicht-HTTPS- oder ungültige externe URLs werden nicht übernommen.",
                count: 1,
                to: &issues
            )
            return ""
        }
        return url.absoluteString
    }

    private static func addEmptyNameIssue(
        _ values: [String?],
        kind: String,
        code: String,
        to issues: inout [MigrationIssue]
    ) {
        addIssue(
            code: code,
            severity: .error,
            message: "\(kind) ohne Namen können nicht importiert werden.",
            count: values.filter { trimmed($0).isEmpty }.count,
            to: &issues
        )
    }

    private static func addIssue(
        code: String,
        severity: MigrationIssueSeverity,
        message: String,
        count: Int,
        to issues: inout [MigrationIssue]
    ) {
        guard count > 0 else { return }
        if let index = issues.firstIndex(where: { $0.code == code && $0.severity == severity }) {
            issues[index].affectedItems += count
        } else {
            issues.append(MigrationIssue(
                code: code,
                severity: severity,
                message: message,
                affectedItems: count
            ))
        }
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(fromMilliseconds value: Double?) -> Date {
        guard let value, value.isFinite, value > 0 else {
            return Date(timeIntervalSince1970: 0)
        }
        return Date(timeIntervalSince1970: value / 1_000)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct V1LegacyJSONReader: Sendable {
    private static let maximumSourceBytes: Int64 = 500 * 1_024 * 1_024
    private static let maximumPhotoBytes = 30 * 1_024 * 1_024
    private static let maximumPhotoTotalBytes = 500 * 1_024 * 1_024
    private static let maximumItemsPerKind = 10_000
    private static let maximumPhotos = 50_000

    func inspect(at url: URL) async throws -> MigrationDryRunResult {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerLegacy-\(UUID().uuidString)", isDirectory: true)
        let canonicalArchiveURL = temporaryDirectoryURL.appendingPathComponent("Canonical.zip")
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        return try await prepareInspection(
            at: url,
            canonicalArchiveURL: canonicalArchiveURL
        )
    }

    func prepareInspection(
        at sourceURL: URL,
        canonicalArchiveURL: URL
    ) async throws -> MigrationDryRunResult {
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try Self.createCanonicalArchive(
                from: sourceURL,
                at: canonicalArchiveURL
            )
        }.value
        var result = try await V1BackupReader().inspect(at: canonicalArchiveURL)
        result.report.sourceKind = .legacyJSON
        result.report.sourceFileName = sourceURL.lastPathComponent
        result.report.sourceByteCount = descriptor.sourceByteCount
        result.report.sourceSHA256 = descriptor.sourceSHA256
        result.report.sourceVersion = descriptor.sourceVersion
        result.report.schemaVersion = descriptor.schemaVersion
        result.report.issues.append(MigrationIssue(
            code: "legacy-json-source",
            severity: .warning,
            message: "Eingebettete Legacy-Fotos werden vor dem Import in getrennte, geprüfte Dateien überführt.",
            affectedItems: 1
        ))
        result.report.issues.sort {
            if $0.severity != $1.severity { return $0.severity == .error }
            return $0.code < $1.code
        }
        return result
    }

    private struct SourceDescriptor: Sendable {
        var sourceByteCount: Int64
        var sourceSHA256: String
        var sourceVersion: String
        var schemaVersion: Int
    }

    private static func createCanonicalArchive(
        from sourceURL: URL,
        at archiveURL: URL
    ) throws -> SourceDescriptor {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw V1BackupReaderError.notARegularFile
        }
        let sourceByteCount = Int64(values.fileSize ?? 0)
        guard sourceByteCount > 0, sourceByteCount <= maximumSourceBytes else {
            throw V1BackupReaderError.archiveTooLarge
        }

        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard var root = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              root["boards"] is [Any],
              root["lists"] is [String: Any] else {
            throw V1BackupReaderError.invalidLegacyJSON
        }

        let originalSchema = (root["schemaVersion"] as? NSNumber)?.intValue ?? 0
        guard (0...2).contains(originalSchema) else {
            throw V1BackupReaderError.unsupportedLegacySchema(originalSchema)
        }

        let collectionKeys = ["boards", "keycapSets", "artisanSets", "switchSets"]
        for key in collectionKeys {
            let count = (root[key] as? [Any])?.count ?? 0
            guard count <= maximumItemsPerKind else {
                throw V1BackupReaderError.tooManyEntries
            }
            if root[key] == nil {
                root[key] = []
            }
        }

        let sourcePhotos = root["photos"] as? [[String: Any]] ?? []
        guard sourcePhotos.count <= maximumPhotos else {
            throw V1BackupReaderError.tooManyEntries
        }

        var canonicalPhotos: [[String: Any]] = []
        var photoPayloads: [(path: String, data: Data)] = []
        var totalPhotoBytes = 0
        canonicalPhotos.reserveCapacity(sourcePhotos.count)
        photoPayloads.reserveCapacity(sourcePhotos.count)

        for var photo in sourcePhotos {
            guard let photoID = photo["id"] as? String,
                  isValidIdentifier(photoID),
                  let dataURL = photo["dataUrl"] as? String,
                  let payload = decodedPhotoDataURL(dataURL) else {
                throw V1BackupReaderError.invalidLegacyPhoto(
                    (photo["id"] as? String) ?? "unbekannt"
                )
            }
            guard payload.data.count <= maximumPhotoBytes else {
                throw V1BackupReaderError.invalidLegacyPhoto(photoID)
            }
            totalPhotoBytes += payload.data.count
            guard totalPhotoBytes <= maximumPhotoTotalBytes else {
                throw V1BackupReaderError.photoDataTooLarge
            }

            let declaredType = (photo["type"] as? String) ?? payload.mimeType.rawValue
            guard declaredType == payload.mimeType.rawValue else {
                throw V1BackupReaderError.invalidLegacyPhoto(photoID)
            }
            let path = "photos/\(photoID).\(payload.mimeType.fileExtension)"
            photo["type"] = payload.mimeType.rawValue
            photo["file"] = path
            photo.removeValue(forKey: "dataUrl")
            canonicalPhotos.append(photo)
            photoPayloads.append((path, payload.data))
        }

        root["schemaVersion"] = 6
        root["format"] = "keyboard-manager-zip"
        root["photos"] = canonicalPhotos
        let manifestData: Data
        do {
            manifestData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw V1BackupReaderError.invalidLegacyJSON
        }

        guard manifestData.count <= 10 * 1_024 * 1_024 else {
            throw V1BackupReaderError.manifestTooLarge
        }
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add(manifestData, at: "manifest.json", to: archive)
        for payload in photoPayloads {
            try add(payload.data, at: payload.path, to: archive)
        }

        let meta = root["meta"] as? [String: Any]
        return SourceDescriptor(
            sourceByteCount: sourceByteCount,
            sourceSHA256: try sha256(of: sourceURL),
            sourceVersion: (meta?["version"] as? String) ?? "legacy",
            schemaVersion: originalSchema
        )
    }

    private static func decodedPhotoDataURL(
        _ value: String
    ) -> (mimeType: PhotoMIMEType, data: Data)? {
        guard value.hasPrefix("data:"),
              let separatorRange = value.range(of: ";base64,") else {
            return nil
        }
        let mimeStart = value.index(value.startIndex, offsetBy: 5)
        let rawMIME = String(value[mimeStart..<separatorRange.lowerBound])
        guard let mimeType = PhotoMIMEType(rawValue: rawMIME),
              mimeType != .heic,
              let data = Data(
                base64Encoded: String(value[separatorRange.upperBound...]),
                options: []
              ),
              !data.isEmpty else {
            return nil
        }
        return (mimeType, data)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    private static func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
