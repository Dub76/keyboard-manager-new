import Foundation

enum InventoryReportBuilder {
    static func build(
        snapshot: InventorySnapshot,
        context: InventoryReportContext,
        options: InventoryReportOptions,
        createdAt: Date = .now,
        appVersion: String
    ) throws -> InventoryReport {
        let language = AppLanguage.normalized(snapshot.metadata.preferredLanguage).rawValue
        let kinds = options.scope == .all ? InventoryItemKind.allCases : [context.currentKind]
        let sections = try kinds.map { kind in
            try section(
                kind: kind,
                snapshot: snapshot,
                filters: options.appliesFilters
                    ? context.filtersByKind[kind, default: InventoryFilters()]
                    : InventoryFilters(),
                sort: context.sortsByKind[kind, default: .name],
                appliesFilters: options.appliesFilters,
                language: language
            )
        }
        guard sections.reduce(0, { $0 + $1.rows.count }) <= 40_000 else {
            throw InventoryReportError.tooManyRows
        }
        return InventoryReport(
            language: language,
            createdAt: createdAt,
            appVersion: appVersion,
            scope: options.scope,
            appliesFilters: options.appliesFilters,
            includesImages: options.format == .pdf && options.includesImages,
            sections: sections,
            photosByID: Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        )
    }

    private static func section(
        kind: InventoryItemKind,
        snapshot: InventorySnapshot,
        filters: InventoryFilters,
        sort: InventorySort,
        appliesFilters: Bool,
        language: String
    ) throws -> InventoryReportSection {
        let summaries = InventoryQuery.results(
            in: snapshot,
            kind: kind,
            filters: filters,
            sort: sort
        )
        let positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
        let rows: [InventoryReportRow]
        let columns: [InventoryReportColumn]

        switch kind {
        case .board:
            columns = boardColumns(language: language)
            let keycaps = Dictionary(uniqueKeysWithValues: snapshot.keycapSets.map { ($0.id, $0.name) })
            let switches = Dictionary(uniqueKeysWithValues: snapshot.switchSets.map { ($0.id, $0.name) })
            let installations = Dictionary(grouping: snapshot.switchInstallations, by: \.boardID)
            rows = snapshot.boards
                .filter { positions[$0.id] != nil }
                .sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
                .map { board in
                    let switchNames = installations[board.id, default: []]
                        .compactMap { switches[$0.switchSetID] }
                        .sorted()
                        .joined(separator: ", ")
                    return row(
                        id: board.id,
                        values: [
                            .text(board.name), .text(board.manufacturer), .text(board.format),
                            .text(board.color), .text(board.weightMaterial),
                            .text(board.status.title(language: language)),
                            .text(board.purchasePrice.map {
                                BoardValueFormat.displayPrice($0, language: AppLanguage.normalized(language))
                            } ?? ""),
                            board.purchaseDate.map(InventoryReportValue.date) ?? .text(""),
                            .text(board.purchaseShop), .text(board.layout), .text(board.mounting),
                            .text(board.caseMaterial), .text(board.typingAngle),
                            board.weightGrams.map(InventoryReportValue.number) ?? .text(""),
                            .text(board.plate), .text(board.pcb),
                            .text(switchNames.nilIfEmpty ?? board.legacySwitchesName),
                            .text(board.keycapSetID.flatMap { keycaps[$0] } ?? board.legacyKeycapsName),
                            .text(board.stabilizers), .number(board.photoIDs.count),
                            .text(board.remark), .date(board.updatedAt)
                        ],
                        mainPhotoID: board.mainPhotoID
                    )
                }
        case .keycapSet:
            columns = keycapColumns(language: language)
            rows = componentRows(
                components: snapshot.keycapSets,
                positions: positions,
                boards: snapshot.boards,
                values: { item, boardName in
                    [
                        .text(item.name), .text(item.manufacturer), .text(item.profile),
                        .text(item.material), .text(item.status),
                        .text(item.kits.joined(separator: ", ")), .text(boardName),
                        .text(item.sourceShop), .url(item.sourceURL), .text(item.notes),
                        .number(item.photoIDs.count), .date(item.updatedAt)
                    ]
                }
            )
        case .artisanSet:
            columns = artisanColumns(language: language)
            rows = componentRows(
                components: snapshot.artisanSets,
                positions: positions,
                boards: snapshot.boards,
                values: { item, boardName in
                    [
                        .text(item.name), .text(item.manufacturer), .text(item.profile),
                        .text(item.material), .text(item.status),
                        .text(item.tags.joined(separator: ", ")), .text(boardName),
                        .text(item.sourceShop), .url(item.sourceURL), .text(item.notes),
                        .number(item.photoIDs.count), .date(item.updatedAt)
                    ]
                }
            )
        case .switchSet:
            columns = switchColumns(language: language)
            let boardNames = Dictionary(uniqueKeysWithValues: snapshot.boards.map { ($0.id, $0.name) })
            let installations = Dictionary(grouping: snapshot.switchInstallations, by: \.switchSetID)
            rows = snapshot.switchSets
                .filter { positions[$0.id] != nil }
                .sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
                .map { item in
                    let installed = item.installedQuantity(in: snapshot.switchInstallations)
                    let boards = installations[item.id, default: []]
                        .compactMap { boardNames[$0.boardID] }
                        .sorted()
                        .joined(separator: ", ")
                    return row(
                        id: item.id,
                        values: [
                            .text(item.name), .text(item.switchType),
                            .text(item.topHousingMaterial), .text(item.bottomHousingMaterial),
                            .text(item.stemMaterial), .text(item.springLength),
                            .text(item.springType), .text(item.preTravel),
                            .text(item.totalTravel), .text(item.operatingForce),
                            .text(item.bottomOutForce), .text(item.pins.displayName),
                            .text(L10n.text(item.hasLEDDiffuser ? "Ja" : "Nein", language: language)),
                            .text(L10n.text(item.isFactoryLubed ? "Ja" : "Nein", language: language)),
                            .number(item.quantity), .number(installed),
                            .number(item.availableQuantity(in: snapshot.switchInstallations)),
                            .text(boards), .text(item.notes),
                            .number(item.photoIDs.count), .date(item.updatedAt)
                        ],
                        mainPhotoID: item.mainPhotoID
                    )
                }
        }

        guard columns.count <= 32 else { throw InventoryReportError.tooManyColumns }
        return InventoryReportSection(
            kind: kind,
            title: kind.displayName(language: language),
            columns: columns,
            rows: rows,
            filterDescription: filterDescription(
                filters,
                kind: kind,
                appliesFilters: appliesFilters,
                language: language
            )
        )
    }

