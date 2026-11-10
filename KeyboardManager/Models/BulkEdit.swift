import Foundation

/// A text field that can be set for several entries at once.
enum BulkEditField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case manufacturer
    case boardStatus
    case format
    case color
    case weightMaterial
    case layout
    case mounting
    case caseMaterial
    case typingAngle
    case plate
    case pcb
    case stabilizers
    case purchaseShop
    case profile
    case material
    case status
    case sourceShop
    case switchType
    case topHousingMaterial
    case bottomHousingMaterial
    case stemMaterial
    case springType

    var id: Self { self }

    static func fields(for kind: InventoryItemKind) -> [BulkEditField] {
        switch kind {
        case .board:
            [.manufacturer, .boardStatus, .format, .color, .weightMaterial, .layout, .mounting,
             .caseMaterial, .typingAngle, .plate, .pcb, .stabilizers, .purchaseShop]
        case .keycapSet, .artisanSet:
            [.manufacturer, .profile, .material, .status, .sourceShop]
        case .switchSet:
            [.switchType, .topHousingMaterial, .bottomHousingMaterial, .stemMaterial, .springType]
        }
    }

    var title: String {
        switch self {
        case .manufacturer: L10n.text("Hersteller")
        case .boardStatus, .status: L10n.text("Status")
        case .format: L10n.text("Format")
        case .color: L10n.text("Farbe")
        case .weightMaterial: L10n.text("Gewicht-Material")
        case .layout: L10n.text("Layout")
        case .mounting: L10n.text("Mounting")
        case .caseMaterial: L10n.text("Case-Material")
        case .typingAngle: L10n.text("Tippwinkel")
        case .plate: L10n.text("Plate")
        case .pcb: L10n.text("PCB")
        case .stabilizers: L10n.text("Stabilisatoren")
        case .purchaseShop, .sourceShop: L10n.text("Shop")
        case .profile: L10n.text("Profil")
        case .material: L10n.text("Material")
        case .switchType: L10n.text("Typ")
        case .topHousingMaterial: L10n.text("Top Housing")
        case .bottomHousingMaterial: L10n.text("Bottom Housing")
        case .stemMaterial: L10n.text("Stem")
        case .springType: L10n.text("Federtyp")
        }
    }

    var keyPath: WritableKeyPath<InventoryDraft, String> {
        switch self {
        case .manufacturer: \.manufacturer
        case .boardStatus, .status: \.status
        case .format: \.format
        case .color: \.color
        case .weightMaterial: \.weightMaterial
        case .layout: \.layout
        case .mounting: \.mounting
        case .caseMaterial: \.caseMaterial
        case .typingAngle: \.typingAngle
        case .plate: \.plate
        case .pcb: \.pcb
        case .stabilizers: \.stabilizers
        case .purchaseShop: \.purchaseShop
        case .sourceShop: \.sourceShop
        case .profile: \.profile
        case .material: \.material
        case .switchType: \.switchType
        case .topHousingMaterial: \.topHousingMaterial
        case .bottomHousingMaterial: \.bottomHousingMaterial
        case .stemMaterial: \.stemMaterial
        case .springType: \.springType
        }
    }

    /// The library that offers previously entered values for this field.
    func libraryKey(for kind: InventoryItemKind) -> String? {
        switch (self, kind) {
        case (.manufacturer, .board): "manufacturers"
        case (.manufacturer, .keycapSet): "keycapManufacturers"
        case (.manufacturer, .artisanSet): "artisanManufacturers"
        case (.format, _): "formats"
        case (.color, _): "boardColors"
        case (.weightMaterial, _): "boardWeightMaterials"
        case (.layout, _): "boardLayouts"
        case (.mounting, _): "boardMountings"
        case (.caseMaterial, _): "boardCaseMaterials"
        case (.plate, _): "plates"
        case (.pcb, _): "pcbs"
        case (.stabilizers, _): "stabs"
        case (.purchaseShop, _): "boardShops"
        case (.profile, .keycapSet): "keycapProfiles"
        case (.profile, .artisanSet): "artisanProfiles"
        case (.material, .keycapSet): "keycapMaterials"
        case (.material, .artisanSet): "artisanMaterials"
        case (.status, .keycapSet): "keycapStatuses"
        case (.status, .artisanSet): "artisanStatuses"
        case (.switchType, _): "switchTypes"
        case (.topHousingMaterial, _): "switchTopHousingMaterials"
        case (.bottomHousingMaterial, _): "switchBottomHousingMaterials"
        case (.stemMaterial, _): "switchStemMaterials"
        case (.springType, _): "switchSpringTypes"
        default: nil
        }
    }
}
