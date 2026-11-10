import Foundation

/// Reads and writes CSV text (RFC 4180 quoting). Export uses semicolons and a
/// UTF-8 byte order mark, which German Excel opens correctly; import detects
/// semicolon, comma or tab from the header line.
enum CSVCodec {
    static func encode(_ rows: [[String]], delimiter: Character = ";") -> String {
        rows.map { row in
            row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }
        .joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func decode(_ text: String) -> [[String]] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delimiter = detectDelimiter(text)

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func nextCharacter() -> Character? {
            if let value = pending {
                pending = nil
                return value
            }
            return iterator.next()
        }

        while let character = nextCharacter() {
            if inQuotes {
                if character == "\"" {
                    if let following = nextCharacter() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                row.append(field)
                field = ""
            case "\r\n", "\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [";": 0, ",": 0, "\t": 0]
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, character == "\n" || character == "\r" || character == "\r\n" { break }
            if !inQuotes, counts[character] != nil { counts[character, default: 0] += 1 }
        }
        let best = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key != ";" : lhs.value < rhs.value
        }
        return (best?.value ?? 0) > 0 ? best!.key : ";"
    }
}

/// One CSV column: how it is written from and read into an editor draft.
/// Columns without `write` describe relations and are export-only.
struct InventoryCSVColumn {
    var header: String
    var read: (InventoryDraft, InventorySnapshot) -> String
    var write: ((inout InventoryDraft, String) throws -> Void)?
}

enum InventoryCSVError: LocalizedError, Equatable, Sendable {
    case empty
    case missingNameColumn
    case invalidValue(column: String, value: String)

    var errorDescription: String? {
        switch self {
        case .empty:
            L10n.text("Die CSV-Datei enthält keine Zeilen.")
        case .missingNameColumn:
            L10n.text("In der ersten Zeile fehlt die Spalte „Name“.")
        case let .invalidValue(column, value):
            L10n.text("„%@“ ist kein gültiger Wert für „%@“.", arguments: value, column)
        }
    }
}

struct InventoryCSVImportPreview: Sendable {
    struct RowIssue: Hashable, Sendable {
        var row: Int
        var name: String
        var message: String
    }

    var kind: InventoryItemKind
    var drafts: [InventoryDraft]
    var duplicates: [RowIssue]
    var errors: [RowIssue]
    var ignoredColumns: [String]
}

enum InventoryCSV {
    /// Purchase dates are calendar days in the user's time zone.
    static var dateFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
    }

    // MARK: Export

    static func export(
        _ snapshot: InventorySnapshot,
        kind: InventoryItemKind,
        ids: [String]? = nil
    ) -> String {
        let columns = columns(for: kind)
        let order = ids ?? InventoryQuery.items(in: snapshot, kind: kind).map(\.id)
        var rows = [columns.map(\.header)]
        for id in order {
            guard let draft = InventoryDraft(kind: kind, id: id, in: snapshot) else { continue }
            rows.append(columns.map { $0.read(draft, snapshot) })
        }
        return "\u{FEFF}" + CSVCodec.encode(rows)
    }

    static func defaultFileName(for kind: InventoryItemKind, date: Date = .now) -> String {
        let name = switch kind {
        case .board: "Keyboards"
        case .keycapSet: "Keycap-Sets"
        case .artisanSet: "Artisans"
        case .switchSet: "Switches"
        }
        return "Keyboard Manager \(name) \(date.formatted(dateFormat)).csv"
    }

    // MARK: Import

    /// Checks every row against the regular save rules without writing
    /// anything. Rows whose name already exists are skipped, so importing the
    /// same file twice creates no duplicates.
    static func preview(
        _ text: String,
        kind: InventoryItemKind,
        in snapshot: InventorySnapshot,
        now: Date = .now
    ) throws -> InventoryCSVImportPreview {
        let rows = CSVCodec.decode(text)
        guard let header = rows.first else { throw InventoryCSVError.empty }
        let columns = columns(for: kind)
        let mapping: [(index: Int, column: InventoryCSVColumn)] = header.enumerated().compactMap { index, title in
            let key = normalizedHeader(title)
            guard let column = columns.first(where: { normalizedHeader($0.header) == key }),
                  column.write != nil else { return nil }
            return (index, column)
        }
        guard mapping.contains(where: { normalizedHeader($0.column.header) == normalizedHeader("Name") }) else {
            throw InventoryCSVError.missingNameColumn
        }
        let writable = Set(columns.filter { $0.write != nil }.map { normalizedHeader($0.header) })
        let ignored = header.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !writable.contains(normalizedHeader($0))
        }