    private static func componentRows<Component>(
        components: [Component],
        positions: [String: Int],
        boards: [Board],
        values: (Component, String) -> [InventoryReportValue]
    ) -> [InventoryReportRow] where Component: Identifiable, Component.ID == String {
        let boardNames = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0.name) })
        return components
            .filter { positions[$0.id] != nil }
            .sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
            .compactMap { component in
                if let item = component as? KeycapSet {
                    return row(
                        id: item.id,
                        values: values(component, item.mountedBoardID.flatMap { boardNames[$0] } ?? ""),
                        mainPhotoID: item.mainPhotoID
                    )
                }
                if let item = component as? ArtisanSet {
                    return row(
                        id: item.id,
                        values: values(component, item.mountedBoardID.flatMap { boardNames[$0] } ?? ""),
                        mainPhotoID: item.mainPhotoID
                    )
                }
                return nil
            }
    }

    private static func row(
        id: String,
        values: [InventoryReportValue],
        mainPhotoID: String?
    ) -> InventoryReportRow {
        InventoryReportRow(
            id: id,
            values: values.map {
                guard $0.displayText.count > 20_000 else { return $0 }
                return .text(String($0.displayText.prefix(20_000)))
            },
            mainPhotoID: mainPhotoID
        )
    }

    private static func filterDescription(
        _ filters: InventoryFilters,
        kind: InventoryItemKind,
        appliesFilters: Bool,
        language: String
    ) -> String {
        guard appliesFilters else { return L10n.text("Nicht angewendet", language: language) }
        var parts: [String] = []
        if !filters.searchText.isEmpty {
            parts.append(L10n.text("Suche: %@", language: language, arguments: filters.searchText))
        }
        if !filters.manufacturer.isEmpty {
            parts.append(L10n.text("Hersteller: %@", language: language, arguments: filters.manufacturer))
        }
        if !filters.format.isEmpty {
            parts.append(L10n.text("Format: %@", language: language, arguments: filters.format))
        }
        if !filters.color.isEmpty {
            parts.append(L10n.text("Farbe: %@", language: language, arguments: filters.color))
        }
        if !filters.profile.isEmpty {
            parts.append(L10n.text("Profil: %@", language: language, arguments: filters.profile))
        }
        if !filters.weightMaterial.isEmpty {
            parts.append(L10n.text("Gewicht-Material: %@", language: language, arguments: filters.weightMaterial))
        }
        if !filters.status.isEmpty {
            parts.append(L10n.text("Status: %@", language: language, arguments: filters.status))
        }
        if !filters.switchType.isEmpty {
            parts.append(L10n.text("Typ: %@", language: language, arguments: filters.switchType))
        }
        if !filters.operatingForce.isEmpty {
            parts.append(L10n.text("Kraft: %@", language: language, arguments: filters.operatingForce))
        }
        if let pins = filters.pins {
            parts.append(L10n.text("Pins: %@", language: language, arguments: pins.displayName))
        }
        return parts.isEmpty || filters.isEmpty(for: kind)
            ? L10n.text("Keine aktiven Filter", language: language)
            : parts.joined(separator: " · ")
    }

    private static func column(_ title: String, _ width: Double, pdf: Bool = false) -> InventoryReportColumn {
        InventoryReportColumn(title: title, width: width, isPDFVisible: pdf)
    }

    private static func localizedColumn(
        _ title: String,
        _ width: Double,
        pdf: Bool = false,
        language: String
    ) -> InventoryReportColumn {
        column(L10n.text(title, language: language), width, pdf: pdf)
    }

    private static func boardColumns(language: String) -> [InventoryReportColumn] {
        [
            localizedColumn("Name", 24, pdf: true, language: language),
            localizedColumn("Hersteller", 18, pdf: true, language: language),
            localizedColumn("Format", 12, pdf: true, language: language),
            localizedColumn("Farbe", 14, language: language),
            localizedColumn("Gewicht-Material", 18, language: language),
            localizedColumn("Status", 12, language: language),
            localizedColumn("Preis", 12, language: language),
            localizedColumn("Kaufdatum", 14, language: language),
            localizedColumn("Shop", 16, language: language),
            localizedColumn("Layout", 10, language: language),
            localizedColumn("Mounting", 14, language: language),
            localizedColumn("Case-Material", 16, language: language),
            localizedColumn("Tippwinkel", 10, language: language),
            localizedColumn("Gewicht (g)", 11, language: language),
            localizedColumn("Plate", 16, language: language),
            localizedColumn("PCB", 18, language: language),
            localizedColumn("Switches", 22, pdf: true, language: language),
            localizedColumn("Keycaps", 22, pdf: true, language: language),
            localizedColumn("Stabilisatoren", 18, language: language),
            localizedColumn("Fotos", 9, language: language),
            localizedColumn("Notizen", 34, language: language),
            localizedColumn("Geändert", 19, language: language)
        ]
    }

    private static func keycapColumns(language: String) -> [InventoryReportColumn] {
        componentColumns(listTitle: "Kits", language: language)
    }

    private static func artisanColumns(language: String) -> [InventoryReportColumn] {
        componentColumns(listTitle: "Tags", language: language)
    }

    private static func componentColumns(
        listTitle: String,
        language: String
    ) -> [InventoryReportColumn] {
        [
            localizedColumn("Name", 24, pdf: true, language: language),
            localizedColumn("Hersteller", 18, pdf: true, language: language),
            localizedColumn("Profil", 12, pdf: true, language: language),
            localizedColumn("Material", 13, language: language),
            localizedColumn("Status", 12, pdf: true, language: language),
            localizedColumn(listTitle, 28, pdf: true, language: language),
            localizedColumn("Keyboard", 22, pdf: true, language: language),
            localizedColumn("Quelle", 18, language: language),
            localizedColumn("Quell-URL", 34, language: language),
            localizedColumn("Notizen", 34, language: language),
            localizedColumn("Fotos", 9, language: language),
            localizedColumn("Geändert", 19, language: language)
        ]
    }

    private static func switchColumns(language: String) -> [InventoryReportColumn] {
        [
            localizedColumn("Name", 23, pdf: true, language: language),
            localizedColumn("Typ", 14, pdf: true, language: language),
            localizedColumn("Top Housing", 16, language: language),
            localizedColumn("Bottom Housing", 16, language: language),
            localizedColumn("Stem", 14, language: language),
            localizedColumn("Federlänge", 12, language: language),
            localizedColumn("Federtyp", 13, language: language),
            localizedColumn("Pre-Travel", 12, language: language),
            localizedColumn("Gesamtweg", 12, language: language),
            localizedColumn("Betätigung", 13, pdf: true, language: language),
            localizedColumn("Bottom-out", 13, language: language),
            localizedColumn("Pins", 9, language: language),
            localizedColumn("LED-Diffusor", 11, language: language),
            localizedColumn("Werkseitig geschmiert", 17, language: language),
            localizedColumn("Gesamt", 10, pdf: true, language: language),
            localizedColumn("Verbaut", 10, pdf: true, language: language),
            localizedColumn("Verfügbar", 10, pdf: true, language: language),
            localizedColumn("Keyboards", 26, pdf: true, language: language),
            localizedColumn("Notizen", 34, language: language),
            localizedColumn("Fotos", 9, language: language),
            localizedColumn("Geändert", 19, language: language)
        ]
    }
}
