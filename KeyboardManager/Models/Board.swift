import Foundation

struct Board: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var format: String
    var color: String
    /// Material of the case weight, for example brass or copper.
    var weightMaterial: String
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
        case legacyKeycapsName, keycapSetID, legacySwitchesName
        case photoIDs, mainPhotoID, createdAt, updatedAt
    }

    /// Snapshots saved before the color and weight fields existed lack those
    /// keys; they must keep loading, so the fields default to empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        format = try container.decode(String.self, forKey: .format)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        weightMaterial = try container.decodeIfPresent(String.self, forKey: .weightMaterial) ?? ""
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

    var hasValidMainPhoto: Bool {
        guard let mainPhotoID else { return true }
        return photoIDs.contains(mainPhotoID)
    }
}
