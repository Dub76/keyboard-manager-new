import Foundation

enum InventoryEditingError: LocalizedError, Equatable, Sendable {
    case missingName
    case invalidHTTPSURL(String)
    case missingRelation(String)
    case invalidQuantity(String)
    case missingItem
    case invalidMainPhoto
    case invalidPrice(String)
    case invalidWeightGrams(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            L10n.text("Der Name ist ein Pflichtfeld.")
        case let .invalidHTTPSURL(value):
            L10n.text(
                "Die URL „%@“ muss eine vollständige HTTPS-Adresse sein.",
                arguments: value
            )
        case let .missingRelation(name):
            L10n.text("Die verknüpfte Position „%@“ existiert nicht mehr.", arguments: name)
        case let .invalidQuantity(message):
            message
        case .missingItem:
            L10n.text("Der zu bearbeitende Eintrag wurde nicht gefunden.")
        case .invalidMainPhoto:
            L10n.text("Das Hauptfoto gehört nicht zur Fotoliste dieses Eintrags.")
        case let .invalidPrice(value):
            L10n.text("„%@“ ist kein gültiger Preis.", arguments: value)
        case let .invalidWeightGrams(value):
            L10n.text("„%@“ ist keine gültige Grammangabe.", arguments: value)
        }
    }
}

struct InventoryEditingResult: Sendable {
    var snapshot: InventorySnapshot
    var removedPhotos: [PhotoRecord]
}

struct InventoryEditingService: Sendable {
    func saving(
        _ draft: InventoryDraft,
        newPhotos: [PhotoRecord],
        in source: InventorySnapshot,
        now: Date = .now
    ) throws -> InventoryEditingResult {
        try validate(draft, in: source, newPhotos: newPhotos)

        var snapshot = source
        snapshot.metadata.updatedAt = now
        let newPhotoIDs = Set(newPhotos.map(\.id))
        let retainedIDs = Set(draft.photoIDs).subtracting(newPhotoIDs)
        let oldOwnedPhotos = source.photos.filter {
            $0.owner == PhotoOwner(type: draft.kind.photoOwnerType, id: draft.id)
        }
        let removedPhotos = oldOwnedPhotos.filter { !retainedIDs.contains($0.id) }
        snapshot.photos.removeAll { removedPhotos.map(\.id).contains($0.id) }
        snapshot.photos.removeAll { newPhotoIDs.contains($0.id) }
        snapshot.photos.append(contentsOf: newPhotos)

        switch draft.kind {
        case .board:
            saveBoard(draft, in: &snapshot, now: now)
        case .keycapSet:
            saveKeycapSet(draft, in: &snapshot, now: now)
        case .artisanSet:
            saveArtisanSet(draft, in: &snapshot, now: now)
        case .switchSet:
            saveSwitchSet(draft, in: &snapshot, now: now)
        }
        clearLegacyNamesForChangedRelationships(from: source, in: &snapshot, now: now)
        rememberLibraryValues(from: draft, in: &snapshot.libraryValues)

        return InventoryEditingResult(snapshot: snapshot, removedPhotos: removedPhotos)
    }

    /// Removes the preserved V1 import warnings of a switch set. The removal
    /// is logged in the item's notes, so nothing disappears silently.
    func clearingImportWarnings(
        switchSetID: String,
        in source: InventorySnapshot,
        now: Date = .now
    ) throws -> InventorySnapshot {
        guard let index = source.switchSets.firstIndex(where: { $0.id == switchSetID }) else {
            throw InventoryEditingError.missingItem
        }
        let warnings = source.switchSets[index].importWarnings
        guard !warnings.isEmpty else { return source }

        let date = now.formatted(.iso8601.year().month().day())
        let log = ([L10n.text("Importhinweise am %@ entfernt:", arguments: date)]
            + warnings.map { "- \($0)" })
            .joined(separator: "\n")
        var snapshot = source
        let notes = snapshot.switchSets[index].notes
        snapshot.switchSets[index].notes = notes.isEmpty ? log : notes + "\n\n" + log
        snapshot.switchSets[index].importWarnings = []
        snapshot.switchSets[index].updatedAt = now
        snapshot.metadata.updatedAt = now
        return snapshot
    }

