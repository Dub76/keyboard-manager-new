import XCTest
@testable import KeyboardManager

final class InventoryModelsTests: XCTestCase {
    func testStringCatalogProvidesGermanAndEnglishAtRuntime() {
        XCTAssertEqual(L10n.text("Übersicht", language: "de"), "Übersicht")
        XCTAssertEqual(L10n.text("Übersicht", language: "en"), "Overview")
        XCTAssertEqual(
            L10n.text("%lld Einträge", language: "en", arguments: 3),
            "3 entries"
        )
    }

    func testBoardsSavedBeforeColorExistedStillDecode() throws {
        var current = InventorySnapshot.empty
        current.boards = [Board(id: "board-1", name: "Alt", format: "65%")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any]
        )
        var boards = try XCTUnwrap(json["boards"] as? [[String: Any]])
        boards[0].removeValue(forKey: "color")
        boards[0].removeValue(forKey: "weightMaterial")
        for key in ["status", "purchasePrice", "purchaseDate", "purchaseShop", "mounting",
                    "caseMaterial", "layout", "typingAngle", "weightGrams"] {
            boards[0].removeValue(forKey: key)
        }
        json["boards"] = boards
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(InventorySnapshot.self, from: legacyData)

        XCTAssertEqual(decoded.boards.first?.color, "")
        XCTAssertEqual(decoded.boards.first?.weightMaterial, "")
        XCTAssertEqual(decoded.boards.first?.status, .owned)
        XCTAssertNil(decoded.boards.first?.purchasePrice)
        XCTAssertNil(decoded.boards.first?.weightGrams)
        XCTAssertEqual(decoded.boards.first?.format, "65%")

