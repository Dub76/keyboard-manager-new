import Foundation

struct InventoryMetadataValue: Hashable, Sendable {
    var label: String
    var value: String
}

struct InventoryItemSummary: Identifiable, Hashable, Sendable {
    var id: String
    var kind: InventoryItemKind
    var name: String
    var manufacturer: String
    var primaryDetail: String
    var secondaryDetail: String
    var format: String
    var color = ""
    var weightMaterial = ""
    var priceText = ""
    var profile: String
    var status: String
    var switchType: String
    var operatingForce: String
    var pins: SwitchPins?
    var quantity: Int?
    var stockSummary: String
    var mountedBoardSummary: String
    var keycapsSummary: String
    var switchesSummary: String
    var contentsSummary: String
    var notes: String
    var sourceURL: String
    var photoIDs: [String]
    var mainPhotoID: String?
    var externalImageURLs: [String]
    var metadata: [InventoryMetadataValue]
    var updatedAt: Date

    var photoCount: Int { photoIDs.count }
    var externalImageCount: Int { externalImageURLs.count }

    var searchableText: String {
        (
            [
                name,
                manufacturer,
                primaryDetail,
                secondaryDetail,
                stockSummary,
                mountedBoardSummary,
                keycapsSummary,
                switchesSummary,
                contentsSummary,
                notes
            ]
                + metadata.flatMap { [$0.label, $0.value] }
        )
        .joined(separator: " ")
    }
}

struct InventoryFilters: Equatable, Sendable {
    var searchText = ""
    var manufacturer = ""
    var format = ""
    var color = ""
    var weightMaterial = ""
    var profile = ""
    var status = ""
    var switchType = ""
    var operatingForce = ""
    var pins: SwitchPins?

    func isEmpty(for kind: InventoryItemKind) -> Bool {
        guard searchText.isEmpty else { return false }
        switch kind {
        case .board:
            return manufacturer.isEmpty && format.isEmpty && color.isEmpty
                && weightMaterial.isEmpty && status.isEmpty
        case .keycapSet, .artisanSet:
            return manufacturer.isEmpty && profile.isEmpty && status.isEmpty
        case .switchSet:
            return switchType.isEmpty && operatingForce.isEmpty && pins == nil
        }
    }
}

/// Key figures of the keyboard collection. The value and the breakdowns
/// cover boards that are owned or ordered; sold boards and wishes appear
/// only in the status breakdown.
struct InventoryStatistics: Equatable, Sendable {
    struct Bucket: Identifiable, Equatable, Sendable {
        var label: String
        var count: Int
        var id: String { label }
    }

    static let maximumBuckets = 8

    var collectionBoardCount = 0
    var collectionValue: Decimal = 0
    var pricedBoardCount = 0
    var averagePrice: Decimal?
    var byStatus: [Bucket] = []
    var byManufacturer: [Bucket] = []
    var byFormat: [Bucket] = []
    var byColor: [Bucket] = []
    var byWeightMaterial: [Bucket] = []

    var unpricedBoardCount: Int { collectionBoardCount - pricedBoardCount }

    init(snapshot: InventorySnapshot) {
        byStatus = BoardStatus.allCases.compactMap { status in
            let count = snapshot.boards.filter { $0.status == status }.count
            return count > 0 ? Bucket(label: status.title, count: count) : nil
        }
        let boards = snapshot.boards.filter(\.status.countsTowardsCollection)
        collectionBoardCount = boards.count
        let prices = boards.compactMap(\.purchasePrice)
        pricedBoardCount = prices.count
        collectionValue = prices.reduce(0, +)
        averagePrice = prices.isEmpty ? nil : collectionValue / Decimal(prices.count)
        byManufacturer = Self.buckets(boards.map(\.manufacturer))
        byFormat = Self.buckets(boards.map(\.format))
        byColor = Self.buckets(boards.map(\.color))
        byWeightMaterial = Self.buckets(boards.map(\.weightMaterial))
    }