    func deleting(
        kind: InventoryItemKind,
        id: String,
        in source: InventorySnapshot,
        now: Date = .now
    ) throws -> InventoryEditingResult {
        var snapshot = source
        let removedPhotos = source.photos.filter {
            $0.owner == PhotoOwner(type: kind.photoOwnerType, id: id)
        }
        let didRemove: Bool

        switch kind {
        case .board:
            let oldCount = snapshot.boards.count
            snapshot.boards.removeAll { $0.id == id }
            didRemove = snapshot.boards.count != oldCount
            snapshot.keycapSets.indices.forEach { index in
                if snapshot.keycapSets[index].mountedBoardID == id {
                    snapshot.keycapSets[index].mountedBoardID = nil
                    snapshot.keycapSets[index].updatedAt = now
                }
            }
            snapshot.artisanSets.indices.forEach { index in
                if snapshot.artisanSets[index].mountedBoardID == id {
                    snapshot.artisanSets[index].mountedBoardID = nil
                    snapshot.artisanSets[index].updatedAt = now
                }
            }
            snapshot.switchInstallations.removeAll { $0.boardID == id }
        case .keycapSet:
            let oldCount = snapshot.keycapSets.count
            snapshot.keycapSets.removeAll { $0.id == id }
            didRemove = snapshot.keycapSets.count != oldCount
            snapshot.boards.indices.forEach { index in
                if snapshot.boards[index].keycapSetID == id {
                    snapshot.boards[index].keycapSetID = nil
                    snapshot.boards[index].updatedAt = now
                }
            }
        case .artisanSet:
            let oldCount = snapshot.artisanSets.count
            snapshot.artisanSets.removeAll { $0.id == id }
            didRemove = snapshot.artisanSets.count != oldCount
        case .switchSet:
            let oldCount = snapshot.switchSets.count
            snapshot.switchSets.removeAll { $0.id == id }
            didRemove = snapshot.switchSets.count != oldCount
            snapshot.switchInstallations.removeAll { $0.switchSetID == id }
        }

        guard didRemove else { throw InventoryEditingError.missingItem }
        clearLegacyNamesForChangedRelationships(from: source, in: &snapshot, now: now)
        snapshot.photos.removeAll { removedPhotos.map(\.id).contains($0.id) }
        snapshot.metadata.updatedAt = now
        return InventoryEditingResult(snapshot: snapshot, removedPhotos: removedPhotos)
    }

    // Import-only labels must not become visible again after an explicit relationship change.
    // Compare complete snapshots so edits from either side, moves and deletion share this rule.
    private func clearLegacyNamesForChangedRelationships(
        from source: InventorySnapshot,
        in snapshot: inout InventorySnapshot,
        now: Date
    ) {
        let oldBoards = Dictionary(uniqueKeysWithValues: source.boards.map { ($0.id, $0) })
        let oldInstallations = Dictionary(grouping: source.switchInstallations, by: \.boardID)
        let newInstallations = Dictionary(grouping: snapshot.switchInstallations, by: \.boardID)
        for index in snapshot.boards.indices {
            let board = snapshot.boards[index]
            if oldBoards[board.id]?.keycapSetID != board.keycapSetID {
                snapshot.boards[index].legacyKeycapsName = ""
                snapshot.boards[index].updatedAt = now
            }
            let oldSwitches = oldInstallations[board.id, default: []].sorted { $0.switchSetID < $1.switchSetID }
            let newSwitches = newInstallations[board.id, default: []].sorted { $0.switchSetID < $1.switchSetID }
            if oldSwitches != newSwitches {
                snapshot.boards[index].legacySwitchesName = ""
                snapshot.boards[index].updatedAt = now
            }
        }
    }

