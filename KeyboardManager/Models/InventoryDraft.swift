import Foundation

struct InventoryDraft: Hashable, Sendable {
    var id: String
    var kind: InventoryItemKind
    var createdAt: Date

    var name = ""
    var manufacturer = ""
    var profile = ""
    var material = ""
    var status = "owned"
    var sourceURL = ""
    var sourceShop = ""
    var mountedBoardID: String?
    var notes = ""
    var listEntries: [String] = []

    var format = ""
    var color = ""
    var weightMaterial = ""
    var plate = ""
    var pcb = ""
    var stabilizers = ""
    var keycapSetID: String?
    var legacyKeycapsName = ""
    var legacySwitchesName = ""

    var switchType = ""
    var topHousingMaterial = ""
    var bottomHousingMaterial = ""
    var stemMaterial = ""
    var springLength = ""
    var springType = ""
    var preTravel = ""
    var totalTravel = ""
    var operatingForce = ""
    var bottomOutForce = ""
    var pins: SwitchPins = .five
    var hasLEDDiffuser = false
    var isFactoryLubed = false
    var quantity = 0
    var installations: [String: Int] = [:]

    var importedBoardText = ""
    var importedBoardAllocations: [ImportedBoardAllocation] = []
    var importSource = ""
    var importRow = 0
    var importKey = ""
    var importWarnings: [String] = []

    var photoIDs: [String] = []
    var mainPhotoID: String?
    var coverURL = ""
    var externalImageURLs: [String] = []
    var trelloCardID = ""
    var trelloListName = ""

    init(kind: InventoryItemKind, id: String = UUID().uuidString, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    init(board: Board, installations: [SwitchInstallation]) {
        self.init(kind: .board, id: board.id, createdAt: board.createdAt)
        name = board.name
        manufacturer = board.manufacturer
        format = board.format
        color = board.color
        weightMaterial = board.weightMaterial
        plate = board.plate
        pcb = board.pcb
        stabilizers = board.stabilizers
        notes = board.remark
        legacyKeycapsName = board.legacyKeycapsName
        keycapSetID = board.keycapSetID
        legacySwitchesName = board.legacySwitchesName
        photoIDs = board.photoIDs
        mainPhotoID = board.mainPhotoID
        self.installations = Dictionary(
            uniqueKeysWithValues: installations
                .filter { $0.boardID == board.id }
                .map { ($0.switchSetID, $0.quantity) }
        )
    }

    init(keycapSet: KeycapSet) {
        self.init(kind: .keycapSet, id: keycapSet.id, createdAt: keycapSet.createdAt)
        name = keycapSet.name
        manufacturer = keycapSet.manufacturer
        profile = keycapSet.profile
        material = keycapSet.material
        status = keycapSet.status
        listEntries = keycapSet.kits
        sourceURL = keycapSet.sourceURL
        sourceShop = keycapSet.sourceShop
        mountedBoardID = keycapSet.mountedBoardID
        notes = keycapSet.notes
        photoIDs = keycapSet.photoIDs
        mainPhotoID = keycapSet.mainPhotoID
        coverURL = keycapSet.coverURL
        externalImageURLs = keycapSet.externalImageURLs
        trelloCardID = keycapSet.trelloCardID
        trelloListName = keycapSet.trelloListName
    }

    init(artisanSet: ArtisanSet) {
        self.init(kind: .artisanSet, id: artisanSet.id, createdAt: artisanSet.createdAt)
        name = artisanSet.name
        manufacturer = artisanSet.manufacturer
        profile = artisanSet.profile
        material = artisanSet.material
        status = artisanSet.status
        listEntries = artisanSet.tags
        sourceURL = artisanSet.sourceURL
        sourceShop = artisanSet.sourceShop
        mountedBoardID = artisanSet.mountedBoardID
        notes = artisanSet.notes
        photoIDs = artisanSet.photoIDs
        mainPhotoID = artisanSet.mainPhotoID
        coverURL = artisanSet.coverURL
        externalImageURLs = artisanSet.externalImageURLs
        trelloCardID = artisanSet.trelloCardID
        trelloListName = artisanSet.trelloListName
    }

    init(switchSet: SwitchSet, installations: [SwitchInstallation]) {
        self.init(kind: .switchSet, id: switchSet.id, createdAt: switchSet.createdAt)
        name = switchSet.name
        switchType = switchSet.switchType
        topHousingMaterial = switchSet.topHousingMaterial
        bottomHousingMaterial = switchSet.bottomHousingMaterial
        stemMaterial = switchSet.stemMaterial
        springLength = switchSet.springLength
        springType = switchSet.springType
        preTravel = switchSet.preTravel
        totalTravel = switchSet.totalTravel
        operatingForce = switchSet.operatingForce
        bottomOutForce = switchSet.bottomOutForce
        pins = switchSet.pins
        hasLEDDiffuser = switchSet.hasLEDDiffuser
        isFactoryLubed = switchSet.isFactoryLubed
        quantity = switchSet.quantity
        importedBoardText = switchSet.importedBoardText
        importedBoardAllocations = switchSet.importedBoardAllocations
        importSource = switchSet.importSource
        importRow = switchSet.importRow
        importKey = switchSet.importKey
        importWarnings = switchSet.importWarnings
        notes = switchSet.notes
        photoIDs = switchSet.photoIDs
        mainPhotoID = switchSet.mainPhotoID
        self.installations = Dictionary(
            uniqueKeysWithValues: installations
                .filter { $0.switchSetID == switchSet.id }
                .map { ($0.boardID, $0.quantity) }
        )
    }

    var normalizedListEntries: [String] {
        var seen = Set<String>()
        return listEntries.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
