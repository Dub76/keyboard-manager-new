import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import KeyboardManager

final class BackupExportServiceTests: XCTestCase {
    func testExportIsReadableAndPreservesManagedPhoto() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("roundtrip.zip")
        let before = try Data(contentsOf: fixture.photoURL)

        let result = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)
        let after = try Data(contentsOf: fixture.photoURL)

        XCTAssertEqual(before, after, "Der Export darf das verwaltete Originalfoto nicht verändern.")
        XCTAssertEqual(result.destinationURL, destination)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertEqual(result.counts, fixture.snapshot.counts)
        XCTAssertEqual(result.transcodedHEICPhotoCount, 0)
        XCTAssertEqual(inspected.report.schemaVersion, 6)
        XCTAssertEqual(inspected.report.sourceVersion, "0.1.0-test")
        XCTAssertEqual(inspected.report.errorCount, 0, "Issues: \(inspected.report.issues)")
        XCTAssertEqual(inspected.snapshot.boards.first?.keycapSetID, "keycap_1")
        XCTAssertEqual(
            inspected.snapshot.switchInstallations,
            [SwitchInstallation(switchSetID: "switch_1", boardID: "board_1", quantity: 70)]
        )
        XCTAssertEqual(
            inspected.snapshot.photos.first?.owner,
            PhotoOwner(type: .board, id: "board_1")
        )
    }

    func testSameSnapshotAndTimestampProduceByteIdenticalArchives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstURL = fixture.directory.appendingPathComponent("first.zip")
        let secondURL = fixture.directory.appendingPathComponent("second.zip")

        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: firstURL,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: secondURL,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )

        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
    }

    func testMissingPhotoFailsWithoutInstallingDestination() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.photoURL)
        let destination = fixture.directory.appendingPathComponent("missing.zip")

        do {
            _ = try await fixture.service.export(
                snapshot: fixture.snapshot,
                to: destination,
                exportedAt: fixture.exportedAt,
                appVersion: "0.1.0-test"
            )
            XCTFail("Ein Backup mit fehlendem verwaltetem Foto darf nicht installiert werden.")
        } catch let error as BackupExportError {
            guard case .missingPhoto = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExistingDestinationIsReplacedWithValidatedArchive() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("replace.zip")
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "first"
        )
        fixture.snapshot.boards[0].name = "Ersetztes Board"

        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt.addingTimeInterval(2),
            appVersion: "second"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)

        XCTAssertEqual(inspected.report.sourceVersion, "second")
        XCTAssertEqual(inspected.snapshot.boards.first?.name, "Ersetztes Board")
    }

    func testManifestUsesV1SchemaSixPhotoLayout() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("manifest.zip")
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )

        let archive = try Archive(url: destination, accessMode: .read)
        let paths = Array(archive).map(\.path)
        XCTAssertEqual(paths, ["photos/photo_1.png", "manifest.json"])
        let manifestEntry = try XCTUnwrap(archive["manifest.json"])
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let photos = try XCTUnwrap(object["photos"] as? [[String: Any]])

        XCTAssertEqual(object["schemaVersion"] as? Int, 6)
        XCTAssertEqual(object["format"] as? String, "keyboard-manager-zip")
        XCTAssertEqual(photos.first?["file"] as? String, "photos/photo_1.png")
        XCTAssertEqual(photos.first?["ownerType"] as? String, "board")
    }

    func testHEICIsExportedAsJPEGWithoutChangingManagedOriginal() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let heicData = try makeHEICData()
        let heicURL = fixture.photoURL.deletingLastPathComponent()
            .appendingPathComponent("photo_1.heic")
        try FileManager.default.removeItem(at: fixture.photoURL)
        try heicData.write(to: heicURL)
        fixture.photoURL = heicURL
        fixture.snapshot.photos[0].mimeType = .heic
        fixture.snapshot.photos[0].relativeFileName = "photo_1.heic"
        fixture.snapshot.photos[0].originalName = "original.heic"
        let before = try Data(contentsOf: heicURL)
        let destination = fixture.directory.appendingPathComponent("heic.zip")

        let result = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)

        XCTAssertEqual(result.transcodedHEICPhotoCount, 1)
        XCTAssertEqual(try Data(contentsOf: heicURL), before)
        XCTAssertEqual(inspected.snapshot.photos.first?.mimeType, .jpeg)
        XCTAssertEqual(inspected.snapshot.photos.first?.relativeFileName, "photo_1.jpg")
    }

    func testBackupKeepsBoardColorAndOmitsEmptyColor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var colored = fixture.snapshot
        colored.boards[0].color = "Navy"
        colored.boards[0].weightMaterial = "Messing"
        let coloredURL = fixture.directory.appendingPathComponent("colored.zip")
        let plainURL = fixture.directory.appendingPathComponent("plain.zip")

        _ = try await fixture.service.export(snapshot: colored, to: coloredURL, exportedAt: fixture.exportedAt, appVersion: "test")
        _ = try await fixture.service.export(snapshot: fixture.snapshot, to: plainURL, exportedAt: fixture.exportedAt, appVersion: "test")

        let restored = try await V1BackupReader().inspect(at: coloredURL)
        XCTAssertEqual(restored.snapshot.boards.first?.color, "Navy")
        XCTAssertEqual(restored.snapshot.boards.first?.weightMaterial, "Messing")

        let archive = try Archive(url: plainURL, accessMode: .read)
        let manifestEntry = try XCTUnwrap(archive["manifest.json"])
        var manifest = Data()
        _ = try archive.extract(manifestEntry) { manifest.append($0) }
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("\"color\""))
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("\"weightMaterial\""))
    }

    func testAutomaticBackupRunsDailyOnlyOnChangesAndKeepsNewest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let directory = fixture.directory.appendingPathComponent("Automatic", isDirectory: true)
        let service = AutomaticBackupService(
            directoryURL: directory,
            exporter: fixture.service,
            retainedCount: 3
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreignFile = directory.appendingPathComponent("keyboard-manager-backup.zip")
        try Data("manual".utf8).write(to: foreignFile)

        func snapshot(named name: String) -> InventorySnapshot {
            var snapshot = fixture.snapshot
            snapshot.boards[0].name = name
            return snapshot
        }
        let start = fixture.exportedAt
        let day: TimeInterval = 24 * 60 * 60

        let first = try await service.backUpIfDue(snapshot: snapshot(named: "A"), appVersion: "test", now: start)
        guard case .created = first else { return XCTFail("Expected first backup, got \(first)") }

        let unchanged = try await service.backUpIfDue(snapshot: snapshot(named: "A"), appVersion: "test", now: start + 3 * day)
        guard case .skippedUnchanged = unchanged else { return XCTFail("Expected unchanged skip, got \(unchanged)") }

        let recent = try await service.backUpIfDue(snapshot: snapshot(named: "B"), appVersion: "test", now: start + 3_600)
        guard case .skippedRecent = recent else { return XCTFail("Expected recent skip, got \(recent)") }

        for index in 1...4 {
            let outcome = try await service.backUpIfDue(
                snapshot: snapshot(named: "Day \(index)"),
                appVersion: "test",
                now: start + Double(index) * day + 60
            )
            guard case .created = outcome else { return XCTFail("Expected backup on day \(index), got \(outcome)") }
        }

        let entries = await service.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.createdAt, start + 4 * day + 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignFile.path), "Fremde Dateien dürfen nie gelöscht werden.")

        let forced = try await service.backUpIfDue(
            snapshot: snapshot(named: "Day 4"),
            appVersion: "test",
            now: start + 4 * day + 120,
            force: true
        )
        guard case .created = forced else { return XCTFail("Expected forced backup, got \(forced)") }
    }

    func testBackupMirrorCopiesCatchesUpAndPrunesOnlyItsOwnFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mirror = fixture.directory.appendingPathComponent("Mirror", isDirectory: true)
        let service = AutomaticBackupService(
            directoryURL: fixture.directory.appendingPathComponent("Automatic", isDirectory: true),
            exporter: fixture.service,
            retainedCount: 2
        )
        func snapshot(named name: String) -> InventorySnapshot {
            var snapshot = fixture.snapshot
            snapshot.boards[0].name = name
            return snapshot
        }
        let day: TimeInterval = 24 * 60 * 60
        _ = try await service.backUpIfDue(snapshot: snapshot(named: "A"), appVersion: "test", now: fixture.exportedAt)

        do {
            try await service.syncMirror(to: mirror)
            XCTFail("A missing folder must be reported, not created")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                BackupExportError.mirrorUnavailable(mirror.standardizedFileURL.path).localizedDescription
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.path))

        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let foreign = mirror.appendingPathComponent("Urlaubsfoto.zip")
        try Data("x".utf8).write(to: foreign)

        var copied = try await service.syncMirror(to: mirror)
        XCTAssertEqual(copied, 1)
        copied = try await service.syncMirror(to: mirror)
        XCTAssertEqual(copied, 0)

        for index in 1...2 {
            _ = try await service.backUpIfDue(
                snapshot: snapshot(named: "Tag \(index)"),
                appVersion: "test",
                now: fixture.exportedAt + Double(index) * day + 60
            )
        }
        copied = try await service.syncMirror(to: mirror)
        XCTAssertEqual(copied, 2)

        let local = await service.entries().map(\.url.lastPathComponent)
        let mirrored = try FileManager.default.contentsOfDirectory(atPath: mirror.path)
        XCTAssertEqual(Set(mirrored), Set(local + ["Urlaubsfoto.zip"]))
        XCTAssertEqual(local.count, 2)
    }

    func testAutomaticBackupIsRestorableThroughMigrationReader() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = AutomaticBackupService(
            directoryURL: fixture.directory.appendingPathComponent("Automatic", isDirectory: true),
            exporter: fixture.service
        )

        let outcome = try await service.backUpIfDue(
            snapshot: fixture.snapshot,
            appVersion: "0.1.0-test",
            now: fixture.exportedAt
        )
        guard case let .created(entry) = outcome else { return XCTFail("Expected backup, got \(outcome)") }

        let inspected = try await V1BackupReader().inspect(at: entry.url)
        XCTAssertEqual(inspected.report.errorCount, 0, "Issues: \(inspected.report.issues)")
        XCTAssertEqual(inspected.snapshot.boards.map(\.name), fixture.snapshot.boards.map(\.name))
        XCTAssertEqual(inspected.snapshot.photos.count, fixture.snapshot.photos.count)
    }

    func testAutomaticBackupSkipsEmptyInventoryWithoutCreatingFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerAutoBackupEmpty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AutomaticBackupService(directoryURL: directory)

        let outcome = try await service.backUpIfDue(snapshot: .empty, appVersion: "test", force: true)

        XCTAssertEqual(outcome, .skippedEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPhotoImportRemovesLocationButKeepsOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerGPSImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (type, ext) in [(UTType.jpeg, "jpg"), (UTType.png, "png"), (UTType.heic, "heic")] {
            let source = try makeImageWithLocation(type: type)
            XCTAssertTrue(PhotoMetadataSanitizer.containsLocation(source), "Fixture \(ext) needs GPS")
            let url = directory.appendingPathComponent("located.\(ext)")
            try source.write(to: url)

            let service = PhotoImportService(
                layout: MigrationStorageLayout(rootURL: directory.appendingPathComponent("AppData-\(ext)"))
            )
            let prepared = try await service.prepare(
                urls: [url],
                owner: PhotoOwner(type: .board, id: "board_1")
            )

            let data = try XCTUnwrap(prepared.first?.data)
            XCTAssertFalse(PhotoMetadataSanitizer.containsLocation(data), "\(ext) still has GPS")
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            if prepared.first?.record.mimeType.fileExtension == ext {
                XCTAssertEqual(
                    (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
                    6,
                    "\(ext) lost its orientation"
                )
            }
        }
    }

    func testBackupRemovesLocationFromStoredPhotos() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let located = try makeImageWithLocation(type: .png)
        try located.write(to: fixture.photoURL)
        let destination = fixture.directory.appendingPathComponent("located.zip")

        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "test"
        )

        let archive = try Archive(url: destination, accessMode: .read)
        let entry = try XCTUnwrap(archive.first { $0.path.hasPrefix("photos/") })
        var archived = Data()
        _ = try archive.extract(entry) { archived.append($0) }
        XCTAssertFalse(PhotoMetadataSanitizer.containsLocation(archived))
        XCTAssertEqual(try Data(contentsOf: fixture.photoURL), located, "Das Original bleibt unverändert.")
    }

    private func makeImageWithLocation(type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 6,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.137,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 11.575,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeFixture() throws -> (
        directory: URL,
        photoURL: URL,
        service: BackupExportService,
        snapshot: InventorySnapshot,
        exportedAt: Date
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerBackupTests-\(UUID().uuidString)", isDirectory: true)
        let layout = MigrationStorageLayout(rootURL: directory.appendingPathComponent("AppData"))
        try FileManager.default.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let photoURL = layout.currentPhotosDirectoryURL.appendingPathComponent("photo_1.png")
        try imageData.write(to: photoURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let board = Board(
            id: "board_1",
            name: "Testboard",
            manufacturer: "Test",
            format: "65%",
            keycapSetID: "keycap_1",
            photoIDs: ["photo_1"],
            mainPhotoID: "photo_1",
            createdAt: date,
            updatedAt: date
        )
        let snapshot = InventorySnapshot(
            metadata: AppMetadata(
                schemaVersion: 1,
                createdAt: date,
                updatedAt: date,
                preferredLanguage: "de"
            ),
            libraryValues: LibraryValues(valuesByKey: ["formats": ["65%"]]),
            boards: [board],
            keycapSets: [
                KeycapSet(
                    id: "keycap_1",
                    name: "Testcaps",
                    mountedBoardID: "board_1",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            artisanSets: [],
            switchSets: [
                SwitchSet(
                    id: "switch_1",
                    name: "Testswitch",
                    switchType: "Linear",
                    quantity: 90,
                    createdAt: date,
                    updatedAt: date
                )
            ],
            switchInstallations: [
                SwitchInstallation(switchSetID: "switch_1", boardID: "board_1", quantity: 70)
            ],
            photos: [
                PhotoRecord(
                    id: "photo_1",
                    owner: PhotoOwner(type: .board, id: "board_1"),
                    originalName: "pixel.png",
                    mimeType: .png,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    addedAt: date,
                    relativeFileName: "photo_1.png"
                )
            ]
        )
        return (
            directory,
            photoURL,
            BackupExportService(layout: layout),
            snapshot,
            date
        )
    }

    private func makeHEICData() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Testbild konnte nicht erzeugt werden.")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else {
            throw XCTSkip("Testbild konnte nicht gerendert werden.")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("HEIC-Encoding ist auf diesem System nicht verfügbar.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("HEIC-Testbild konnte nicht kodiert werden.")
        }
        return data as Data
    }
}
