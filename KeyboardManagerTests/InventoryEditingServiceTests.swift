import Foundation
import XCTest
@testable import KeyboardManager

final class InventoryEditingServiceTests: XCTestCase {
    private let service = InventoryEditingService()

    func testBoardSaveSynchronizesKeycapAndSwitchRelationships() throws {
        let board = Board(id: "board-1", name: "Board")
        let otherBoard = Board(id: "board-2", name: "Other", keycapSetID: "keycap-1")
        let keycap = KeycapSet(id: "keycap-1", name: "Caps", mountedBoardID: "board-2")
        let switches = SwitchSet(id: "switch-1", name: "Switches", quantity: 100)
        var source = InventorySnapshot.empty
        source.boards = [board, otherBoard]
        source.keycapSets = [keycap]
        source.switchSets = [switches]

        var draft = InventoryDraft(board: board, installations: [])
        draft.keycapSetID = keycap.id
        draft.installations[switches.id] = 70

        let result = try service.saving(draft, newPhotos: [], in: source)

        XCTAssertEqual(result.snapshot.boards.first(where: { $0.id == board.id })?.keycapSetID, keycap.id)
        XCTAssertNil(result.snapshot.boards.first(where: { $0.id == otherBoard.id })?.keycapSetID)
        XCTAssertEqual(result.snapshot.keycapSets.first?.mountedBoardID, board.id)
        XCTAssertEqual(
            result.snapshot.switchInstallations,
            [SwitchInstallation(switchSetID: switches.id, boardID: board.id, quantity: 70)]
        )
    }

    private func legacyRelationshipFixture() -> InventorySnapshot {
        var source = InventorySnapshot.empty
        source.boards = [
            Board(id: "board", name: "Board", legacyKeycapsName: "Old caps",
                  keycapSetID: "caps", legacySwitchesName: "Old switches"),
            Board(id: "other", name: "Other", legacyKeycapsName: "Import caps",
                  legacySwitchesName: "Import switches")
        ]
        source.keycapSets = [KeycapSet(id: "caps", name: "Current caps", mountedBoardID: "board")]
        source.switchSets = [SwitchSet(id: "switches", name: "Current switches", quantity: 100)]
        source.switchInstallations = [SwitchInstallation(switchSetID: "switches", boardID: "board", quantity: 60)]
        return source
    }

    func testClearingImportWarningsLogsThemInNotes() throws {
        var source = InventorySnapshot.empty
        source.switchSets = [
            SwitchSet(
                id: "switch-1",
                name: "Switches",
                quantity: 10,
                importWarnings: ["Board „Alt“ nicht gefunden", "Menge geschätzt"],
                notes: "Gekauft 2024"
            )
        ]
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try InventoryEditingService().clearingImportWarnings(
            switchSetID: "switch-1",
            in: source,
            now: now
        )

        let switchSet = try XCTUnwrap(result.switchSets.first)
        XCTAssertEqual(switchSet.importWarnings, [])
        XCTAssertTrue(switchSet.notes.hasPrefix("Gekauft 2024\n\n"))
        XCTAssertTrue(switchSet.notes.contains("2023-11-14"))
        XCTAssertTrue(switchSet.notes.contains("- Board „Alt“ nicht gefunden"))
        XCTAssertTrue(switchSet.notes.contains("- Menge geschätzt"))
        XCTAssertEqual(switchSet.updatedAt, now)

        let unchanged = try InventoryEditingService().clearingImportWarnings(
            switchSetID: "switch-1",
            in: result,
            now: now + 60
        )
        XCTAssertEqual(unchanged, result)
        XCTAssertThrowsError(
            try InventoryEditingService().clearingImportWarnings(switchSetID: "missing", in: source)
        )
    }

    func testBoardDetachDoesNotResurrectLegacyNames() throws {
        let source = legacyRelationshipFixture()
        var draft = InventoryDraft(board: source.boards[0], installations: source.switchInstallations)
        draft.keycapSetID = nil
        draft.installations = [:]
        let saved = try service.saving(draft, newPhotos: [], in: source).snapshot
        let summary = try XCTUnwrap(InventoryQuery.items(in: saved, kind: .board).first)
        XCTAssertEqual(summary.keycapsSummary, "")
        XCTAssertEqual(summary.switchesSummary, "")
        XCTAssertNil(saved.keycapSets[0].mountedBoardID)
        XCTAssertTrue(saved.switchInstallations.isEmpty)
        XCTAssertEqual(saved.boards[1], source.boards[1])
    }