    private func validate(
        _ draft: InventoryDraft,
        in snapshot: InventorySnapshot,
        newPhotos: [PhotoRecord]
    ) throws {
        guard !draft.normalizedName.isEmpty else {
            throw InventoryEditingError.missingName
        }
        for value in [draft.sourceURL, draft.coverURL] + draft.externalImageURLs {
            guard value.isEmpty || isValidHTTPSURL(value) else {
                throw InventoryEditingError.invalidHTTPSURL(value)
            }
        }
        if let boardID = draft.mountedBoardID,
           !snapshot.boards.contains(where: { $0.id == boardID }) {
            throw InventoryEditingError.missingRelation(boardID)
        }
        if let keycapSetID = draft.keycapSetID,
           !snapshot.keycapSets.contains(where: { $0.id == keycapSetID }) {
            throw InventoryEditingError.missingRelation(keycapSetID)
        }
        let validPhotoIDs = Set(draft.photoIDs).union(newPhotos.map(\.id))
        if let mainPhotoID = draft.mainPhotoID, !validPhotoIDs.contains(mainPhotoID) {
            throw InventoryEditingError.invalidMainPhoto
        }
        if draft.kind == .board {
            let price = draft.purchasePriceText.trimmed
            if !price.isEmpty, BoardValueFormat.parsePrice(price) == nil {
                throw InventoryEditingError.invalidPrice(price)
            }
            let grams = draft.weightGramsText.trimmed
            if !grams.isEmpty, BoardValueFormat.parseGrams(grams) == nil {
                throw InventoryEditingError.invalidWeightGrams(grams)
            }
        }
        if draft.quantity < 0 {
            throw InventoryEditingError.invalidQuantity(
                L10n.text("Der Gesamtbestand darf nicht negativ sein.")
            )
        }
        if draft.installations.values.contains(where: { $0 < 0 }) {
            throw InventoryEditingError.invalidQuantity(
                L10n.text("Installationsmengen dürfen nicht negativ sein.")
            )
        }
        switch draft.kind {
        case .board:
            for switchID in draft.installations.keys where
                !snapshot.switchSets.contains(where: { $0.id == switchID }) {
                throw InventoryEditingError.missingRelation(switchID)
            }
            for (switchID, quantity) in draft.installations {
                guard let switchSet = snapshot.switchSets.first(where: { $0.id == switchID }) else {
                    continue
                }
                let installedElsewhere = snapshot.switchInstallations
                    .filter { $0.switchSetID == switchID && $0.boardID != draft.id }
                    .reduce(0) { $0 + $1.quantity }
                if installedElsewhere + quantity > switchSet.quantity {
                    throw InventoryEditingError.invalidQuantity(
                        L10n.text(
                            "Für „%@“ wären %lld von %lld Switches verbaut.",
                            arguments: switchSet.name,
                            installedElsewhere + quantity,
                            switchSet.quantity
                        )
                    )
                }
            }
        case .switchSet:
            for boardID in draft.installations.keys where
                !snapshot.boards.contains(where: { $0.id == boardID }) {
                throw InventoryEditingError.missingRelation(boardID)
            }
            let installed = draft.installations.values.reduce(0, +)
            if installed > draft.quantity {
                throw InventoryEditingError.invalidQuantity(
                    L10n.text(
                        "Verbaut (%lld) darf den Gesamtbestand (%lld) nicht überschreiten.",
                        arguments: installed,
                        draft.quantity
                    )
                )
            }
        case .keycapSet, .artisanSet:
            break
        }
    }

    private func saveBoard(_ draft: InventoryDraft, in snapshot: inout InventorySnapshot, now: Date) {
        let board = Board(
            id: draft.id,
            name: draft.normalizedName,
            manufacturer: draft.manufacturer.trimmed,
            format: draft.format.trimmed,
            color: draft.color.trimmed,
            weightMaterial: draft.weightMaterial.trimmed,
            status: BoardStatus(rawValue: draft.status) ?? .owned,
            purchasePrice: BoardValueFormat.parsePrice(draft.purchasePriceText),
            purchaseDate: draft.purchaseDate,
            purchaseShop: draft.purchaseShop.trimmed,
            mounting: draft.mounting.trimmed,
            caseMaterial: draft.caseMaterial.trimmed,
            layout: draft.layout.trimmed,
            typingAngle: draft.typingAngle.trimmed,
            weightGrams: BoardValueFormat.parseGrams(draft.weightGramsText),
            plate: draft.plate.trimmed,
            pcb: draft.pcb.trimmed,
            stabilizers: draft.stabilizers.trimmed,
            remark: draft.notes,
            legacyKeycapsName: draft.legacyKeycapsName,
            keycapSetID: draft.keycapSetID,
            legacySwitchesName: draft.legacySwitchesName,
            photoIDs: draft.photoIDs,
            mainPhotoID: draft.mainPhotoID,
            createdAt: draft.createdAt,
            updatedAt: now
        )
        upsert(board, in: &snapshot.boards)

        snapshot.keycapSets.indices.forEach { index in
            if snapshot.keycapSets[index].mountedBoardID == draft.id,
               snapshot.keycapSets[index].id != draft.keycapSetID {
                snapshot.keycapSets[index].mountedBoardID = nil
                snapshot.keycapSets[index].updatedAt = now
            }
        }
        if let keycapID = draft.keycapSetID,
           let keycapIndex = snapshot.keycapSets.firstIndex(where: { $0.id == keycapID }) {
            if let previousBoardID = snapshot.keycapSets[keycapIndex].mountedBoardID,
               previousBoardID != draft.id,
               let previousBoardIndex = snapshot.boards.firstIndex(where: { $0.id == previousBoardID }),
               snapshot.boards[previousBoardIndex].keycapSetID == keycapID {
                snapshot.boards[previousBoardIndex].keycapSetID = nil
                snapshot.boards[previousBoardIndex].updatedAt = now
            }
            snapshot.keycapSets[keycapIndex].mountedBoardID = draft.id
            snapshot.keycapSets[keycapIndex].updatedAt = now
        }
        snapshot.switchInstallations.removeAll { $0.boardID == draft.id }
        snapshot.switchInstallations.append(contentsOf: draft.installations.compactMap { switchID, quantity in
            quantity > 0 ? SwitchInstallation(switchSetID: switchID, boardID: draft.id, quantity: quantity) : nil
        })
    }