        var colored = decoded
        colored.boards[0].color = "Navy"
        let roundTrip = try decoder.decode(InventorySnapshot.self, from: encoder.encode(colored))
        XCTAssertEqual(roundTrip.boards.first?.color, "Navy")
    }

    func testBoardColorIsSavedRememberedSearchableAndFilterable() throws {
        var source = InventorySnapshot.empty
        source.boards = [Board(id: "board-2", name: "Zweites", color: "Silber")]
        var draft = InventoryDraft(kind: .board)
        draft.name = "Erstes"
        draft.color = "  Navy  "

        let saved = try InventoryEditingService().saving(draft, newPhotos: [], in: source).snapshot

        let board = try XCTUnwrap(saved.boards.first { $0.id == draft.id })
        XCTAssertEqual(board.color, "Navy")
        XCTAssertEqual(InventoryDraft(board: board, installations: []).color, "Navy")
        XCTAssertTrue(saved.libraryValues.valuesByKey["boardColors", default: []].contains("Navy"))

        var filters = InventoryFilters()
        filters.color = "Navy"
        XCTAssertFalse(filters.isEmpty(for: .board))
        let filtered = InventoryQuery.results(in: saved, kind: .board, filters: filters, sort: .name)
        XCTAssertEqual(filtered.map(\.name), ["Erstes"])

        var search = InventoryFilters()
        search.searchText = "silber"
        XCTAssertEqual(
            InventoryQuery.results(in: saved, kind: .board, filters: search, sort: .name).map(\.name),
            ["Zweites"]
        )
    }

    func testWeightMaterialIsSavedRememberedAndSuggested() async throws {
        var draft = InventoryDraft(kind: .board)
        draft.name = "Schwer"
        draft.weightMaterial = " Wolfram "
        let saved = try InventoryEditingService().saving(draft, newPhotos: [], in: .empty).snapshot
        let board = try XCTUnwrap(saved.boards.first)
        XCTAssertEqual(board.weightMaterial, "Wolfram")
        XCTAssertEqual(InventoryDraft(board: board, installations: []).weightMaterial, "Wolfram")

        let summary = try XCTUnwrap(InventoryQuery.items(in: saved, kind: .board).first)
        XCTAssertEqual(summary.weightMaterial, "Wolfram")
        XCTAssertTrue(summary.searchableText.contains("Wolfram"))

        let store = await MainActor.run { InventoryStore(repository: InMemoryInventoryRepository(snapshot: saved)) }
        await store.load()
        let suggestions = await store.weightMaterialSuggestions()
        XCTAssertEqual(suggestions.first, "Wolfram")
        for material in ["Messing", "Kupfer", "Aluminium", "Edelstahl"] {
            XCTAssertTrue(suggestions.contains(material), material)
        }
        XCTAssertEqual(suggestions.count, Set(suggestions.map { $0.lowercased() }).count)
    }

    func testInstanceLockAllowsOnlyOneHolderUntilReleased() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = InstanceLock(directoryURL: directory)
        let second = InstanceLock(directoryURL: directory)

        XCTAssertTrue(first.acquire())
        XCTAssertTrue(first.acquire(), "Repeated acquire by the holder is harmless.")
        XCTAssertFalse(second.acquire())

        first.release()
        XCTAssertTrue(second.acquire())
    }

    func testPriceAndGramsParsing() {
        let cases: [(String, Decimal?)] = [
            ("349,99", Decimal(string: "349.99")),
            ("349.99", Decimal(string: "349.99")),
            ("1.234,50", Decimal(string: "1234.5")),
            ("1,234.50", Decimal(string: "1234.5")),
            ("1.234", 1234),
            ("275 €", 275),
            ("0", 0),
            ("abc", nil),
            ("-5", nil),
            ("", nil)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(BoardValueFormat.parsePrice(text), expected, text)
        }
        XCTAssertEqual(BoardValueFormat.parseGrams("1200"), 1200)
        XCTAssertEqual(BoardValueFormat.parseGrams("1.200 g"), 1200)
        XCTAssertNil(BoardValueFormat.parseGrams("schwer"))
        XCTAssertNil(BoardValueFormat.parseGrams("0"))
    }

    func testBoardPurchaseAndSpecFieldsRoundTripThroughEditor() throws {
        var draft = InventoryDraft(kind: .board)
        draft.name = "Neo60"
        draft.status = BoardStatus.ordered.rawValue
        draft.purchasePriceText = "275,50"
        draft.purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        draft.purchaseShop = " MonacoKeys "
        draft.mounting = "Gasket"
        draft.caseMaterial = "Kupfer"
        draft.layout = "ANSI"
        draft.typingAngle = "7°"
        draft.weightGramsText = "1.450"

        let saved = try InventoryEditingService().saving(draft, newPhotos: [], in: .empty).snapshot
        let board = try XCTUnwrap(saved.boards.first)

        XCTAssertEqual(board.status, .ordered)
        XCTAssertEqual(board.purchasePrice, Decimal(string: "275.5"))
        XCTAssertEqual(board.purchaseShop, "MonacoKeys")
        XCTAssertEqual(board.weightGrams, 1450)
        XCTAssertEqual(saved.libraryValues.valuesByKey["boardMountings"], ["Gasket"])
        let reopened = InventoryDraft(board: board, installations: [])
        XCTAssertEqual(BoardValueFormat.parsePrice(reopened.purchasePriceText), board.purchasePrice)
        XCTAssertEqual(reopened.status, "ordered")
        XCTAssertEqual(reopened.weightGramsText, "1450")

        draft.purchasePriceText = "teuer"
        XCTAssertThrowsError(try InventoryEditingService().saving(draft, newPhotos: [], in: .empty)) {
            XCTAssertEqual($0 as? InventoryEditingError, .invalidPrice("teuer"))
        }
    }

    func testStatisticsCountOwnedAndOrderedBoardsOnly() {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = [
            Board(id: "1", name: "A", manufacturer: "Neo", color: "Schwarz", purchasePrice: 100),
            Board(id: "2", name: "B", manufacturer: "Neo", status: .ordered, purchasePrice: 300),
            Board(id: "3", name: "C", manufacturer: "Geon"),
            Board(id: "4", name: "D", manufacturer: "Alt", status: .sold, purchasePrice: 999),
            Board(id: "5", name: "E", manufacturer: "Traum", status: .wishlist, purchasePrice: 888)
        ]

        let statistics = InventoryStatistics(snapshot: snapshot)

        XCTAssertEqual(statistics.collectionBoardCount, 3)
        XCTAssertEqual(statistics.collectionValue, 400)
        XCTAssertEqual(statistics.averagePrice, 200)
        XCTAssertEqual(statistics.unpricedBoardCount, 1)
        XCTAssertEqual(statistics.byManufacturer.map(\.label), ["Neo", "Geon"])
        XCTAssertEqual(statistics.byManufacturer.first?.count, 2)
        XCTAssertEqual(statistics.byStatus.map(\.count), [2, 1, 1, 1])
        XCTAssertTrue(statistics.byColor.contains { $0.label == L10n.text("Ohne Angabe") && $0.count == 2 })
    }

    func testStatisticsFoldRareValuesAndFilterByStatusAndWeight() {
        let values = (1...12).map { "Marke \($0)" }
        let buckets = InventoryStatistics.buckets(values)
        XCTAssertEqual(buckets.count, InventoryStatistics.maximumBuckets)
        XCTAssertEqual(buckets.last?.label, L10n.text("Weitere"))
        XCTAssertEqual(buckets.map(\.count).reduce(0, +), 12)

        var snapshot = InventorySnapshot.empty
        snapshot.boards = [
            Board(id: "1", name: "Messing", weightMaterial: "Messing"),
            Board(id: "2", name: "Verkauft", weightMaterial: "Kupfer", status: .sold)
        ]
        var filters = InventoryFilters()
        filters.weightMaterial = "Messing"
        XCTAssertEqual(
            InventoryQuery.results(in: snapshot, kind: .board, filters: filters, sort: .name).map(\.name),
            ["Messing"]
        )
        filters = InventoryFilters()
        filters.status = BoardStatus.sold.title
        XCTAssertFalse(filters.isEmpty(for: .board))
        XCTAssertEqual(
            InventoryQuery.results(in: snapshot, kind: .board, filters: filters, sort: .name).map(\.name),
            ["Verkauft"]
        )
    }

    func testPrimaryNavigationUsesOverviewGalleryCaptureOrder() {
        XCTAssertEqual(AppRoute.primary, [.overview, .gallery, .capture])
    }

    func testPrimaryDetailSortUsesAConcreteLabelForEachInventoryKind() {
        XCTAssertEqual(InventorySort.primaryDetail.title(for: .board), "Format")
        XCTAssertEqual(InventorySort.primaryDetail.title(for: .keycapSet), "Profil")
        XCTAssertEqual(InventorySort.primaryDetail.title(for: .artisanSet), "Profil")
        XCTAssertEqual(InventorySort.primaryDetail.title(for: .switchSet), "Typ")
    }

    func testAllV1PinValuesHaveStableDisplayNames() {
        XCTAssertEqual(SwitchPins.three.rawValue, "3")
        XCTAssertEqual(SwitchPins.five.rawValue, "5")
        XCTAssertEqual(SwitchPins.hallEffect.rawValue, "HE")
        XCTAssertEqual(SwitchPins.three.displayName, "3 PIN")
        XCTAssertEqual(SwitchPins.five.displayName, "5 PIN")
        XCTAssertEqual(SwitchPins.hallEffect.displayName, "HE")
    }

    func testAvailableSwitchQuantityNeverBecomesNegative() {
        let switches = SwitchSet(id: "switches-a", name: "Test", quantity: 70)
        let installations = [
            SwitchInstallation(switchSetID: "switches-a", boardID: "board-a", quantity: 40),
            SwitchInstallation(switchSetID: "switches-a", boardID: "board-b", quantity: 45)
        ]

        XCTAssertEqual(switches.installedQuantity(in: installations), 85)
        XCTAssertEqual(switches.availableQuantity(in: installations), 0)
    }

    func testMainPhotoMustBelongToBoardPhotoIDs() {
        let valid = Board(id: "board-a", photoIDs: ["photo-a"], mainPhotoID: "photo-a")
        let invalid = Board(id: "board-b", photoIDs: [], mainPhotoID: "photo-a")

        XCTAssertTrue(valid.hasValidMainPhoto)
        XCTAssertFalse(invalid.hasValidMainPhoto)
    }

    func testLegacyImportedPhotoPrefixResolvesInsideManagedPhotosDirectory() {
        let legacy = PhotoRecord(
            id: "photo-a",
            owner: PhotoOwner(type: .board, id: "board-a"),
            originalName: "photo-a.jpg",
            mimeType: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            addedAt: .now,
            relativeFileName: "Photos/photo-a.jpg"
        )
        let unsafe = PhotoRecord(
            id: "photo-a",
            owner: PhotoOwner(type: .board, id: "board-a"),
            originalName: "photo-a.jpg",
            mimeType: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            addedAt: .now,
            relativeFileName: "Photos/../photo-a.jpg"
        )

        XCTAssertEqual(legacy.managedFileName, "photo-a.jpg")
        XCTAssertNil(unsafe.managedFileName)
    }

    func testSnapshotCountsAllInventoryKinds() {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = [Board(id: "board-a")]
        snapshot.keycapSets = [KeycapSet(id: "keycap-a")]
        snapshot.artisanSets = [ArtisanSet(id: "artisan-a")]
        snapshot.switchSets = [SwitchSet(id: "switch-a")]

        XCTAssertEqual(snapshot.counts.totalItems, 4)
        XCTAssertEqual(snapshot.counts.value(for: .switchSet), 1)
    }

    func testPresentationKeepsUniqueExternalImportImagesSeparateFromLocalPhotos() throws {
        var snapshot = InventorySnapshot.empty
        snapshot.keycapSets = [
            KeycapSet(
                id: "keycap-a",
                name: "Imported",
                photoIDs: ["local-photo"],
                coverURL: "https://example.com/cover.png",
                externalImageURLs: [
                    "https://example.com/cover.png",
                    "https://example.com/detail.png"
                ]
            )
        ]

        let item = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .keycapSet).first
        )

        XCTAssertEqual(item.photoCount, 1)
        XCTAssertEqual(item.externalImageCount, 2)
        XCTAssertEqual(
            item.externalImageURLs,
            [
                "https://example.com/cover.png",
                "https://example.com/detail.png"
            ]
        )
    }

    func testBoardSpotlightMetadataIncludesLinkedKeycapsAndSwitchQuantities() throws {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = [Board(id: "board-a", name: "Board", keycapSetID: "keycap-a")]
        snapshot.keycapSets = [KeycapSet(id: "keycap-a", name: "Keycaps")]
        snapshot.switchSets = [SwitchSet(id: "switch-a", name: "Switches")]
        snapshot.switchInstallations = [
            SwitchInstallation(switchSetID: "switch-a", boardID: "board-a", quantity: 68)
        ]

        let item = try XCTUnwrap(InventoryQuery.items(in: snapshot, kind: .board).first)
        let metadata = Dictionary(uniqueKeysWithValues: item.metadata.map { ($0.label, $0.value) })

        XCTAssertEqual(metadata[L10n.text("Keycaps")], "Keycaps")
        XCTAssertEqual(metadata[L10n.text("Switches")], "Switches · 68 Stück")
    }

    func testOverviewPresentationRestoresV1RelationsStockAndListsForAllKinds() throws {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = [
            Board(
                id: "board-a",
                name: "Board A",
                keycapSetID: "keycap-a",
                photoIDs: ["board-photo"],
                mainPhotoID: "board-photo"
            )
        ]
        snapshot.keycapSets = [
            KeycapSet(
                id: "keycap-a",
                name: "Keycaps A",
                kits: ["Base", "Numpad"],
                mountedBoardID: "board-a"
            )
        ]
        snapshot.artisanSets = [
            ArtisanSet(
                id: "artisan-a",
                name: "Artisan A",
                tags: ["Resin", "Blue"],
                mountedBoardID: "board-a"
            )
        ]
        snapshot.switchSets = [
            SwitchSet(
                id: "switch-a",
                name: "Switch A",
                switchType: "Linear",
                operatingForce: "55g",
                quantity: 105
            )
        ]
        snapshot.switchInstallations = [
            SwitchInstallation(
                switchSetID: "switch-a",
                boardID: "board-a",
                quantity: 87
            )
        ]

        let board = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .board).first
        )
        XCTAssertEqual(board.keycapsSummary, "Keycaps A")
        XCTAssertEqual(board.switchesSummary, "Switch A · 87 Stück")
        XCTAssertEqual(board.mainPhotoID, "board-photo")

        let keycaps = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .keycapSet).first
        )
        XCTAssertEqual(keycaps.contentsSummary, "Base, Numpad")
        XCTAssertEqual(keycaps.mountedBoardSummary, "Board A")

        let artisan = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .artisanSet).first
        )
        XCTAssertEqual(artisan.contentsSummary, "Resin, Blue")
        XCTAssertEqual(artisan.mountedBoardSummary, "Board A")

        let switches = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .switchSet).first
        )
        XCTAssertEqual(switches.stockSummary, "105 / 87 / 18")
        XCTAssertEqual(switches.mountedBoardSummary, "Board A (87)")
        XCTAssertEqual(switches.operatingForce, "55g")
    }

    func testOverviewBoardUsesLegacyNamesUntilRelationsCanBeResolved() throws {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = [
            Board(
                id: "board-a",
                name: "Board A",
                legacyKeycapsName: "Legacy Caps",
                legacySwitchesName: "Legacy Switches"
            )
        ]

        let board = try XCTUnwrap(
            InventoryQuery.items(in: snapshot, kind: .board).first
        )

        XCTAssertEqual(board.keycapsSummary, "Legacy Caps")
        XCTAssertEqual(board.switchesSummary, "Legacy Switches")
    }

    func testPerformanceFilteringAndSortingLargeBoardInventory() {
        var snapshot = InventorySnapshot.empty
        snapshot.boards = (0..<5_000).map { index in
            Board(
                id: "board-\(index)",
                name: index.isMultiple(of: 10) ? "Aurora \(index)" : "Board \(index)",
                manufacturer: index.isMultiple(of: 2) ? "Maker A" : "Maker B",
                format: index.isMultiple(of: 3) ? "65%" : "TKL",
                remark: "Performance fixture \(index)"
            )
        }
        let filters = InventoryFilters(searchText: "Aurora", manufacturer: "Maker A")

        measure {
            let results = InventoryQuery.results(
                in: snapshot,
                kind: .board,
                filters: filters,
                sort: .name
            )
            XCTAssertEqual(results.count, 500)
        }
    }
}