    func testComponentEditorsDetachWithoutResurrectingLegacyNames() throws {
        var source = legacyRelationshipFixture()
        var caps = InventoryDraft(keycapSet: source.keycapSets[0])
        caps.mountedBoardID = nil
        source = try service.saving(caps, newPhotos: [], in: source).snapshot
        XCTAssertEqual(source.boards[0].legacyKeycapsName, "")
        XCTAssertEqual(source.boards[0].legacySwitchesName, "Old switches")
        var switches = InventoryDraft(switchSet: source.switchSets[0], installations: source.switchInstallations)
        switches.installations = [:]
        source = try service.saving(switches, newPhotos: [], in: source).snapshot
        XCTAssertEqual(source.boards[0].legacySwitchesName, "")
    }

    func testMovingComponentsClearsLegacyNamesOnBothBoards() throws {
        for editFromBoard in [true, false] {
            var source = legacyRelationshipFixture()
            if editFromBoard {
                var draft = InventoryDraft(board: source.boards[1], installations: [])
                draft.keycapSetID = "caps"
                source = try service.saving(draft, newPhotos: [], in: source).snapshot
            } else {
                var draft = InventoryDraft(keycapSet: source.keycapSets[0])
                draft.mountedBoardID = "other"
                source = try service.saving(draft, newPhotos: [], in: source).snapshot
            }
            XCTAssertTrue(source.boards.allSatisfy { $0.legacyKeycapsName.isEmpty })
            var switches = InventoryDraft(switchSet: source.switchSets[0], installations: source.switchInstallations)
            switches.installations = ["other": 60]
            source = try service.saving(switches, newPhotos: [], in: source).snapshot
            XCTAssertTrue(source.boards.allSatisfy { $0.legacySwitchesName.isEmpty })
        }
    }

    func testDeletingComponentsDoesNotResurrectLegacyNames() throws {
        var source = legacyRelationshipFixture()
        source = try service.deleting(kind: .keycapSet, id: "caps", in: source).snapshot
        XCTAssertEqual(source.boards[0].legacyKeycapsName, "")
        source = try service.deleting(kind: .switchSet, id: "switches", in: source).snapshot
        XCTAssertEqual(source.boards[0].legacySwitchesName, "")
        XCTAssertEqual(source.boards[1].legacyKeycapsName, "Import caps")
        XCTAssertEqual(source.boards[1].legacySwitchesName, "Import switches")
    }

    func testUnrelatedBoardEditPreservesImportOnlyNames() throws {
        let source = legacyRelationshipFixture()
        var draft = InventoryDraft(board: source.boards[1], installations: [])
        draft.notes = "New note"
        let saved = try service.saving(draft, newPhotos: [], in: source).snapshot
        XCTAssertEqual(saved.boards[1].legacyKeycapsName, "Import caps")
        XCTAssertEqual(saved.boards[1].legacySwitchesName, "Import switches")
    }

    func testSavingNewLibraryValueDeduplicatesCaseInsensitively() throws {
        var source = InventorySnapshot.empty
        source.libraryValues.valuesByKey["manufacturers"] = ["Mode"]
        var draft = InventoryDraft(kind: .board, id: "board-1")
        draft.name = "Sonnet"
        draft.manufacturer = "mode"
        draft.format = "75%"

        let first = try service.saving(draft, newPhotos: [], in: source).snapshot
        XCTAssertEqual(first.libraryValues.valuesByKey["manufacturers"], ["Mode"])
        XCTAssertEqual(first.libraryValues.valuesByKey["formats"], ["75%"])
    }

    func testCaptureLayoutAlwaysFitsAvailableWidth() {
        for width: CGFloat in [640, 760, 980, 1_240, 1_600] {
            let layout = CaptureLayout(availableWidth: width)
            XCTAssertEqual(
                layout.formWidth + CaptureLayout.dividerWidth + layout.previewWidth,
                width,
                accuracy: 0.001
            )
            XCTAssertGreaterThanOrEqual(layout.previewWidth, CaptureLayout.minimumPreviewWidth)
            XCTAssertLessThanOrEqual(layout.previewWidth, CaptureLayout.maximumPreviewWidth)
        }
    }