        var knownNames = Set(InventoryQuery.items(in: snapshot, kind: kind).map { nameKey($0.name) })
        var scratch = snapshot
        var drafts: [InventoryDraft] = []
        var duplicates: [InventoryCSVImportPreview.RowIssue] = []
        var errors: [InventoryCSVImportPreview.RowIssue] = []
        let editing = InventoryEditingService()

        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            var draft = InventoryDraft(kind: kind, createdAt: now)
            if kind == .board { draft.status = BoardStatus.owned.rawValue }
            do {
                for (index, column) in mapping where index < row.count {
                    try column.write?(&draft, row[index].trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                errors.append(.init(row: rowNumber, name: draft.normalizedName, message: error.localizedDescription))
                continue
            }
            guard !draft.normalizedName.isEmpty else {
                errors.append(.init(
                    row: rowNumber,
                    name: "",
                    message: InventoryEditingError.missingName.localizedDescription
                ))
                continue
            }
            guard knownNames.insert(nameKey(draft.normalizedName)).inserted else {
                duplicates.append(.init(
                    row: rowNumber,
                    name: draft.normalizedName,
                    message: L10n.text("Ein Eintrag mit diesem Namen ist schon vorhanden.")
                ))
                continue
            }
            do {
                scratch = try editing.saving(draft, newPhotos: [], in: scratch, now: now).snapshot
                drafts.append(draft)
            } catch {
                errors.append(.init(row: rowNumber, name: draft.normalizedName, message: error.localizedDescription))
            }
        }
        return InventoryCSVImportPreview(
            kind: kind,
            drafts: drafts,
            duplicates: duplicates,
            errors: errors,
            ignoredColumns: ignored
        )
    }