    private func saveKeycapSet(_ draft: InventoryDraft, in snapshot: inout InventorySnapshot, now: Date) {
        let item = KeycapSet(
            id: draft.id,
            name: draft.normalizedName,
            manufacturer: draft.manufacturer.trimmed,
            profile: draft.profile.trimmed,
            material: draft.material.trimmed,
            status: draft.status.trimmed,
            kits: draft.normalizedListEntries,
            sourceURL: draft.sourceURL.trimmed,
            sourceShop: draft.sourceShop.trimmed,
            mountedBoardID: draft.mountedBoardID,
            notes: draft.notes,
            photoIDs: draft.photoIDs,
            mainPhotoID: draft.mainPhotoID,
            coverURL: draft.coverURL.trimmed,
            externalImageURLs: draft.externalImageURLs,
            trelloCardID: draft.trelloCardID,
            trelloListName: draft.trelloListName,
            createdAt: draft.createdAt,
            updatedAt: now
        )
        upsert(item, in: &snapshot.keycapSets)

        snapshot.boards.indices.forEach { index in
            if snapshot.boards[index].keycapSetID == draft.id,
               snapshot.boards[index].id != draft.mountedBoardID {
                snapshot.boards[index].keycapSetID = nil
                snapshot.boards[index].updatedAt = now
            }
        }
        if let boardID = draft.mountedBoardID,
           let boardIndex = snapshot.boards.firstIndex(where: { $0.id == boardID }) {
            if let previousKeycapID = snapshot.boards[boardIndex].keycapSetID,
               previousKeycapID != draft.id,
               let previousKeycapIndex = snapshot.keycapSets.firstIndex(where: { $0.id == previousKeycapID }),
               snapshot.keycapSets[previousKeycapIndex].mountedBoardID == boardID {
                snapshot.keycapSets[previousKeycapIndex].mountedBoardID = nil
                snapshot.keycapSets[previousKeycapIndex].updatedAt = now
            }
            snapshot.boards[boardIndex].keycapSetID = draft.id
            snapshot.boards[boardIndex].updatedAt = now
        }
    }

    private func saveArtisanSet(_ draft: InventoryDraft, in snapshot: inout InventorySnapshot, now: Date) {
        let item = ArtisanSet(
            id: draft.id,
            name: draft.normalizedName,
            manufacturer: draft.manufacturer.trimmed,
            profile: draft.profile.trimmed,
            material: draft.material.trimmed,
            status: draft.status.trimmed,
            tags: draft.normalizedListEntries,
            sourceURL: draft.sourceURL.trimmed,
            sourceShop: draft.sourceShop.trimmed,
            mountedBoardID: draft.mountedBoardID,
            notes: draft.notes,
            photoIDs: draft.photoIDs,
            mainPhotoID: draft.mainPhotoID,
            coverURL: draft.coverURL.trimmed,
            externalImageURLs: draft.externalImageURLs,
            trelloCardID: draft.trelloCardID,
            trelloListName: draft.trelloListName,
            createdAt: draft.createdAt,
            updatedAt: now
        )
        upsert(item, in: &snapshot.artisanSets)
    }