    /// Largest groups first; everything beyond the limit folds into "Weitere".
    static func buckets(_ values: [String]) -> [Bucket] {
        let groups = Dictionary(grouping: values) { value in
            value.isEmpty ? L10n.text("Ohne Angabe") : value
        }
        let sorted = groups
            .map { Bucket(label: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        guard sorted.count > maximumBuckets else { return sorted }
        let rest = sorted.dropFirst(maximumBuckets - 1).reduce(0) { $0 + $1.count }
        return Array(sorted.prefix(maximumBuckets - 1)) + [Bucket(label: L10n.text("Weitere"), count: rest)]
    }
}

enum InventorySort: String, CaseIterable, Identifiable, Sendable {
    case name
    case manufacturer
    case primaryDetail
    case recentlyUpdated
    case quantityDescending

    var id: Self { self }

    func title(for kind: InventoryItemKind) -> String {
        switch self {
        case .name: L10n.text("Name")
        case .manufacturer: L10n.text("Hersteller")
        case .primaryDetail:
            switch kind {
            case .board:
                L10n.text("Format")
            case .keycapSet, .artisanSet:
                L10n.text("Profil")
            case .switchSet:
                L10n.text("Typ")
            }
        case .recentlyUpdated: L10n.text("Zuletzt geändert")
        case .quantityDescending: L10n.text("Menge absteigend")
        }
    }

    static func available(for kind: InventoryItemKind) -> [InventorySort] {
        switch kind {
        case .board, .keycapSet, .artisanSet:
            [.name, .manufacturer, .primaryDetail, .recentlyUpdated]
        case .switchSet:
            [.name, .primaryDetail, .quantityDescending, .recentlyUpdated]
        }
    }
}

enum InventoryQuery {
    static let galleryKinds: [InventoryItemKind] = [.board, .keycapSet, .artisanSet]

    static func items(in snapshot: InventorySnapshot, kind: InventoryItemKind) -> [InventoryItemSummary] {
        switch kind {
        case .board:
            snapshot.boards.map { board in
                let keycaps = board.keycapSetID
                    .flatMap { keycapID in
                        snapshot.keycapSets.first(where: { $0.id == keycapID })?.name
                    }
                    ?? board.legacyKeycapsName
                let switchInstallations = snapshot.switchInstallations
                    .filter { $0.boardID == board.id }
                let resolvedSwitches = switchInstallations.compactMap { installation in
                    guard let switchSet = snapshot.switchSets.first(
                        where: { $0.id == installation.switchSetID }
                    ) else {
                        return nil
                    }
                    return L10n.text(
                        "%@ · %lld Stück",
                        arguments: switchSet.name,
                        installation.quantity
                    )
                }
                .joined(separator: ", ")
                let switches = resolvedSwitches.isEmpty
                    ? board.legacySwitchesName
                    : resolvedSwitches
                return InventoryItemSummary(
                    id: board.id,
                    kind: .board,
                    name: board.name,
                    manufacturer: board.manufacturer,
                    primaryDetail: board.format,
                    secondaryDetail: [board.pcb, board.plate].filter { !$0.isEmpty }.joined(separator: " · "),
                    format: board.format,
                    color: board.color,
                    weightMaterial: board.weightMaterial,
                    priceText: board.purchasePrice.map { BoardValueFormat.displayPrice($0) } ?? "",
                    profile: "",
                    status: board.status.title,
                    switchType: "",
                    operatingForce: "",
                    pins: nil,
                    quantity: nil,
                    stockSummary: "",
                    mountedBoardSummary: "",
                    keycapsSummary: keycaps,
                    switchesSummary: switches,
                    contentsSummary: "",
                    notes: board.remark,
                    sourceURL: "",
                    photoIDs: board.photoIDs,
                    mainPhotoID: board.mainPhotoID,
                    externalImageURLs: [],
                    metadata: [
                        .init(label: L10n.text("Hersteller"), value: board.manufacturer),
                        .init(label: L10n.text("Format"), value: board.format),
                        .init(label: L10n.text("Farbe"), value: board.color),
                        .init(label: L10n.text("Gewicht-Material"), value: board.weightMaterial),
                        .init(label: L10n.text("Gewicht (g)"), value: board.weightGrams.map(String.init) ?? ""),
                        .init(label: L10n.text("Status"), value: board.status.title),
                        .init(
                            label: L10n.text("Preis"),
                            value: board.purchasePrice.map { BoardValueFormat.displayPrice($0) } ?? ""
                        ),
                        .init(
                            label: L10n.text("Kaufdatum"),
                            value: board.purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
                        ),
                        .init(label: L10n.text("Shop"), value: board.purchaseShop),
                        .init(label: L10n.text("Layout"), value: board.layout),
                        .init(label: L10n.text("Mounting"), value: board.mounting),
                        .init(label: L10n.text("Case-Material"), value: board.caseMaterial),
                        .init(label: L10n.text("Tippwinkel"), value: board.typingAngle),
                        .init(label: "PCB", value: board.pcb),
                        .init(label: "Plate", value: board.plate),
                        .init(label: L10n.text("Stabilisatoren"), value: board.stabilizers),
                        .init(label: L10n.text("Keycaps"), value: keycaps),
                        .init(label: L10n.text("Switches"), value: switches)
                    ],
                    updatedAt: board.updatedAt
                )
            }
        case .keycapSet:
            snapshot.keycapSets.map { keycapSet in
                let mountedBoard = keycapSet.mountedBoardID
                    .flatMap { boardID in
                        snapshot.boards.first(where: { $0.id == boardID })?.name
                    }
                    ?? ""
                return InventoryItemSummary(
                    id: keycapSet.id,
                    kind: .keycapSet,
                    name: keycapSet.name,
                    manufacturer: keycapSet.manufacturer,
                    primaryDetail: keycapSet.profile,
                    secondaryDetail: keycapSet.status,
                    format: "",
                    profile: keycapSet.profile,
                    status: keycapSet.status,
                    switchType: "",
                    operatingForce: "",
                    pins: nil,
                    quantity: nil,
                    stockSummary: "",
                    mountedBoardSummary: mountedBoard,
                    keycapsSummary: "",
                    switchesSummary: "",
                    contentsSummary: keycapSet.kits.joined(separator: ", "),
                    notes: keycapSet.notes,
                    sourceURL: keycapSet.sourceURL,
                    photoIDs: keycapSet.photoIDs,
                    mainPhotoID: keycapSet.mainPhotoID,
                    externalImageURLs: uniqueExternalImageURLs(
                        coverURL: keycapSet.coverURL,
                        additionalURLs: keycapSet.externalImageURLs
                    ),
                    metadata: [
                        .init(label: L10n.text("Hersteller"), value: keycapSet.manufacturer),
                        .init(label: L10n.text("Profil"), value: keycapSet.profile),
                        .init(label: L10n.text("Material"), value: keycapSet.material),
                        .init(label: L10n.text("Status"), value: keycapSet.status),
                        .init(label: "Kits", value: keycapSet.kits.joined(separator: ", ")),
                        .init(label: L10n.text("Board"), value: mountedBoard),
                        .init(label: L10n.text("Shop"), value: keycapSet.sourceShop)
                    ],
                    updatedAt: keycapSet.updatedAt
                )
            }
        case .artisanSet:
            snapshot.artisanSets.map { artisanSet in
                let mountedBoard = artisanSet.mountedBoardID
                    .flatMap { boardID in
                        snapshot.boards.first(where: { $0.id == boardID })?.name
                    }
                    ?? ""
                return InventoryItemSummary(
                    id: artisanSet.id,
                    kind: .artisanSet,
                    name: artisanSet.name,
                    manufacturer: artisanSet.manufacturer,
                    primaryDetail: artisanSet.profile,
                    secondaryDetail: artisanSet.status,
                    format: "",
                    profile: artisanSet.profile,
                    status: artisanSet.status,
                    switchType: "",
                    operatingForce: "",
                    pins: nil,
                    quantity: nil,
                    stockSummary: "",
                    mountedBoardSummary: mountedBoard,
                    keycapsSummary: "",
                    switchesSummary: "",
                    contentsSummary: artisanSet.tags.joined(separator: ", "),
                    notes: artisanSet.notes,
                    sourceURL: artisanSet.sourceURL,
                    photoIDs: artisanSet.photoIDs,
                    mainPhotoID: artisanSet.mainPhotoID,
                    externalImageURLs: uniqueExternalImageURLs(
                        coverURL: artisanSet.coverURL,
                        additionalURLs: artisanSet.externalImageURLs
                    ),
                    metadata: [
                        .init(label: L10n.text("Hersteller"), value: artisanSet.manufacturer),
                        .init(label: L10n.text("Profil"), value: artisanSet.profile),
                        .init(label: L10n.text("Material"), value: artisanSet.material),
                        .init(label: L10n.text("Status"), value: artisanSet.status),
                        .init(label: "Tags", value: artisanSet.tags.joined(separator: ", ")),
                        .init(label: L10n.text("Board"), value: mountedBoard),
                        .init(label: L10n.text("Shop"), value: artisanSet.sourceShop)
                    ],
                    updatedAt: artisanSet.updatedAt
                )
            }
        case .switchSet:
            snapshot.switchSets.map { switchSet in
                let installed = switchSet.installedQuantity(in: snapshot.switchInstallations)
                let available = switchSet.availableQuantity(in: snapshot.switchInstallations)
                let mountedBoards = snapshot.switchInstallations
                    .filter { $0.switchSetID == switchSet.id }
                    .compactMap { installation -> (name: String, quantity: Int)? in
                        guard let board = snapshot.boards.first(
                                where: { $0.id == installation.boardID }
                              ) else {
                            return nil
                        }
                        return (board.name, installation.quantity)
                    }
                    .sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    .map {
                        $0.quantity > 0
                            ? "\($0.name) (\($0.quantity))"
                            : $0.name
                    }
                    .joined(separator: ", ")
                return InventoryItemSummary(
                    id: switchSet.id,
                    kind: .switchSet,
                    name: switchSet.name,
                    manufacturer: "",
                    primaryDetail: switchSet.switchType,
                    secondaryDetail: switchSet.pins.displayName,
                    format: "",
                    profile: "",
                    status: "",
                    switchType: switchSet.switchType,
                    operatingForce: switchSet.operatingForce,
                    pins: switchSet.pins,
                    quantity: switchSet.quantity,
                    stockSummary: "\(switchSet.quantity) / \(installed) / \(available)",
                    mountedBoardSummary: mountedBoards,
                    keycapsSummary: "",
                    switchesSummary: "",
                    contentsSummary: "",
                    notes: switchSet.notes,
                    sourceURL: "",
                    photoIDs: switchSet.photoIDs,
                    mainPhotoID: switchSet.mainPhotoID,
                    externalImageURLs: [],
                    metadata: [
                        .init(label: L10n.text("Typ"), value: switchSet.switchType),
                        .init(label: L10n.text("Pins"), value: switchSet.pins.displayName),
                        .init(label: L10n.text("Betätigungskraft"), value: switchSet.operatingForce),
                        .init(label: "Bottom-out", value: switchSet.bottomOutForce),
                        .init(label: L10n.text("Gesamt"), value: "\(switchSet.quantity)"),
                        .init(label: L10n.text("Verbaut"), value: "\(installed)"),
                        .init(label: L10n.text("Verfügbar"), value: "\(available)"),
                        .init(label: L10n.text("Board"), value: mountedBoards)
                    ],
                    updatedAt: switchSet.updatedAt
                )
            }
        }
    }

    static func results(
        in snapshot: InventorySnapshot,
        kind: InventoryItemKind,
        filters: InventoryFilters,
        sort: InventorySort
    ) -> [InventoryItemSummary] {
        items(in: snapshot, kind: kind)
            .filter { item in
                matchesSearch(item, searchText: filters.searchText)
                    && matchesExact(item.manufacturer, filters.manufacturer)
                    && matchesExact(item.format, filters.format)
                    && matchesExact(item.color, filters.color)
                    && matchesExact(item.weightMaterial, filters.weightMaterial)
                    && matchesExact(item.profile, filters.profile)
                    && matchesExact(item.status, filters.status)
                    && matchesExact(item.switchType, filters.switchType)
                    && matchesExact(item.operatingForce, filters.operatingForce)
                    && (filters.pins == nil || item.pins == filters.pins)
            }
            .sorted { lhs, rhs in
                compare(lhs, rhs, by: sort)
            }
    }

    private static func uniqueExternalImageURLs(
        coverURL: String,
        additionalURLs: [String]
    ) -> [String] {
        var seen = Set<String>()
        return ([coverURL] + additionalURLs).filter { value in
            !value.isEmpty && seen.insert(value).inserted
        }
    }

    static func values(
        _ keyPath: KeyPath<InventoryItemSummary, String>,
        in items: [InventoryItemSummary]
    ) -> [String] {
        Array(Set(items.map { $0[keyPath: keyPath] }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func matchesSearch(_ item: InventoryItemSummary, searchText: String) -> Bool {
        let needle = normalized(searchText)
        return needle.isEmpty || normalized(item.searchableText).contains(needle)
    }

    private static func matchesExact(_ value: String, _ filter: String) -> Bool {
        filter.isEmpty || normalized(value) == normalized(filter)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private static func compare(
        _ lhs: InventoryItemSummary,
        _ rhs: InventoryItemSummary,
        by sort: InventorySort
    ) -> Bool {
        switch sort {
        case .name:
            return ordered(lhs.name, before: rhs.name, tieBreaker: lhs.id, rhs.id)
        case .manufacturer:
            return ordered(lhs.manufacturer, before: rhs.manufacturer, tieBreaker: lhs.name, rhs.name)
        case .primaryDetail:
            return ordered(lhs.primaryDetail, before: rhs.primaryDetail, tieBreaker: lhs.name, rhs.name)
        case .recentlyUpdated:
            return lhs.updatedAt == rhs.updatedAt
                ? ordered(lhs.name, before: rhs.name, tieBreaker: lhs.id, rhs.id)
                : lhs.updatedAt > rhs.updatedAt
        case .quantityDescending:
            let leftQuantity = lhs.quantity ?? 0
            let rightQuantity = rhs.quantity ?? 0
            return leftQuantity == rightQuantity
                ? ordered(lhs.name, before: rhs.name, tieBreaker: lhs.id, rhs.id)
                : leftQuantity > rightQuantity
        }
    }

    private static func ordered(
        _ lhs: String,
        before rhs: String,
        tieBreaker lhsTie: String,
        _ rhsTie: String
    ) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        if result == .orderedSame {
            return lhsTie.localizedStandardCompare(rhsTie) == .orderedAscending
        }
        return result == .orderedAscending
    }
}