    private static func normalizedHeader(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    static func nameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    // MARK: Columns

    static func columns(for kind: InventoryItemKind) -> [InventoryCSVColumn] {
        switch kind {
        case .board:
            [
                text("Name", \.name),
                text("Hersteller", \.manufacturer),
                text("Format", \.format),
                text("Farbe", \.color),
                text("Gewicht-Material", \.weightMaterial),
                text("Gewicht (g)", \.weightGramsText),
                text("Layout", \.layout),
                text("Mounting", \.mounting),
                text("Case-Material", \.caseMaterial),
                text("Tippwinkel", \.typingAngle),
                text("Plate", \.plate),
                text("PCB", \.pcb),
                text("Stabilisatoren", \.stabilizers),
                boardStatus,
                InventoryCSVColumn(header: "Preis (€)", read: { draft, _ in
                    BoardValueFormat.parsePrice(draft.purchasePriceText)
                        .map { BoardValueFormat.priceText($0, language: .german) } ?? ""
                }, write: { draft, value in draft.purchasePriceText = value }),
                purchaseDate,
                text("Shop", \.purchaseShop),
                InventoryCSVColumn(header: "Keycap-Set", read: { draft, snapshot in
                    snapshot.keycapSets.first { $0.id == draft.keycapSetID }?.name ?? draft.legacyKeycapsName
                }, write: nil),
                InventoryCSVColumn(header: "Switches", read: { draft, snapshot in
                    let names = draft.installations.compactMap { id, quantity -> String? in
                        guard let name = snapshot.switchSets.first(where: { $0.id == id })?.name else { return nil }
                        return "\(name) (\(quantity))"
                    }
                    return names.isEmpty ? draft.legacySwitchesName : names.sorted().joined(separator: ", ")
                }, write: nil),
                text("Notizen", \.notes)
            ]
        case .keycapSet, .artisanSet:
            [
                text("Name", \.name),
                text("Hersteller", \.manufacturer),
                text("Profil", \.profile),
                text("Material", \.material),
                text("Status", \.status),
                InventoryCSVColumn(
                    header: kind == .keycapSet ? "Kits" : "Tags",
                    read: { draft, _ in draft.normalizedListEntries.joined(separator: ", ") },
                    write: { draft, value in draft.listEntries = value.components(separatedBy: ",") }
                ),
                text("Shop", \.sourceShop),
                text("Quelle", \.sourceURL),
                InventoryCSVColumn(header: "Board", read: { draft, snapshot in
                    snapshot.boards.first { $0.id == draft.mountedBoardID }?.name ?? ""
                }, write: nil),
                text("Notizen", \.notes)
            ]
        case .switchSet:
            [
                text("Name", \.name),
                text("Typ", \.switchType),
                InventoryCSVColumn(header: "Pins", read: { draft, _ in draft.pins.rawValue }, write: { draft, value in
                    guard !value.isEmpty else { return }
                    let compact = value.uppercased().replacingOccurrences(of: "PIN", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    guard let pins = SwitchPins(rawValue: compact) else {
                        throw InventoryCSVError.invalidValue(column: "Pins", value: value)
                    }
                    draft.pins = pins
                }),
                InventoryCSVColumn(header: "Bestand", read: { draft, _ in String(draft.quantity) }, write: { draft, value in
                    guard !value.isEmpty else { return }
                    guard let quantity = Int(value.filter { !$0.isWhitespace && $0 != "." }), quantity >= 0 else {
                        throw InventoryCSVError.invalidValue(column: "Bestand", value: value)
                    }
                    draft.quantity = quantity
                }),
                flag("LED-Diffusor", \.hasLEDDiffuser),
                flag("Werkseitig geschmiert", \.isFactoryLubed),
                text("Top Housing", \.topHousingMaterial),
                text("Bottom Housing", \.bottomHousingMaterial),
                text("Stem", \.stemMaterial),
                text("Federlänge", \.springLength),
                text("Federtyp", \.springType),
                text("Pre-Travel", \.preTravel),
                text("Total Travel", \.totalTravel),
                text("Operating Force", \.operatingForce),
                text("Bottom-out Force", \.bottomOutForce),
                InventoryCSVColumn(header: "Boards", read: { draft, snapshot in
                    draft.installations.compactMap { id, quantity -> String? in
                        guard let name = snapshot.boards.first(where: { $0.id == id })?.name else { return nil }
                        return "\(name) (\(quantity))"
                    }
                    .sorted()
                    .joined(separator: ", ")
                }, write: nil),
                text("Notizen", \.notes)
            ]
        }
    }

    private static func text(
        _ header: String,
        _ keyPath: WritableKeyPath<InventoryDraft, String>
    ) -> InventoryCSVColumn {
        InventoryCSVColumn(
            header: header,
            read: { draft, _ in draft[keyPath: keyPath] },
            write: { draft, value in draft[keyPath: keyPath] = value }
        )
    }

    private static func flag(
        _ header: String,
        _ keyPath: WritableKeyPath<InventoryDraft, Bool>
    ) -> InventoryCSVColumn {
        InventoryCSVColumn(
            header: header,
            read: { draft, _ in draft[keyPath: keyPath] ? "ja" : "nein" },
            write: { draft, value in
                switch value.lowercased() {
                case "": return
                case "ja", "yes", "true", "1", "x", "wahr": draft[keyPath: keyPath] = true
                case "nein", "no", "false", "0", "falsch": draft[keyPath: keyPath] = false
                default: throw InventoryCSVError.invalidValue(column: header, value: value)
                }
            }
        )
    }

    private static var boardStatus: InventoryCSVColumn { InventoryCSVColumn(
        header: "Status",
        read: { draft, _ in
            (BoardStatus(rawValue: draft.status) ?? .owned).title(language: "de")
        },
        write: { draft, value in
            guard !value.isEmpty else { return }
            let key = nameKey(value)
            let match = BoardStatus.allCases.first { status in
                [status.rawValue, status.title(language: "de"), status.title(language: "en")]
                    .map(nameKey)
                    .contains(key)
            }
            guard let match else {
                throw InventoryCSVError.invalidValue(column: "Status", value: value)
            }
            draft.status = match.rawValue
        }
    ) }

    private static var purchaseDate: InventoryCSVColumn { InventoryCSVColumn(
        header: "Kaufdatum",
        read: { draft, _ in draft.purchaseDate?.formatted(dateFormat) ?? "" },
        write: { draft, value in
            guard !value.isEmpty else {
                draft.purchaseDate = nil
                return
            }
            guard let date = parseDate(value) else {
                throw InventoryCSVError.invalidValue(column: "Kaufdatum", value: value)
            }
            draft.purchaseDate = date
        }
    ) }

    /// Accepts 2026-11-10 and 10.11.2026.
    static func parseDate(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: dateFormat) {
            return date
        }
        let parts = value.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let day = parts[0], let month = parts[1], var year = parts[2] else {
            return nil
        }
        if year < 100 { year += 2000 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}