    func testInventoryQueryCombinesFiltersAndIgnoresDiacritics() {
        var source = InventorySnapshot.empty
        source.boards = [
            Board(id: "board-1", name: "Café Board", manufacturer: "Mode", format: "75%"),
            Board(id: "board-2", name: "Other", manufacturer: "Mode", format: "65%"),
            Board(id: "board-3", name: "Third", manufacturer: "TGR", format: "75%")
        ]
        let filters = InventoryFilters(
            searchText: "cafe",
            manufacturer: "mode",
            format: "75%"
        )

        let results = InventoryQuery.results(
            in: source,
            kind: .board,
            filters: filters,
            sort: .name
        )

        XCTAssertEqual(results.map(\.id), ["board-1"])
    }

    func testInventoryQueryFiltersSwitchesAndSortsQuantity() {
        var source = InventorySnapshot.empty
        source.switchSets = [
            SwitchSet(
                id: "switch-1",
                name: "Low",
                switchType: "Linear",
                operatingForce: "45 g",
                pins: .five,
                quantity: 20
            ),
            SwitchSet(
                id: "switch-2",
                name: "High",
                switchType: "Linear",
                operatingForce: "45 g",
                pins: .five,
                quantity: 100
            ),
            SwitchSet(
                id: "switch-3",
                name: "HE",
                switchType: "Magnetic",
                operatingForce: "45 g",
                pins: .hallEffect,
                quantity: 200
            )
        ]
        let filters = InventoryFilters(
            switchType: "Linear",
            operatingForce: "45 g",
            pins: .five
        )

        let results = InventoryQuery.results(
            in: source,
            kind: .switchSet,
            filters: filters,
            sort: .quantityDescending
        )

        XCTAssertEqual(results.map(\.id), ["switch-2", "switch-1"])
    }

    func testSwitchSaveRejectsMoreInstalledThanOwned() {
        let board = Board(id: "board-1", name: "Board")
        let item = SwitchSet(id: "switch-1", name: "Switches", quantity: 50)
        var source = InventorySnapshot.empty
        source.boards = [board]
        source.switchSets = [item]
        var draft = InventoryDraft(switchSet: item, installations: [])
        draft.installations[board.id] = 51

        XCTAssertThrowsError(try service.saving(draft, newPhotos: [], in: source)) { error in
            guard case InventoryEditingError.invalidQuantity = error else {
                return XCTFail("Expected invalid quantity, got \(error)")
            }
        }
    }

    func testDeleteBoardClearsAllReverseRelationsAndOwnedPhotos() throws {
        let board = Board(id: "board-1", name: "Board", photoIDs: ["photo-1"], mainPhotoID: "photo-1")
        let keycap = KeycapSet(id: "keycap-1", name: "Caps", mountedBoardID: board.id)
        let artisan = ArtisanSet(id: "artisan-1", name: "Artisan", mountedBoardID: board.id)
        let photo = PhotoRecord(
            id: "photo-1",
            owner: PhotoOwner(type: .board, id: board.id),
            originalName: "photo.jpg",
            mimeType: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            addedAt: .now,
            relativeFileName: "photo-1.jpg"
        )
        var source = InventorySnapshot.empty
        source.boards = [board]
        source.keycapSets = [keycap]
        source.artisanSets = [artisan]
        source.switchInstallations = [
            SwitchInstallation(switchSetID: "switch-1", boardID: board.id, quantity: 10)
        ]
        source.photos = [photo]

        let result = try service.deleting(kind: .board, id: board.id, in: source)

        XCTAssertTrue(result.snapshot.boards.isEmpty)
        XCTAssertNil(result.snapshot.keycapSets.first?.mountedBoardID)
        XCTAssertNil(result.snapshot.artisanSets.first?.mountedBoardID)
        XCTAssertTrue(result.snapshot.switchInstallations.isEmpty)
        XCTAssertTrue(result.snapshot.photos.isEmpty)
        XCTAssertEqual(result.removedPhotos, [photo])
    }

    func testPhotoServiceCommitsPreparedPNGToManagedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-manager-photo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.png")
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try png.write(to: sourceURL)

