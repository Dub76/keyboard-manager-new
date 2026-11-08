import Foundation

enum BoardStatus: String, CaseIterable, Identifiable, Hashable, Sendable {
    case owned
    case ordered
    case sold
    case wishlist

    var id: Self { self }

    var title: String {
        title(language: nil)
    }

    func title(language: String?) -> String {
        switch self {
        case .owned: L10n.text("Vorhanden", language: language)
        case .ordered: L10n.text("Bestellt", language: language)
        case .sold: L10n.text("Verkauft", language: language)
        case .wishlist: L10n.text("Wunschliste", language: language)
        }
    }

    /// Owned and ordered boards are paid for and count towards the collection.
    var countsTowardsCollection: Bool {
        self == .owned || self == .ordered
    }
}

/// Reads and writes the free-text number fields of the board editor.
enum BoardValueFormat {
    static func priceText(_ price: Decimal, language: AppLanguage = .current) -> String {
        let text = NSDecimalNumber(decimal: price).stringValue
        return language == .german ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    static func displayPrice(_ price: Decimal, language: AppLanguage = .current) -> String {
        price.formatted(.currency(code: "EUR").locale(language.locale))
    }

    /// Accepts "349,99", "349.99", "1.234,50", "1,234.50" and "349 €".
    /// Returns nil for anything that is not a non-negative amount.
    static func parsePrice(_ text: String) -> Decimal? {
        var digits = text.filter { !$0.isWhitespace && $0 != "€" }
        guard !digits.isEmpty else { return nil }
        let separators = digits.filter { $0 == "," || $0 == "." }
        if let decimalSeparator = decimalSeparator(in: digits, separators: separators) {
            let parts = digits.split(separator: decimalSeparator, omittingEmptySubsequences: false)
            let whole = parts.dropLast().joined().filter { $0 != "," && $0 != "." }
            digits = whole + "." + (parts.last ?? "")
        } else {
            digits = digits.filter { $0 != "," && $0 != "." }
        }
        guard digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              digits.contains(where: \.isNumber),
              let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return value
    }

    /// The last separator is decimal if both kinds occur. A single kind is
    /// decimal only when used once and not followed by exactly three digits.
    private static func decimalSeparator(in text: String, separators: String) -> Character? {
        guard let last = separators.last else { return nil }
        if Set(separators).count > 1 { return last }
        guard separators.count == 1 else { return nil }
        let digitsAfter = text.split(separator: last, omittingEmptySubsequences: false).last?.count ?? 0
        return digitsAfter == 3 ? nil : last
    }

    static func parseGrams(_ text: String) -> Int? {
        let digits = text.filter { !$0.isWhitespace && $0 != "." }
            .replacingOccurrences(of: "g", with: "")
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

struct Board: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var format: String
    var color: String
    /// Material of the case weight, for example brass or copper.
    var weightMaterial: String
    var status: BoardStatus
    var purchasePrice: Decimal?
    var purchaseDate: Date?
    var purchaseShop: String
    var mounting: String
    var caseMaterial: String
    var layout: String
    var typingAngle: String
    var weightGrams: Int?
    var plate: String
    var pcb: String
    var stabilizers: String
    var remark: String

    // V1 compatibility fields remain until migration has resolved relations.
    var legacyKeycapsName: String
    var keycapSetID: String?
    var legacySwitchesName: String

    var photoIDs: [String]
    var mainPhotoID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        manufacturer: String = "",
        format: String = "",
        color: String = "",
        weightMaterial: String = "",
        status: BoardStatus = .owned,
        purchasePrice: Decimal? = nil,
        purchaseDate: Date? = nil,
        purchaseShop: String = "",
        mounting: String = "",
        caseMaterial: String = "",
        layout: String = "",
        typingAngle: String = "",
        weightGrams: Int? = nil,
        plate: String = "",
        pcb: String = "",
        stabilizers: String = "",
        remark: String = "",
        legacyKeycapsName: String = "",
        keycapSetID: String? = nil,
        legacySwitchesName: String = "",
        photoIDs: [String] = [],
        mainPhotoID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.format = format
        self.color = color
        self.weightMaterial = weightMaterial
        self.status = status
        self.purchasePrice = purchasePrice
        self.purchaseDate = purchaseDate
        self.purchaseShop = purchaseShop
        self.mounting = mounting
        self.caseMaterial = caseMaterial
        self.layout = layout
        self.typingAngle = typingAngle
        self.weightGrams = weightGrams
        self.plate = plate
        self.pcb = pcb
        self.stabilizers = stabilizers
        self.remark = remark
        self.legacyKeycapsName = legacyKeycapsName
        self.keycapSetID = keycapSetID
        self.legacySwitchesName = legacySwitchesName
        self.photoIDs = photoIDs
        self.mainPhotoID = mainPhotoID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, format, color, weightMaterial, plate, pcb, stabilizers, remark
        case status, purchasePrice, purchaseDate, purchaseShop
        case mounting, caseMaterial, layout, typingAngle, weightGrams
        case legacyKeycapsName, keycapSetID, legacySwitchesName
        case photoIDs, mainPhotoID, createdAt, updatedAt
    }

    /// Snapshots saved before the newer board fields existed lack those keys;
    /// they must keep loading, so the fields default to empty or "owned".
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        format = try container.decode(String.self, forKey: .format)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        weightMaterial = try container.decodeIfPresent(String.self, forKey: .weightMaterial) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status)
            .flatMap(BoardStatus.init(rawValue:)) ?? .owned
        purchasePrice = try container.decodeIfPresent(Decimal.self, forKey: .purchasePrice)
        purchaseDate = try container.decodeIfPresent(Date.self, forKey: .purchaseDate)
        purchaseShop = try container.decodeIfPresent(String.self, forKey: .purchaseShop) ?? ""
        mounting = try container.decodeIfPresent(String.self, forKey: .mounting) ?? ""
        caseMaterial = try container.decodeIfPresent(String.self, forKey: .caseMaterial) ?? ""
        layout = try container.decodeIfPresent(String.self, forKey: .layout) ?? ""
        typingAngle = try container.decodeIfPresent(String.self, forKey: .typingAngle) ?? ""
        weightGrams = try container.decodeIfPresent(Int.self, forKey: .weightGrams)
        plate = try container.decode(String.self, forKey: .plate)
        pcb = try container.decode(String.self, forKey: .pcb)
        stabilizers = try container.decode(String.self, forKey: .stabilizers)
        remark = try container.decode(String.self, forKey: .remark)
        legacyKeycapsName = try container.decode(String.self, forKey: .legacyKeycapsName)
        keycapSetID = try container.decodeIfPresent(String.self, forKey: .keycapSetID)
        legacySwitchesName = try container.decode(String.self, forKey: .legacySwitchesName)
        photoIDs = try container.decode([String].self, forKey: .photoIDs)
        mainPhotoID = try container.decodeIfPresent(String.self, forKey: .mainPhotoID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(manufacturer, forKey: .manufacturer)
        try container.encode(format, forKey: .format)
        try container.encode(color, forKey: .color)
        try container.encode(weightMaterial, forKey: .weightMaterial)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(purchasePrice, forKey: .purchasePrice)
        try container.encodeIfPresent(purchaseDate, forKey: .purchaseDate)
        try container.encode(purchaseShop, forKey: .purchaseShop)
        try container.encode(mounting, forKey: .mounting)
        try container.encode(caseMaterial, forKey: .caseMaterial)
        try container.encode(layout, forKey: .layout)
        try container.encode(typingAngle, forKey: .typingAngle)
        try container.encodeIfPresent(weightGrams, forKey: .weightGrams)
        try container.encode(plate, forKey: .plate)
        try container.encode(pcb, forKey: .pcb)
        try container.encode(stabilizers, forKey: .stabilizers)
        try container.encode(remark, forKey: .remark)
        try container.encode(legacyKeycapsName, forKey: .legacyKeycapsName)
        try container.encodeIfPresent(keycapSetID, forKey: .keycapSetID)
        try container.encode(legacySwitchesName, forKey: .legacySwitchesName)
        try container.encode(photoIDs, forKey: .photoIDs)
        try container.encodeIfPresent(mainPhotoID, forKey: .mainPhotoID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var hasValidMainPhoto: Bool {
        guard let mainPhotoID else { return true }
        return photoIDs.contains(mainPhotoID)
    }
}
