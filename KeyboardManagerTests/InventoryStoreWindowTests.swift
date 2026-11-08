import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import KeyboardManager

@MainActor
final class InventoryStoreWindowTests: XCTestCase {
    func testPreferredLanguageIsNormalizedAndPersistedInSnapshot() async throws {
        let repository = InMemoryInventoryRepository()
        let store = InventoryStore(repository: repository)

        await store.load()
        await store.updatePreferredLanguage("en")

        XCTAssertEqual(store.snapshot.metadata.preferredLanguage, "en")
        let persisted = try await repository.loadSnapshot()
        XCTAssertEqual(persisted.metadata.preferredLanguage, "en")
        XCTAssertNil(store.languagePersistenceError)

        await store.updatePreferredLanguage("unsupported")
        XCTAssertEqual(store.snapshot.metadata.preferredLanguage, "de")
    }

    func testFailedLoadBlocksWritesSoStoredDataIsNotOverwritten() async throws {
        let repository = FailingLoadRepository()
        let store = InventoryStore(repository: repository)
        await store.load()
        guard case .failed = store.loadState else {
            return XCTFail("Load should have failed")
        }

        store.prepareNewItem(.board)
        var draft = store.editorDraft()
        draft.name = "New"
        let saved = await store.save(draft, preparedPhotos: [])
        let deleted = await store.deleteItem(kind: .board, id: draft.id)
        await store.updatePreferredLanguage("en")

        XCTAssertFalse(saved)
        XCTAssertFalse(deleted)
        XCTAssertEqual(
            store.editorSaveState,
            .failed(InventoryStore.inventoryNotLoadedMessage)
        )
        XCTAssertTrue(store.hasExistingV2Data)
        let saveCount = await repository.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    func testConcurrentSavesKeepBothChanges() async throws {
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [
                Board(id: "board-1", name: "One"),
                Board(id: "board-2", name: "Two")
            ],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
        let repository = InMemoryInventoryRepository(snapshot: snapshot)
        let store = InventoryStore(repository: repository)
        await store.load()

        store.editItem(kind: .board, id: "board-1")
        var first = store.editorDraft()
        first.name = "One edited"
        store.editItem(kind: .board, id: "board-2")
        var second = store.editorDraft()
        second.name = "Two edited"

        async let firstSaved = store.save(first, preparedPhotos: [])
        async let secondSaved = store.save(second, preparedPhotos: [])
        let results = await [firstSaved, secondSaved]

        XCTAssertEqual(results, [true, true])
        let persisted = try await repository.loadSnapshot()
        XCTAssertEqual(
            persisted.boards.map(\.name).sorted(),
            ["One edited", "Two edited"]
        )
        XCTAssertEqual(store.snapshot, persisted)
    }

    func testLoadingAndSavingTriggerAutomaticBackupOnlyWhenEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerStoreAutoBackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "One")],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )

        let disabledStore = InventoryStore(
            repository: InMemoryInventoryRepository(snapshot: snapshot),
            automaticBackupService: AutomaticBackupService(directoryURL: directory),
            automaticBackupsEnabled: { false }
        )
        await disabledStore.load()
        await disabledStore.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let service = AutomaticBackupService(directoryURL: directory)
        let store = InventoryStore(
            repository: InMemoryInventoryRepository(snapshot: snapshot),
            automaticBackupService: service,
            automaticBackupsEnabled: { true }
        )
        await store.load()
        await store.waitForPendingWrites()

        let created = try XCTUnwrap(store.latestAutomaticBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.url.path))
        let entriesAfterLoad = await service.entries()
        XCTAssertEqual(entriesAfterLoad.count, 1)

        // A change on the same day is not backed up again automatically.
        store.editItem(kind: .board, id: "board-1")
        var draft = store.editorDraft()
        draft.name = "One edited"
        let saved = await store.save(draft, preparedPhotos: [])
        await store.waitForPendingWrites()
        XCTAssertTrue(saved)
        let entriesAfterSave = await service.entries()
        XCTAssertEqual(entriesAfterSave.count, 1)

        await store.backUpNow()
        let entriesAfterForce = await service.entries()
        // Both files may carry the same second, so compare contents, not order.
        XCTAssertEqual(entriesAfterForce.count, 2)
        XCTAssertEqual(
            Set(entriesAfterForce.map(\.fingerprint)).subtracting([created.fingerprint]).count,
            1
        )
        XCTAssertEqual(store.automaticBackupState, .created(entriesAfterForce[0].createdAt))
    }

    func testDroppedPhotosBecomeLocalImageFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let finderPhoto = directory.appendingPathComponent("Board.png")
        try png.write(to: finderPhoto)
        let textFile = directory.appendingPathComponent("Notiz.txt")
        try Data("kein Bild".utf8).write(to: textFile)

        let fromFinder = NSItemProvider(object: finderPhoto as NSURL)
        let notAnImage = NSItemProvider(object: textFile as NSURL)
        let fromPhotosApp = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)

        let loader = DroppedPhotoLoader()
        let result = await loader.load([fromFinder, notAnImage, fromPhotosApp])

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.urls.count, 2)
        XCTAssertEqual(result.urls.first?.standardizedFileURL, finderPhoto.standardizedFileURL)
        let copied = try XCTUnwrap(result.urls.last)
        XCTAssertTrue(copied.path.hasPrefix(loader.temporaryDirectory.path))
        XCTAssertEqual(try Data(contentsOf: copied), png)

        loader.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finderPhoto.path), "Finder-Dateien bleiben unberührt.")
    }

    func testCleanEditorAllowsWindowToCloseImmediately() {
        let store = makeStore()
        store.prepareNewItem(.board)

        XCTAssertTrue(store.shouldAllowWindowClose())
        XCTAssertFalse(store.isWindowCloseConfirmationPresented)
        XCTAssertEqual(store.windowCloseRevision, 0)
    }

    func testDirtyEditorDefersCloseUntilUserConfirmsDiscard() {
        let store = makeStore()
        store.prepareNewItem(.board)
        store.isEditorDirty = true

        XCTAssertFalse(store.shouldAllowWindowClose())
        XCTAssertTrue(store.isWindowCloseConfirmationPresented)
        XCTAssertEqual(store.windowCloseRevision, 0)

        store.confirmDiscardAndCloseWindow()

        XCTAssertFalse(store.isEditorDirty)
        XCTAssertFalse(store.isWindowCloseConfirmationPresented)
        XCTAssertEqual(store.windowCloseRevision, 1)
    }

    func testCancellingWindowCloseKeepsDirtyDraft() {
        let store = makeStore()
        store.prepareNewItem(.switchSet)
        store.isEditorDirty = true

        XCTAssertFalse(store.shouldAllowWindowClose())
        store.cancelWindowClose()

        XCTAssertTrue(store.isEditorDirty)
        XCTAssertFalse(store.isWindowCloseConfirmationPresented)
        XCTAssertEqual(store.windowCloseRevision, 0)
    }

    func testCaptureRouteAlwaysStartsBlankDraftAfterEditingExistingItem() {
        let store = makeStore()
        store.snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "Board")],
            keycapSets: [KeycapSet(id: "keycap-1", name: "Keycaps")],
            artisanSets: [ArtisanSet(id: "artisan-1", name: "Artisan")],
            switchSets: [SwitchSet(id: "switch-1", name: "Switches")],
            switchInstallations: [],
            photos: []
        )

        let existingItems: [(InventoryItemKind, String)] = [
            (.board, "board-1"),
            (.keycapSet, "keycap-1"),
            (.artisanSet, "artisan-1"),
            (.switchSet, "switch-1")
        ]

        for (kind, id) in existingItems {
            store.editItem(kind: kind, id: id)
            XCTAssertEqual(store.editorDraft().normalizedName.isEmpty, false)

            store.requestRoute(.overview)
            store.requestRoute(.capture)

            XCTAssertEqual(store.route, .capture)
            XCTAssertEqual(store.selectedKind, kind)
            XCTAssertNil(store.selectedItemID)
            XCTAssertEqual(store.editorDraft().kind, kind)
            XCTAssertTrue(store.editorDraft().normalizedName.isEmpty)
        }
    }

    func testSavingEditedItemRestoresOverviewSessionSelectionScrollAndFocusRequest() async throws {
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "Before")],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
        let store = InventoryStore(
            repository: InMemoryInventoryRepository(snapshot: snapshot)
        )
        await store.load()

        var filters = InventoryFilters()
        filters.manufacturer = "Mode"
        store.overviewFiltersByKind[.board] = filters
        store.overviewSortsByKind[.board] = .recentlyUpdated
        store.updateOverviewScrollOffset(243.5, for: .board)
        store.editItem(kind: .board, id: "board-1")

        var draft = store.editorDraft()
        draft.name = "After"
        let succeeded = await store.save(draft, preparedPhotos: [])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.route, .overview)
        XCTAssertEqual(store.overviewSelectionByKind[.board], "board-1")
        XCTAssertEqual(
            store.overviewFiltersByKind[.board]?.manufacturer,
            "Mode"
        )
        XCTAssertEqual(store.overviewSortsByKind[.board], .recentlyUpdated)
        let restoredOffset = try XCTUnwrap(
            store.overviewRestoreRequest?.scrollOffset
        )
        XCTAssertEqual(restoredOffset, 243.5, accuracy: 0.001)
        XCTAssertEqual(store.overviewRestoreRequest?.itemID, "board-1")
        XCTAssertEqual(store.overviewRestoreRequest?.kind, .board)
        XCTAssertEqual(store.overviewRestoreRequest?.revision, 1)
    }

    func testDiscardingEditedItemBackToOverviewRequestsSameRestoration() async {
        let snapshot = InventorySnapshot(
            metadata: .empty,
            libraryValues: .empty,
            boards: [Board(id: "board-1", name: "Board")],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
        let store = InventoryStore(
            repository: InMemoryInventoryRepository(snapshot: snapshot)
        )
        await store.load()
        store.updateOverviewScrollOffset(96, for: .board)
        store.editItem(kind: .board, id: "board-1")
        store.isEditorDirty = true

        store.requestRoute(.overview)

        XCTAssertEqual(store.route, .capture)
        XCTAssertTrue(store.isDiscardConfirmationPresented)

        store.confirmDiscardAndContinue()

        XCTAssertEqual(store.route, .overview)
        XCTAssertFalse(store.isDiscardConfirmationPresented)
        XCTAssertEqual(store.overviewRestoreRequest?.itemID, "board-1")
        XCTAssertEqual(store.overviewRestoreRequest?.scrollOffset, 96)
    }

    func testTableBridgeRestoresPixelOffsetAndKeyboardFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let rootView = NSView(frame: window.contentLayoutRect)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 200)
        )
        scrollView.hasVerticalScroller = true

        let tableView = NSTableView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 900)
        )
        for index in 0..<5 {
            tableView.addTableColumn(
                NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            )
        }
        let dataSource = TableBridgeDataSource(rowCount: 30)
        tableView.dataSource = dataSource
        tableView.reloadData()
        tableView.frame.size.height = 900
        scrollView.documentView = tableView

        let locator = TableLocatorView(frame: .zero)
        rootView.addSubview(scrollView)
        rootView.addSubview(locator)
        window.contentView = rootView

        let coordinator = OverviewTableFocusBridge.Coordinator(
            onScrollOffsetChange: { _ in },
            onRestoreApplied: { _ in }
        )
        coordinator.update(
            restoreRequest: OverviewRestoreRequest(
                revision: 1,
                kind: .board,
                itemID: "board-1",
                scrollOffset: 180
            ),
            selectedRow: 8,
            rowCount: 30,
            onScrollOffsetChange: { _ in },
            onRestoreApplied: { _ in }
        )
        coordinator.resolveTable(from: locator)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            180,
            accuracy: 0.001
        )
        XCTAssertTrue(window.firstResponder === tableView)
        coordinator.detach()
    }

    private func makeStore() -> InventoryStore {
        InventoryStore(repository: InMemoryInventoryRepository())
    }
}

private final class TableBridgeDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }
}

private actor FailingLoadRepository: InventoryRepository {
    private(set) var saveCount = 0

    func loadSnapshot() async throws -> InventorySnapshot {
        throw CocoaError(.fileReadCorruptFile)
    }

    func saveSnapshot(_ snapshot: InventorySnapshot) async throws {
        saveCount += 1
    }
}
