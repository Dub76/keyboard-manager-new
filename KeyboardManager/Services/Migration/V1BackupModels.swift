import Foundation

struct V1BackupManifest: Decodable, Sendable {
    var schemaVersion: Int?
    var format: String?
    var meta: V1BackupMetadata?
    var lists: [String: [String]]?
    var boards: [V1Board]?
    var keycapSets: [V1KeycapSet]?
    var artisanSets: [V1ArtisanSet]?
    var switchSets: [V1SwitchSet]?
    var photos: [V1Photo]?
}

struct V1BackupMetadata: Decodable, Sendable {
    var version: String?
    var createdAt: Double?
    var updatedAt: Double?
    var exportedAt: Double?
    var language: String?
}

struct V1Board: Decodable, Sendable {
    var id: String?
    var name: String?
    var manufacturer: String?
    var format: String?
    /// Not part of V1; written by V2 backups so a restore keeps the color.
    var color: String?
    var weightMaterial: String?
    var plate: String?
    var pcb: String?
    var keycaps: String?
    var keycapSetId: String?
    var stabs: String?
    var switches: String?
    var switchSetId: String?
    var switchSetIds: [String]?
    var switchSetQuantities: [String: Int]?
    var remark: String?
    var photoIds: [String]?
    var mainPhotoId: String?
    var createdAt: Double?
    var updatedAt: Double?
}

struct V1KeycapSet: Decodable, Sendable {
    var id: String?
    var name: String?
    var manufacturer: String?
    var profile: String?
    var material: String?
    var status: String?
    var kits: [String]?
    var sourceUrl: String?
    var sourceShop: String?
    var mountedBoardId: String?
    var notes: String?
    var photoIds: [String]?
    var mainPhotoId: String?
    var coverUrl: String?
    var externalImageUrls: [String]?
    var trelloCardId: String?
    var trelloListName: String?
    var createdAt: Double?
    var updatedAt: Double?
}

struct V1ArtisanSet: Decodable, Sendable {
    var id: String?
    var name: String?
    var manufacturer: String?
    var profile: String?
    var material: String?
    var status: String?
    var tags: [String]?
    var sourceUrl: String?
    var sourceShop: String?
    var mountedBoardId: String?
    var notes: String?
    var photoIds: [String]?
    var mainPhotoId: String?
    var coverUrl: String?
    var externalImageUrls: [String]?
    var trelloCardId: String?
    var trelloListName: String?
    var createdAt: Double?
    var updatedAt: Double?
}

struct V1SwitchSet: Decodable, Sendable {
    var id: String?
    var name: String?
    var switchType: String?
    var topHousingMaterial: String?
    var bottomHousingMaterial: String?
    var stemMaterial: String?
    var springLength: String?
    var springType: String?
    var preTravel: String?
    var totalTravel: String?
    var operatingForce: String?
    var bottomOutForce: String?
    var pins: String?
    var ledDiffuser: Bool?
    var factoryLubed: Bool?
    var quantity: Int?
    var mountedQuantity: Int?
    var mountedBoardId: String?
    var installations: [V1SwitchInstallation]?
    var importedBoardText: String?
    var importedBoardAllocations: [V1ImportedBoardAllocation]?
    var importSource: String?
    var importRow: Int?
    var importKey: String?
    var importWarnings: [String]?
    var notes: String?
    var photoIds: [String]?
    var mainPhotoId: String?
    var createdAt: Double?
    var updatedAt: Double?
}

struct V1SwitchInstallation: Decodable, Sendable {
    var boardId: String?
    var quantity: Int?
}

struct V1ImportedBoardAllocation: Decodable, Sendable {
    var board: String?
    var quantity: Int?
    var inferred: Bool?
}

struct V1Photo: Decodable, Sendable {
    var id: String?
    var boardId: String?
    var ownerType: String?
    var ownerId: String?
    var name: String?
    var type: String?
    var width: Int?
    var height: Int?
    var addedAt: Double?
    var file: String?
    var dataUrl: String?
}
