import AppKit
import XCTest
@testable import KeyboardManager

final class InventoryComfortTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    // MARK: Duplicate

    func testDuplicateKeepsFieldsButDropsExclusiveRelationsAndImportData() {
        var draft = InventoryDraft(kind: .board, id: "board-1")
        draft.name = "Mode Sonnet"
        draft.manufacturer = "Mode"
        draft.color = "Blau"
        draft.weightMaterial = "Messing"
        draft.purchasePriceText = "349,00"
        draft.keycapSetID = "keycaps-1"
        draft.installations = ["switch-1": 70]
        draft.photoIDs = ["photo-1"]
        draft.mainPhotoID = "photo-1"
        draft.legacySwitchesName = "Old"
        draft.importWarnings = ["warning"]

        let copy = draft.duplicated(id: "board-2")

        XCTAssertEqual(copy.id, "board-2")
        XCTAssertEqual(copy.name, L10n.text("%@ (Kopie)", arguments: "Mode Sonnet"))
        XCTAssertEqual(copy.manufacturer, "Mode")
        XCTAssertEqual(copy.color, "Blau")
        XCTAssertEqual(copy.weightMaterial, "Messing")
        XCTAssertEqual(copy.purchasePriceText, "349,00")
        XCTAssertNil(copy.keycapSetID)
        XCTAssertTrue(copy.installations.isEmpty)
        XCTAssertTrue(copy.photoIDs.isEmpty)
        XCTAssertNil(copy.mainPhotoID)
        XCTAssertEqual(copy.legacySwitchesName, "")
        XCTAssertTrue(copy.importWarnings.isEmpty)
    }

    @MainActor
    func testStoreDuplicateCopiesPhotosAndOpensUnsavedEditor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let photoService = PhotoImportService(layout: MigrationStorageLayout(rootURL: root))
        let owner = PhotoOwner(type: .keycapSet, id: "set-1")
        let source = root.appendingPathComponent("a.png")
        try png.write(to: source)
        let prepared = try await photoService.prepare(urls: [source, source], owner: owner)
        try await photoService.commit(prepared)

        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "Board")],
            keycapSets: [KeycapSet(
                id: "set-1",
                name: "GMK Olivia",
                mountedBoardID: "board-1",
                photoIDs: prepared.map(\.record.id),
                mainPhotoID: prepared[1].record.id
            )],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: prepared.map(\.record)
        )
        let repository = InMemoryInventoryRepository(snapshot: snapshot)
        let store = InventoryStore(repository: repository, photoService: photoService)
        await store.load()

        let opened = await store.duplicateItem(kind: .keycapSet, id: "set-1")
        XCTAssertTrue(opened)
        XCTAssertEqual(store.route, .capture)
        XCTAssertNil(store.selectedItemID)
        let duplicate = try XCTUnwrap(store.takePendingDuplicate())
        XCTAssertNil(store.takePendingDuplicate(), "The copy is handed out only once")

        XCTAssertNotEqual(duplicate.draft.id, "set-1")
        XCTAssertNil(duplicate.draft.mountedBoardID)
        XCTAssertEqual(duplicate.photos.count, 2)
        XCTAssertTrue(duplicate.photos.allSatisfy { $0.record.owner.id == duplicate.draft.id })
        XCTAssertEqual(duplicate.draft.photoIDs, duplicate.photos.map(\.record.id))
        XCTAssertEqual(duplicate.draft.mainPhotoID, duplicate.photos[1].record.id)
        XCTAssertTrue(Set(duplicate.draft.photoIDs).isDisjoint(with: prepared.map(\.record.id)))

        // Nothing is written until the copy is saved.
        let stored = try await repository.loadSnapshot()
        XCTAssertEqual(stored.keycapSets.count, 1)

        let saved = await store.save(duplicate.draft, preparedPhotos: duplicate.photos)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.snapshot.keycapSets.count, 2)
        XCTAssertEqual(store.snapshot.photos.count, 4)
        XCTAssertEqual(store.snapshot.keycapSets.first { $0.id == "set-1" }?.mountedBoardID, "board-1")
    }

    // MARK: Photo order

    func testMovingPhotosByDragAndByStep() {
        var draft = InventoryDraft(kind: .board)
        draft.photoIDs = ["a", "b", "c", "d"]

        draft.movePhoto("a", onto: "c")
        XCTAssertEqual(draft.photoIDs, ["b", "c", "a", "d"])
        draft.movePhoto("d", onto: "b")
        XCTAssertEqual(draft.photoIDs, ["d", "b", "c", "a"])
        draft.movePhoto("d", by: -1)
        XCTAssertEqual(draft.photoIDs, ["d", "b", "c", "a"])
        draft.movePhoto("d", by: 1)
        XCTAssertEqual(draft.photoIDs, ["b", "d", "c", "a"])
        draft.movePhoto("x", onto: "a")
        XCTAssertEqual(draft.photoIDs, ["b", "d", "c", "a"])
    }

    func testReorderPayloadIsNotConfusedWithOtherText() {
        XCTAssertEqual(PhotoReorderDrag.photoID(from: PhotoReorderDrag.payload(for: "p-1")), "p-1")
        XCTAssertNil(PhotoReorderDrag.photoID(from: "p-1"))
    }

    // MARK: Paste and drop

    @MainActor
    func testPastedImageDataBecomesImportablePhotoAndTextWins() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("km-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let tiff = try XCTUnwrap(NSImage(data: png)?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertTrue(PhotoPasteboard.containsImages(pasteboard))
        XCTAssertTrue(PhotoPasteboard.shouldPasteAsPhotos(pasteboard, textHasFocus: true))

        let urls = try PhotoPasteboard.imageURLs(from: pasteboard, temporaryDirectory: root)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.pathExtension, "png")
        XCTAssertTrue(DroppedPhotoLoader.isImageFile(try XCTUnwrap(urls.first)))

        pasteboard.clearContents()
        pasteboard.setString("Name", forType: .string)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertFalse(PhotoPasteboard.shouldPasteAsPhotos(pasteboard, textHasFocus: true))
        XCTAssertTrue(PhotoPasteboard.shouldPasteAsPhotos(pasteboard, textHasFocus: false))

        pasteboard.clearContents()
        pasteboard.setString("Nur Text", forType: .string)
        XCTAssertFalse(PhotoPasteboard.containsImages(pasteboard))
    }

    @MainActor
    func testPhotosDroppedOnEntryAreAddedWithoutEditor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let photoService = PhotoImportService(layout: MigrationStorageLayout(rootURL: root.appendingPathComponent("AppData")))
        let repository = InMemoryInventoryRepository(snapshot: InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "Board", color: "Rot")],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        ))
        let store = InventoryStore(repository: repository, photoService: photoService)
        await store.load()
        let file = root.appendingPathComponent("drop.png")
        try png.write(to: file)

        let added = await store.addPhotos(urls: [file, file], toItem: .board, id: "board-1")

        XCTAssertTrue(added)
        let board = try XCTUnwrap(store.snapshot.boards.first)
        XCTAssertEqual(board.photoIDs.count, 2)
        XCTAssertEqual(board.mainPhotoID, board.photoIDs.first)
        XCTAssertEqual(board.color, "Rot")
        XCTAssertEqual(store.route, .overview)
        let stored = try await repository.loadSnapshot()
        XCTAssertEqual(stored.photos.count, 2)
        for record in stored.photos {
            let url = await photoService.fileURL(for: record)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(url).path))
        }
    }

    // MARK: Bulk edit

    func testBulkEditChangesOnlyChosenFieldsAndIsAllOrNothing() throws {
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [
                Board(id: "1", name: "One", manufacturer: "A", color: "Rot"),
                Board(id: "2", name: "Two", manufacturer: "B", color: "Grün"),
                Board(id: "3", name: "Three", manufacturer: "C", color: "Blau")
            ],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
        let service = InventoryEditingService()

        let updated = try service.applyingBulkEdit(
            [.color: " Schwarz ", .boardStatus: BoardStatus.sold.rawValue, .manufacturer: ""],
            kind: .board,
            ids: ["1", "2"],
            in: snapshot
        )

        let byID = Dictionary(uniqueKeysWithValues: updated.boards.map { ($0.id, $0) })
        XCTAssertEqual(byID["1"]?.color, "Schwarz")
        XCTAssertEqual(byID["2"]?.color, "Schwarz")
        XCTAssertEqual(byID["1"]?.status, .sold)
        XCTAssertEqual(byID["1"]?.manufacturer, "")
        XCTAssertEqual(byID["1"]?.name, "One")
        XCTAssertEqual(byID["3"], snapshot.boards[2])
        XCTAssertTrue(updated.libraryValues.valuesByKey["boardColors", default: []].contains("Schwarz"))

        XCTAssertThrowsError(
            try service.applyingBulkEdit([.color: "X"], kind: .board, ids: ["1", "missing"], in: snapshot)
        )
    }

    @MainActor
    func testBulkEditCanBeUndone() async throws {
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "1", name: "One", color: "Rot"), Board(id: "2", name: "Two", color: "Grün")],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
        let repository = InMemoryInventoryRepository(snapshot: snapshot)
        let store = InventoryStore(repository: repository)
        await store.load()

        let applied = await store.applyBulkEdit([.color: "Weiß"], kind: .board, ids: ["1", "2"])
        XCTAssertTrue(applied)
        XCTAssertEqual(Set(store.snapshot.boards.map(\.color)), ["Weiß"])
        XCTAssertEqual(store.undoableDeletion?.change, .bulkEdit(2))

        await store.undoLastDeletion()
        XCTAssertEqual(store.snapshot.boards.map(\.color), ["Rot", "Grün"])
        let stored = try await repository.loadSnapshot()
        XCTAssertEqual(stored.boards.map(\.color), ["Rot", "Grün"])
        XCTAssertNil(store.undoableDeletion)
    }

    func testMultiSelectionHasNoSingleCurrentEntry() async {
        await MainActor.run {
            let store = InventoryStore(repository: InMemoryInventoryRepository())
            store.updateOverviewMultiSelection(["a", "b"], for: .board)
            XCTAssertNil(store.overviewSelectionByKind[.board])
            XCTAssertEqual(store.overviewMultiSelectionByKind[.board], ["a", "b"])
            store.updateOverviewMultiSelection(["a"], for: .board)
            XCTAssertEqual(store.overviewSelectionByKind[.board], "a")
            store.updateOverviewSelection(nil, for: .board)
            XCTAssertNil(store.overviewMultiSelectionByKind[.board])
        }
    }

    // MARK: CSV

    func testCSVCodecRoundTripsQuotesSeparatorsAndLineBreaks() {
        let rows = [["Name", "Notizen"], ["A; B", "Zeile 1\nZeile \"2\""], ["", " leading"]]
        let text = CSVCodec.encode(rows)
        XCTAssertEqual(CSVCodec.decode(text), rows)
        XCTAssertEqual(CSVCodec.decode("Name,Farbe\nOne,Rot\n"), [["Name", "Farbe"], ["One", "Rot"]])
        XCTAssertEqual(CSVCodec.decode("Name\tFarbe\r\nOne\tRot"), [["Name", "Farbe"], ["One", "Rot"]])
        XCTAssertEqual(CSVCodec.decode("\u{FEFF}Name;Farbe\n\n;\nOne;\"Rot\""), [["Name", "Farbe"], ["One", "Rot"]])
    }

    func testBoardCSVExportImportsBackIntoEmptyCollection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))
        let source = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(
                id: "1",
                name: "Mode; Sonnet",
                manufacturer: "Mode",
                color: "Blau",
                weightMaterial: "Messing",
                status: .ordered,
                purchasePrice: Decimal(string: "1234.5"),
                purchaseDate: date,
                purchaseShop: "Shop",
                weightGrams: 2100,
                remark: "Zeile 1\nZeile 2"
            )],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )

        let text = InventoryCSV.export(source, kind: .board)
        XCTAssertTrue(text.hasPrefix("\u{FEFF}Name;Hersteller;"))
        XCTAssertTrue(text.contains("2026-03-14"))
        XCTAssertTrue(text.contains("1234,5"))
        XCTAssertTrue(text.contains("Bestellt"))

        let preview = try InventoryCSV.preview(text, kind: .board, in: .empty)
        XCTAssertEqual(preview.errors, [])
        XCTAssertEqual(preview.ignoredColumns, ["Keycap-Set", "Switches"])
        let draft = try XCTUnwrap(preview.drafts.first)
        let imported = try InventoryEditingService().saving(draft, newPhotos: [], in: .empty).snapshot.boards[0]
        XCTAssertEqual(imported.name, "Mode; Sonnet")
        XCTAssertEqual(imported.status, .ordered)
        XCTAssertEqual(imported.purchasePrice, Decimal(string: "1234.5"))
        XCTAssertEqual(imported.purchaseDate, date)
        XCTAssertEqual(imported.weightGrams, 2100)
        XCTAssertEqual(imported.weightMaterial, "Messing")
        XCTAssertEqual(imported.remark, "Zeile 1\nZeile 2")

        // Importing the same file again creates nothing.
        let again = try InventoryCSV.preview(text, kind: .board, in: source)
        XCTAssertTrue(again.drafts.isEmpty)
        XCTAssertEqual(again.duplicates.map(\.name), ["Mode; Sonnet"])
    }

    func testCSVPreviewReportsBadRowsAndKeepsGoodOnes() throws {
        let text = """
        name,Status,Preis (€),Kaufdatum,Unbekannt
        Gut,verkauft,99,01.02.2025,x
        Schlechter Preis,Vorhanden,abc,,
        Falscher Status,Kaputt,,,
        ,Vorhanden,,,
        Gut,Vorhanden,,,
        """
        let preview = try InventoryCSV.preview(text, kind: .board, in: .empty)

        XCTAssertEqual(preview.drafts.map(\.name), ["Gut"])
        XCTAssertEqual(preview.drafts.first?.status, BoardStatus.sold.rawValue)
        XCTAssertEqual(preview.errors.map(\.row), [3, 4, 5])
        XCTAssertEqual(preview.duplicates.map(\.row), [6])
        XCTAssertEqual(preview.ignoredColumns, ["Unbekannt"])

        XCTAssertThrowsError(try InventoryCSV.preview("Farbe\nRot", kind: .board, in: .empty)) { error in
            XCTAssertEqual(error as? InventoryCSVError, .missingNameColumn)
        }
    }

    func testSwitchCSVReadsNumbersPinsAndFlags() throws {
        let text = "Name;Pins;Bestand;LED-Diffusor;Werkseitig geschmiert\nOil King;3 PIN;90;ja;nein\nBad;7;1;;\n"
        let preview = try InventoryCSV.preview(text, kind: .switchSet, in: .empty)
        let draft = try XCTUnwrap(preview.drafts.first)
        XCTAssertEqual(draft.pins, .three)
        XCTAssertEqual(draft.quantity, 90)
        XCTAssertTrue(draft.hasLEDDiffuser)
        XCTAssertFalse(draft.isFactoryLubed)
        XCTAssertEqual(preview.errors.map(\.row), [3])
    }

    @MainActor
    func testStoreCSVImportWritesOnceAndCanBeUndone() async throws {
        let repository = InMemoryInventoryRepository(snapshot: InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [],
            keycapSets: [KeycapSet(id: "k", name: "Bestehend")],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        ))
        let store = InventoryStore(repository: repository)
        await store.load()

        let imported = await store.importCSV("Name;Profil;Kits\nNeu;Cherry;Base, Novelties\nbestehend;;\n", kind: .keycapSet)

        XCTAssertTrue(imported)
        XCTAssertEqual(store.snapshot.keycapSets.map(\.name).sorted(), ["Bestehend", "Neu"])
        XCTAssertEqual(store.snapshot.keycapSets.first { $0.name == "Neu" }?.kits, ["Base", "Novelties"])
        XCTAssertEqual(store.undoableDeletion?.change, .csvImport(1))

        await store.undoLastDeletion()
        let stored = try await repository.loadSnapshot()
        XCTAssertEqual(stored.keycapSets.map(\.name), ["Bestehend"])
    }

    func testDateParsingAcceptsISOAndGermanFormat() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = calendar.date(from: DateComponents(year: 2025, month: 2, day: 1))
        XCTAssertEqual(InventoryCSV.parseDate("2025-02-01"), expected)
        XCTAssertEqual(InventoryCSV.parseDate("01.02.2025"), expected)
        XCTAssertNil(InventoryCSV.parseDate("31.02.2025"))
        XCTAssertNil(InventoryCSV.parseDate("morgen"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-manager-comfort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