    private func saveSwitchSet(_ draft: InventoryDraft, in snapshot: inout InventorySnapshot, now: Date) {
        let item = SwitchSet(
            id: draft.id,
            name: draft.normalizedName,
            switchType: draft.switchType.trimmed,
            topHousingMaterial: draft.topHousingMaterial.trimmed,
            bottomHousingMaterial: draft.bottomHousingMaterial.trimmed,
            stemMaterial: draft.stemMaterial.trimmed,
            springLength: draft.springLength.trimmed,
            springType: draft.springType.trimmed,
            preTravel: draft.preTravel.trimmed,
            totalTravel: draft.totalTravel.trimmed,
            operatingForce: draft.operatingForce.trimmed,
            bottomOutForce: draft.bottomOutForce.trimmed,
            pins: draft.pins,
            hasLEDDiffuser: draft.hasLEDDiffuser,
            isFactoryLubed: draft.isFactoryLubed,
            quantity: draft.quantity,
            importedBoardText: draft.importedBoardText,
            importedBoardAllocations: draft.importedBoardAllocations,
            importSource: draft.importSource,
            importRow: draft.importRow,
            importKey: draft.importKey,
            importWarnings: draft.importWarnings,
            notes: draft.notes,
            photoIDs: draft.photoIDs,
            mainPhotoID: draft.mainPhotoID,
            createdAt: draft.createdAt,
            updatedAt: now
        )
        upsert(item, in: &snapshot.switchSets)
        snapshot.switchInstallations.removeAll { $0.switchSetID == draft.id }
        snapshot.switchInstallations.append(contentsOf: draft.installations.compactMap { boardID, quantity in
            quantity > 0 ? SwitchInstallation(switchSetID: draft.id, boardID: boardID, quantity: quantity) : nil
        })
    }

    private func rememberLibraryValues(from draft: InventoryDraft, in library: inout LibraryValues) {
        let values: [(String, String)]
        switch draft.kind {
        case .board:
            values = [
                ("manufacturers", draft.manufacturer),
                ("formats", draft.format),
                ("boardColors", draft.color),
                ("boardWeightMaterials", draft.weightMaterial),
                ("boardShops", draft.purchaseShop),
                ("boardMountings", draft.mounting),
                ("boardCaseMaterials", draft.caseMaterial),
                ("boardLayouts", draft.layout),
                ("plates", draft.plate),
                ("pcbs", draft.pcb),
                ("stabs", draft.stabilizers)
            ]
        case .keycapSet:
            values = [
                ("keycapManufacturers", draft.manufacturer),
                ("keycapProfiles", draft.profile),
                ("keycapMaterials", draft.material),
                ("keycapStatuses", draft.status)
            ]
        case .artisanSet:
            values = [
                ("artisanManufacturers", draft.manufacturer),
                ("artisanProfiles", draft.profile),
                ("artisanMaterials", draft.material),
                ("artisanStatuses", draft.status)
            ]
        case .switchSet:
            values = [
                ("switchNames", draft.name),
                ("switchTypes", draft.switchType),
                ("switchTopHousingMaterials", draft.topHousingMaterial),
                ("switchBottomHousingMaterials", draft.bottomHousingMaterial),
                ("switchStemMaterials", draft.stemMaterial),
                ("switchSpringLengths", draft.springLength),
                ("switchSpringTypes", draft.springType),
                ("switchPreTravels", draft.preTravel),
                ("switchTotalTravels", draft.totalTravel),
                ("switchOperatingForces", draft.operatingForce),
                ("switchBottomOutForces", draft.bottomOutForce)
            ]
        }

        for (key, rawValue) in values {
            let value = rawValue.trimmed
            guard !value.isEmpty else { continue }
            var existing = library.valuesByKey[key, default: []]
            guard !existing.contains(where: {
                $0.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                continue
            }
            existing.append(value)
            existing.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            library.valuesByKey[key] = existing
        }
    }

    private func upsert<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == String {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }

    private func isValidHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

private extension InventoryItemKind {
    var photoOwnerType: PhotoOwnerType {
        switch self {
        case .board: .board
        case .keycapSet: .keycapSet
        case .artisanSet: .artisanSet
        case .switchSet: .switchSet
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