        let layout = MigrationStorageLayout(rootURL: root.appendingPathComponent("AppData"))
        let photoService = PhotoImportService(layout: layout)
        let owner = PhotoOwner(type: .board, id: "board-1")
        let prepared = try await photoService.prepare(urls: [sourceURL], owner: owner)
        try await photoService.commit(prepared)

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.record.owner, owner)
        XCTAssertEqual(prepared.first?.record.mimeType, .png)
        let optionalFileURL = await photoService.fileURL(for: prepared[0].record)
        let fileURL = try XCTUnwrap(optionalFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExternalImageDownloadPreparesValidatedManagedPhotoWithoutWritingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-manager-external-photo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let fetcher = ExternalImageFetcherStub(
            result: ExternalImageFetchResult(
                data: png,
                responseURL: URL(string: "https://cdn.example.com/final.png")!,
                mimeType: "image/png",
                suggestedFileName: "cover.png"
            )
        )
        let layout = MigrationStorageLayout(rootURL: root)
        let service = PhotoImportService(
            layout: layout,
            externalImageFetcher: fetcher
        )
        let owner = PhotoOwner(type: .keycapSet, id: "keycap-1")

        let prepared = try await service.prepareExternal(
            urlStrings: [
                "https://example.com/cover.png",
                "https://example.com/cover.png"
            ],
            owner: owner
        )

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].record.owner, owner)
        XCTAssertEqual(prepared[0].record.originalName, "cover.png")
        XCTAssertEqual(prepared[0].record.mimeType, .png)
        let requestCount = await fetcher.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.currentPhotosDirectoryURL
                    .appendingPathComponent(prepared[0].record.relativeFileName)
                    .path
            )
        )
    }

    func testExternalImageDownloadRejectsHTTPBeforeNetworkAccess() async {
        let fetcher = ExternalImageFetcherStub(
            result: ExternalImageFetchResult(
                data: Data(),
                responseURL: URL(string: "https://example.com/image.png")!,
                mimeType: "image/png",
                suggestedFileName: nil
            )
        )
        let service = PhotoImportService(externalImageFetcher: fetcher)

        do {
            _ = try await service.prepareExternal(
                urlStrings: ["http://example.com/image.png"],
                owner: PhotoOwner(type: .artisanSet, id: "artisan-1")
            )
            XCTFail("HTTP must be rejected")
        } catch PhotoImportError.invalidExternalURL {
            let requestCount = await fetcher.requestCount()
            XCTAssertEqual(requestCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExternalImageDownloadRejectsNonImageAndInsecureFinalResponse() async {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let cases = [
            ExternalImageFetchResult(
                data: png,
                responseURL: URL(string: "https://example.com/image.png")!,
                mimeType: "text/html",
                suggestedFileName: "image.png"
            ),
            ExternalImageFetchResult(
                data: png,
                responseURL: URL(string: "http://example.com/image.png")!,
                mimeType: "image/png",
                suggestedFileName: "image.png"
            )
        ]

        for result in cases {
            let service = PhotoImportService(
                externalImageFetcher: ExternalImageFetcherStub(result: result)
            )
            do {
                _ = try await service.prepareExternal(
                    urlStrings: ["https://example.com/image.png"],
                    owner: PhotoOwner(type: .keycapSet, id: "keycap-1")
                )
                XCTFail("Invalid external response must be rejected")
            } catch PhotoImportError.invalidExternalResponse {
                continue
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testThumbnailServiceCreatesAndReusesManagedCacheFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-manager-thumbnail-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MigrationStorageLayout(rootURL: root)
        try FileManager.default.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let record = PhotoRecord(
            id: "photo-1",
            owner: PhotoOwner(type: .board, id: "board-1"),
            originalName: "source.png",
            mimeType: .png,
            pixelWidth: 1,
            pixelHeight: 1,
            addedAt: .now,
            relativeFileName: "photo-1.png"
        )
        try png.write(
            to: layout.currentPhotosDirectoryURL.appendingPathComponent(record.relativeFileName)
        )
        let thumbnailService = ThumbnailService(layout: layout)

        let first = await thumbnailService.thumbnailData(for: record)
        let second = await thumbnailService.thumbnailData(for: record)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.currentThumbnailsDirectoryURL
                    .appendingPathComponent("photo-1.jpg")
                    .path
            )
        )
    }
}

private actor ExternalImageFetcherStub: ExternalImageFetching {
    private let result: ExternalImageFetchResult
    private var requests: [URL] = []

    init(result: ExternalImageFetchResult) {
        self.result = result
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> ExternalImageFetchResult {
        requests.append(url)
        return result
    }

    func requestCount() -> Int {
        requests.count
    }
}
