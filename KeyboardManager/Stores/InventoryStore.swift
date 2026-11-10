import Foundation
import Observation

@MainActor
@Observable
final class InventoryStore {
    var snapshot: InventorySnapshot = .empty
    var route: AppRoute = .overview
    var selectedKind: InventoryItemKind = .board
    var selectedItemID: String?
    var overviewFiltersByKind: [InventoryItemKind: InventoryFilters] = [:]
    var overviewSortsByKind: [InventoryItemKind: InventorySort] = [:]
    private(set) var overviewSelectionByKind: [InventoryItemKind: String] = [:]
    private(set) var overviewMultiSelectionByKind: [InventoryItemKind: Set<String>] = [:]
    private(set) var pendingDuplicate: PendingDuplicate?
    private var editorRevision = 0
    private(set) var overviewScrollOffsetByKind: [InventoryItemKind: Double] = [:]
    private(set) var overviewRestoreRequest: OverviewRestoreRequest?
    var loadState: LoadState = .idle
    var editorSaveState: EditorSaveState = .idle
    var isEditorDirty = false
    var isDiscardConfirmationPresented = false
    var isWindowCloseConfirmationPresented = false
    var navigationRevision = 0
    private(set) var windowCloseRevision = 0
    var migrationReadiness: MigrationReadiness = .notScanned
    var migrationDiscoveryState: V1SourceDiscoveryState = .idle
    var migrationInspectionState: MigrationInspectionState = .idle
    var migrationCommitState: MigrationCommitState = .idle
    var backupExportState: BackupExportState = .idle
    var reportExportState: InventoryReportExportState = .idle
    private(set) var automaticBackupState: AutomaticBackupState = .idle
    private(set) var latestAutomaticBackup: AutomaticBackupEntry?
    private(set) var automaticBackupEntries: [AutomaticBackupEntry] = []
    private(set) var backupRestoreState: BackupRestoreState = .idle
    private(set) var backupMirrorURL: URL?
    private(set) var backupMirrorError: String?
    private(set) var undoableDeletion: UndoableDeletion?
    private(set) var languagePersistenceError: String?
    private(set) var migrationReportURL: URL?
    private(set) var pendingMigrationSnapshot: InventorySnapshot?
    private var pendingMigrationResult: MigrationDryRunResult?
    private var pendingMigrationSourceURL: URL?

    private let repository: any InventoryRepository
    private let migrationService: V1MigrationService
    private let migrationCommitService: MigrationCommitService
    private let backupExportService: BackupExportService
    private let reportExportService: InventoryReportExportService
    private let editingService = InventoryEditingService()
    private let photoService: PhotoImportService
    private let thumbnailService: ThumbnailService
    private let automaticBackupService: AutomaticBackupService?
    private let automaticBackupsEnabled: @MainActor @Sendable () -> Bool
    private let backupDefaults: UserDefaults
    private var pendingEditorNavigation: EditorNavigationTarget?
    private var pendingOverviewReturn: OverviewReturnContext?
    private var overviewRestoreRevision = 0
    private var writeChain: Task<Void, Never>?

    static let automaticBackupsPreferenceKey = "automaticBackupsEnabled"
    static let backupMirrorPathKey = "automaticBackupMirrorPath"

    /// Reads the Settings toggle; automatic backups are on unless turned off.
    static func automaticBackupsPreference() -> Bool {
        UserDefaults.standard.object(forKey: automaticBackupsPreferenceKey) as? Bool ?? true
    }

    static var inventoryNotLoadedMessage: String {
        L10n.text(
            "Der Bestand wurde nicht geladen. Änderungen sind gesperrt, damit keine gespeicherten Daten überschrieben werden."
        )
    }

    init(
        repository: any InventoryRepository = SQLiteInventoryRepository(),
        migrationService: V1MigrationService = V1MigrationService(),
        migrationCommitService: MigrationCommitService = MigrationCommitService(),
        backupExportService: BackupExportService = BackupExportService(),
        reportExportService: InventoryReportExportService = InventoryReportExportService(),
        photoService: PhotoImportService = PhotoImportService(),
        thumbnailService: ThumbnailService = ThumbnailService(),
        // Off unless the app passes a service, so tests and previews never
        // write into or prune the real backup folder.
        automaticBackupService: AutomaticBackupService? = nil,
        automaticBackupsEnabled: @escaping @MainActor @Sendable () -> Bool = {
            InventoryStore.automaticBackupsPreference()
        },
        backupDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.migrationService = migrationService
        self.migrationCommitService = migrationCommitService
        self.backupExportService = backupExportService
        self.reportExportService = reportExportService
        self.photoService = photoService
        self.thumbnailService = thumbnailService
        self.automaticBackupService = automaticBackupService
        self.automaticBackupsEnabled = automaticBackupsEnabled
        self.backupDefaults = backupDefaults
        backupMirrorURL = backupDefaults.string(forKey: Self.backupMirrorPathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func load() async {
        guard loadState == .idle else { return }
        loadState = .loading

        do {
            snapshot = try await repository.loadSnapshot()
            loadState = .loaded
            scheduleAutomaticBackup()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Allows a new load attempt after a failure, for example once the user
    /// has closed another process that held the database.
    func retryLoad() async {
        guard case .failed = loadState else { return }
        loadState = .idle
        await load()
    }

    /// Only a successfully loaded snapshot may be the base of a write.
    /// Writing on top of the `.empty` placeholder would replace the stored
    /// collection with just the edited item.
    var canWriteInventory: Bool {
        loadState == .loaded
    }

    func updatePreferredLanguage(_ value: String) async {
        await serializedWrite { await self.performUpdatePreferredLanguage(value) }
    }

    private func performUpdatePreferredLanguage(_ value: String) async {
        let normalized = AppLanguage.normalized(value).rawValue
        guard loadState == .loaded else { return }
        guard snapshot.metadata.preferredLanguage != normalized else {
            languagePersistenceError = nil
            return
        }
        var updated = snapshot
        updated.metadata.preferredLanguage = normalized
        do {
            try await repository.saveSnapshot(updated)
            await discardUndoableDeletion()
            snapshot = updated
            languagePersistenceError = nil
        } catch {
            languagePersistenceError = L10n.text(
                "Die Sprachauswahl konnte nicht gespeichert werden: %@",
                arguments: error.localizedDescription
            )
        }
    }

    func prepareNewItem(_ kind: InventoryItemKind) {
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .new(kind)
            isDiscardConfirmationPresented = true
            return
        }
        openNewItem(kind)
    }

    func requestRoute(_ newRoute: AppRoute) {
        guard newRoute != route else { return }
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .route(newRoute)
            isDiscardConfirmationPresented = true
            navigationRevision += 1
            return
        }
        if newRoute == .capture {
            openNewItem(selectedKind)
            return
        }
        if newRoute == .overview, let pendingOverviewReturn {
            scheduleOverviewRestore(
                kind: pendingOverviewReturn.kind,
                itemID: pendingOverviewReturn.itemID
            )
        }
        route = newRoute
    }

    func editItem(kind: InventoryItemKind, id: String) {
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .edit(kind, id)
            isDiscardConfirmationPresented = true
            return
        }
        openEditor(kind: kind, id: id)
    }

    func updateOverviewSelection(_ id: String?, for kind: InventoryItemKind) {
        if let id {
            overviewSelectionByKind[kind] = id
            overviewMultiSelectionByKind[kind] = [id]
        } else {
            overviewSelectionByKind.removeValue(forKey: kind)
            overviewMultiSelectionByKind.removeValue(forKey: kind)
        }
        if selectedKind == kind {
            selectedItemID = id
        }
    }

    /// Several selected rows have no single current entry; actions that need
    /// one (details, edit, delete, duplicate) are then unavailable.
    func updateOverviewMultiSelection(_ ids: Set<String>, for kind: InventoryItemKind) {
        if ids.count == 1, let id = ids.first {
            updateOverviewSelection(id, for: kind)
            return
        }
        overviewSelectionByKind.removeValue(forKey: kind)
        if ids.isEmpty {
            overviewMultiSelectionByKind.removeValue(forKey: kind)
        } else {
            overviewMultiSelectionByKind[kind] = ids
        }
        if selectedKind == kind {
            selectedItemID = nil
        }
    }

    func updateOverviewScrollOffset(_ offset: Double, for kind: InventoryItemKind) {
        guard offset.isFinite else { return }
        overviewScrollOffsetByKind[kind] = max(0, offset)
    }

    func consumeOverviewRestoreRequest(revision: Int) {
        guard overviewRestoreRequest?.revision == revision else { return }
        overviewRestoreRequest = nil
    }

    func confirmDiscardAndContinue() {
        isEditorDirty = false
        isDiscardConfirmationPresented = false
        let target = pendingEditorNavigation
        pendingEditorNavigation = nil
        switch target {
        case let .route(route):
            if route == .capture {
                openNewItem(selectedKind)
                return
            }
            if route == .overview, let pendingOverviewReturn {
                scheduleOverviewRestore(
                    kind: pendingOverviewReturn.kind,
                    itemID: pendingOverviewReturn.itemID
                )
            }
            self.route = route
        case let .new(kind):
            openNewItem(kind)
        case let .edit(kind, id):
            openEditor(kind: kind, id: id)
        case nil:
            break
        }
    }

    func cancelDiscard() {
        pendingEditorNavigation = nil
        isDiscardConfirmationPresented = false
        navigationRevision += 1
    }

    func shouldAllowWindowClose() -> Bool {
        guard needsDiscardConfirmation else { return true }
        isWindowCloseConfirmationPresented = true
        return false
    }

    func confirmDiscardAndCloseWindow() {
        isEditorDirty = false
        isWindowCloseConfirmationPresented = false
        windowCloseRevision += 1
    }

    func cancelWindowClose() {
        isWindowCloseConfirmationPresented = false
    }

    func editorDraft() -> InventoryDraft {
        guard let selectedItemID else {
            return InventoryDraft(kind: selectedKind)
        }
        return InventoryDraft(kind: selectedKind, id: selectedItemID, in: snapshot)
            ?? InventoryDraft(kind: selectedKind)
    }

    /// Changes whenever the editor is opened anew, so a duplicate is loaded
    /// even if the editor already showed an empty draft of the same kind.
    var editorIdentity: String {
        "\(selectedKind.rawValue)::\(selectedItemID ?? "new")::\(editorRevision)"
    }

    /// The editor takes the prepared copy exactly once.
    func takePendingDuplicate() -> PendingDuplicate? {
        defer { pendingDuplicate = nil }
        guard pendingDuplicate?.draft.kind == selectedKind, selectedItemID == nil else { return nil }
        return pendingDuplicate
    }

    // MARK: Comfort

    /// Opens the editor with an unsaved copy of an entry, including copies
    /// of its photos. Nothing is written until the copy is saved.
    @discardableResult
    func duplicateItem(kind: InventoryItemKind, id: String) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        guard !needsDiscardConfirmation else {
            editorSaveState = .failed(Self.finishDraftFirstMessage)
            return false
        }
        guard let source = InventoryDraft(kind: kind, id: id, in: snapshot) else {
            editorSaveState = .failed(InventoryEditingError.missingItem.localizedDescription)
            return false
        }
        var copy = source.duplicated()
        let records = source.photoIDs.compactMap { photoID in
            snapshot.photos.first { $0.id == photoID }
        }
        let copies = await photoService.duplicate(
            records,
            owner: PhotoOwner(type: photoOwnerType(for: kind), id: copy.id)
        )
        let photos = copies.map(\.photo)
        let newIDs = Dictionary(copies.map { ($0.sourceID, $0.photo.record.id) }, uniquingKeysWith: { first, _ in first })
        copy.photoIDs = photos.map(\.record.id)
        copy.mainPhotoID = source.mainPhotoID.flatMap { newIDs[$0] } ?? copy.photoIDs.first
        openNewItem(kind)
        pendingDuplicate = PendingDuplicate(draft: copy, photos: photos)
        return true
    }

    /// Adds photos to an entry without opening the editor, for example when
    /// images are dropped onto it in the overview or gallery.
    @discardableResult
    func addPhotos(urls: [URL], toItem kind: InventoryItemKind, id: String) async -> Bool {
        guard !urls.isEmpty else { return false }
        return await serializedWrite {
            await self.performAddPhotos(urls: urls, kind: kind, id: id)
        }
    }

    private func performAddPhotos(urls: [URL], kind: InventoryItemKind, id: String) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        guard var draft = InventoryDraft(kind: kind, id: id, in: snapshot) else {
            editorSaveState = .failed(InventoryEditingError.missingItem.localizedDescription)
            return false
        }
        do {
            let photos = try await photoService.prepare(
                urls: urls,
                owner: PhotoOwner(type: photoOwnerType(for: kind), id: id)
            )
            // The entry may have changed while the photos were prepared.
            guard let current = InventoryDraft(kind: kind, id: id, in: snapshot) else {
                throw InventoryEditingError.missingItem
            }
            draft = current
            draft.photoIDs.append(contentsOf: photos.map(\.record.id))
            if draft.mainPhotoID == nil {
                draft.mainPhotoID = draft.photoIDs.first
            }
            let result = try editingService.saving(draft, newPhotos: photos.map(\.record), in: snapshot)
            try await photoService.commit(photos)
            do {
                try await repository.saveSnapshot(result.snapshot)
            } catch {
                await photoService.remove(photos.map(\.record))
                throw error
            }
            await discardUndoableDeletion()
            snapshot = result.snapshot
            editorSaveState = .saved(L10n.text(
                "%lld Fotos zu „%@“ hinzugefügt.",
                arguments: photos.count,
                draft.normalizedName
            ))
            scheduleAutomaticBackup()
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    /// Sets the chosen fields on all given entries in one write. The change
    /// can be undone like a deletion until the next change.
    @discardableResult
    func applyBulkEdit(
        _ changes: [BulkEditField: String],
        kind: InventoryItemKind,
        ids: Set<String>
    ) async -> Bool {
        await serializedWrite {
            await self.performBulkEdit(changes, kind: kind, ids: ids)
        }
    }

    private func performBulkEdit(
        _ changes: [BulkEditField: String],
        kind: InventoryItemKind,
        ids: Set<String>
    ) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        guard !changes.isEmpty, !ids.isEmpty else { return false }
        let ordered = InventoryQuery.items(in: snapshot, kind: kind).map(\.id).filter(ids.contains)
        do {
            let previous = snapshot
            let updated = try editingService.applyingBulkEdit(changes, kind: kind, ids: ordered, in: snapshot)
            try await repository.saveSnapshot(updated)
            await discardUndoableDeletion()
            undoableDeletion = UndoableDeletion(
                kind: kind,
                itemID: ordered.first ?? "",
                name: "",
                previousSnapshot: previous,
                photos: [],
                holdID: UUID().uuidString,
                change: .bulkEdit(ordered.count)
            )
            snapshot = updated
            editorSaveState = .saved(L10n.text("%lld Einträge wurden geändert.", arguments: ordered.count))
            scheduleAutomaticBackup()
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    /// Checks a CSV file for the given kind without changing anything.
    func previewCSVImport(_ text: String, kind: InventoryItemKind) throws -> InventoryCSVImportPreview {
        try InventoryCSV.preview(text, kind: kind, in: snapshot)
    }

    /// Creates the entries of a checked CSV file in one write. Rows are
    /// checked again against the current state, so nothing changed in the
    /// meantime can be overwritten or duplicated.
    @discardableResult
    func importCSV(_ text: String, kind: InventoryItemKind) async -> Bool {
        await serializedWrite { await self.performImportCSV(text, kind: kind) }
    }

    private func performImportCSV(_ text: String, kind: InventoryItemKind) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        do {
            let preview = try InventoryCSV.preview(text, kind: kind, in: snapshot)
            guard !preview.drafts.isEmpty else {
                editorSaveState = .failed(L10n.text("Die CSV-Datei enthält keine neuen Einträge."))
                return false
            }
            let previous = snapshot
            var updated = snapshot
            for draft in preview.drafts {
                updated = try editingService.saving(draft, newPhotos: [], in: updated).snapshot
            }
            try await repository.saveSnapshot(updated)
            await discardUndoableDeletion()
            undoableDeletion = UndoableDeletion(
                kind: kind,
                itemID: preview.drafts.first?.id ?? "",
                name: "",
                previousSnapshot: previous,
                photos: [],
                holdID: UUID().uuidString,
                change: .csvImport(preview.drafts.count)
            )
            snapshot = updated
            selectedKind = kind
            editorSaveState = .saved(L10n.text(
                "%lld Einträge wurden aus der CSV-Datei übernommen.",
                arguments: preview.drafts.count
            ))
            scheduleAutomaticBackup()
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    /// Writes the given entries, in the given order, as a CSV file.
    func exportCSV(kind: InventoryItemKind, ids: [String], to url: URL) -> Bool {
        let text = InventoryCSV.export(snapshot, kind: kind, ids: ids)
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            editorSaveState = .saved(L10n.text(
                "%lld Einträge als CSV gespeichert: %@",
                arguments: ids.count,
                url.lastPathComponent
            ))
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func preparePhotos(urls: [URL], for draft: InventoryDraft) async throws -> [PreparedPhoto] {
        let owner = PhotoOwner(type: photoOwnerType(for: draft.kind), id: draft.id)
        return try await photoService.prepare(urls: urls, owner: owner)
    }

    func prepareExternalPhotos(urlStrings: [String], for draft: InventoryDraft) async throws -> [PreparedPhoto] {
        let owner = PhotoOwner(type: photoOwnerType(for: draft.kind), id: draft.id)
        return try await photoService.prepareExternal(urlStrings: urlStrings, owner: owner)
    }

    func photoRecord(id: String?) -> PhotoRecord? {
        guard let id else { return nil }
        return snapshot.photos.first { $0.id == id }
    }

    func thumbnailData(for record: PhotoRecord) async -> Data? {
        await thumbnailService.thumbnailData(for: record)
    }

    func photoData(for record: PhotoRecord) async -> Data? {
        await photoService.data(for: record)
    }

    func save(_ draft: InventoryDraft, preparedPhotos: [PreparedPhoto]) async -> Bool {
        editorSaveState = .saving
        return await serializedWrite {
            await self.performSave(draft, preparedPhotos: preparedPhotos)
        }
    }

    private func performSave(_ draft: InventoryDraft, preparedPhotos: [PreparedPhoto]) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        editorSaveState = .saving
        var draft = draft
        for photo in preparedPhotos where !draft.photoIDs.contains(photo.record.id) {
            draft.photoIDs.append(photo.record.id)
        }
        if draft.mainPhotoID == nil {
            draft.mainPhotoID = draft.photoIDs.first
        }

        do {
            let result = try editingService.saving(
                draft,
                newPhotos: preparedPhotos.map(\.record),
                in: snapshot
            )
            try await photoService.commit(preparedPhotos)
            do {
                try await repository.saveSnapshot(result.snapshot)
            } catch {
                await photoService.remove(preparedPhotos.map(\.record))
                throw error
            }
            await photoService.remove(result.removedPhotos)
            await thumbnailService.remove(result.removedPhotos)
            await discardUndoableDeletion()
            snapshot = result.snapshot
            selectedKind = draft.kind
            selectedItemID = draft.id
            isEditorDirty = false
            editorSaveState = .saved("„\(draft.normalizedName)“ wurde gespeichert.")
            scheduleAutomaticBackup()
            scheduleOverviewRestore(kind: draft.kind, itemID: draft.id)
            route = .overview
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func deleteItem(kind: InventoryItemKind, id: String) async -> Bool {
        editorSaveState = .saving
        let wasEditing = route == .capture
        return await serializedWrite {
            await self.performDeleteItem(kind: kind, id: id, wasEditing: wasEditing)
        }
    }

    private func performDeleteItem(kind: InventoryItemKind, id: String, wasEditing: Bool) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        editorSaveState = .saving
        do {
            let result = try editingService.deleting(kind: kind, id: id, in: snapshot)
            let previousSnapshot = snapshot
            let itemName = InventoryQuery.items(in: previousSnapshot, kind: kind)
                .first { $0.id == id }?.name ?? ""
            try await repository.saveSnapshot(result.snapshot)
            await discardUndoableDeletion()
            let holdID = UUID().uuidString
            if await photoService.hold(result.removedPhotos, holdID: holdID) {
                undoableDeletion = UndoableDeletion(
                    kind: kind,
                    itemID: id,
                    name: itemName,
                    previousSnapshot: previousSnapshot,
                    photos: result.removedPhotos,
                    holdID: holdID
                )
            } else {
                // Without all photos an undo could not restore the item fully.
                await photoService.remove(result.removedPhotos)
                await photoService.discardHold(holdID)
            }
            await thumbnailService.remove(result.removedPhotos)
            snapshot = result.snapshot
            if selectedItemID == id {
                selectedItemID = nil
            }
            isEditorDirty = false
            editorSaveState = .saved("Der Eintrag wurde gelöscht.")
            scheduleAutomaticBackup()
            if wasEditing {
                scheduleOverviewRestore(kind: kind, itemID: nil)
            }
            route = .overview
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func importWarnings(forSwitchSetID id: String) -> [String] {
        snapshot.switchSets.first { $0.id == id }?.importWarnings ?? []
    }

    func clearImportWarnings(switchSetID id: String) async -> Bool {
        await serializedWrite { await self.performClearImportWarnings(switchSetID: id) }
    }

    private func performClearImportWarnings(switchSetID id: String) async -> Bool {
        guard canWriteInventory else {
            editorSaveState = .failed(Self.inventoryNotLoadedMessage)
            return false
        }
        do {
            let updated = try editingService.clearingImportWarnings(switchSetID: id, in: snapshot)
            guard updated != snapshot else { return true }
            try await repository.saveSnapshot(updated)
            await discardUndoableDeletion()
            snapshot = updated
            editorSaveState = .saved(L10n.text("Die Importhinweise wurden entfernt und in den Notizen festgehalten."))
            scheduleAutomaticBackup()
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func clearEditorStatus() {
        editorSaveState = .idle
    }

    func exportBackup(to destinationURL: URL) async {
        if case .exporting = backupExportState {
            return
        }
        backupExportState = .exporting
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
            let result = try await backupExportService.export(
                snapshot: snapshot,
                to: destinationURL,
                appVersion: appVersion
            )
            backupExportState = .succeeded(result)
        } catch {
            backupExportState = .failed(error.localizedDescription)
        }
    }

    func clearBackupExportStatus() {
        if case .exporting = backupExportState {
            return
        }
        backupExportState = .idle
    }

    func exportReport(
        context: InventoryReportContext,
        options: InventoryReportOptions,
        to destinationURL: URL
    ) async {
        reportExportState = .exporting(options.format)
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
            let report = try InventoryReportBuilder.build(
                snapshot: snapshot,
                context: context,
                options: options,
                appVersion: appVersion
            )
            let result = try await reportExportService.export(
                report: report,
                format: options.format,
                to: destinationURL
            )
            reportExportState = .succeeded(result)
        } catch {
            reportExportState = .failed(error.localizedDescription)
        }
    }

    func clearReportExportStatus() {
        if case .exporting = reportExportState {
            return
        }
        reportExportState = .idle
    }

    func libraryValues(for key: String) -> [String] {
        snapshot.libraryValues.valuesByKey[key, default: []]
    }

    /// Common weight materials are offered from the start; materials the
    /// user entered come first and are not repeated.
    func weightMaterialSuggestions() -> [String] {
        suggestions(for: "boardWeightMaterials", defaults: [
            L10n.text("Aluminium"),
            L10n.text("Edelstahl"),
            L10n.text("Kupfer"),
            L10n.text("Messing"),
            L10n.text("Stahl"),
            L10n.text("Titan")
        ])
    }

    func mountingSuggestions() -> [String] {
        suggestions(for: "boardMountings", defaults: [
            "Gasket", "Top Mount", "Tray Mount", "Sandwich", "Leaf Spring", "O-Ring"
        ])
    }

    func caseMaterialSuggestions() -> [String] {
        suggestions(for: "boardCaseMaterials", defaults: [
            L10n.text("Aluminium"),
            L10n.text("Polycarbonat"),
            L10n.text("Acryl"),
            L10n.text("Messing"),
            L10n.text("Kupfer")
        ])
    }

    func layoutSuggestions() -> [String] {
        suggestions(for: "boardLayouts", defaults: ["ANSI", "ISO", "ANSI/ISO"])
    }

    private func suggestions(for key: String, defaults: [String]) -> [String] {
        var seen = Set<String>()
        return (libraryValues(for: key) + defaults).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    var statistics: InventoryStatistics {
        InventoryStatistics(snapshot: snapshot)
    }

    private var needsDiscardConfirmation: Bool {
        route == .capture && isEditorDirty
    }

    private func openNewItem(_ kind: InventoryItemKind) {
        pendingOverviewReturn = nil
        pendingDuplicate = nil
        editorRevision += 1
        selectedKind = kind
        selectedItemID = nil
        editorSaveState = .idle
        isEditorDirty = false
        route = .capture
    }

    private func openEditor(kind: InventoryItemKind, id: String) {
        updateOverviewSelection(id, for: kind)
        pendingOverviewReturn = OverviewReturnContext(
            kind: kind,
            itemID: id,
            scrollOffset: overviewScrollOffsetByKind[kind]
        )
        pendingDuplicate = nil
        editorRevision += 1
        selectedKind = kind
        selectedItemID = id
        editorSaveState = .idle
        isEditorDirty = false
        route = .capture
    }

    private func scheduleOverviewRestore(kind: InventoryItemKind, itemID: String?) {
        let scrollOffset: Double?
        if pendingOverviewReturn?.kind == kind {
            scrollOffset = pendingOverviewReturn?.scrollOffset
        } else {
            scrollOffset = nil
        }
        overviewRestoreRevision += 1
        overviewRestoreRequest = OverviewRestoreRequest(
            revision: overviewRestoreRevision,
            kind: kind,
            itemID: itemID,
            scrollOffset: scrollOffset
        )
        selectedKind = kind
        updateOverviewSelection(itemID, for: kind)
        pendingOverviewReturn = nil
    }

    private func photoOwnerType(for kind: InventoryItemKind) -> PhotoOwnerType {
        switch kind {
        case .board: .board
        case .keycapSet: .keycapSet
        case .artisanSet: .artisanSet
        case .switchSet: .switchSet
        }
    }

    func showMigration() {
        requestRoute(.migration)
    }

    func discoverMigrationSources(force: Bool = false) async {
        if !force, migrationDiscoveryState != .idle {
            return
        }
        migrationDiscoveryState = .scanning
        let canUpdateReadiness = migrationInspectionState == .idle

        do {
            let result = try await migrationService.discoverInstalledSource()
            guard let source = result.source else {
                migrationDiscoveryState = .notFound(
                    searchedCandidateCount: result.searchedCandidateCount
                )
                if canUpdateReadiness {
                    migrationReadiness = .notScanned
                }
                return
            }

            if result.isV1Running {
                let reason = V1SourceDiscoveryError.v1IsRunning.localizedDescription
                migrationDiscoveryState = .blocked(source, reason: reason)
                if canUpdateReadiness {
                    migrationReadiness = .blocked(reason: reason)
                }
            } else {
                migrationDiscoveryState = .found(source)
                if canUpdateReadiness {
                    migrationReadiness = .ready(sourceCount: 1)
                }
            }
        } catch {
            migrationDiscoveryState = .failed(error.localizedDescription)
            if canUpdateReadiness {
                migrationReadiness = .blocked(reason: error.localizedDescription)
            }
        }
    }

    func inspectDiscoveredMigrationSource() async {
        guard case let .found(source) = migrationDiscoveryState else { return }
        await inspectMigrationSource(at: source.directoryURL)
    }

    func inspectMigrationSource(at url: URL) async {
        let fileName = url.lastPathComponent
        migrationReadiness = .scanning
        migrationInspectionState = .inspecting(fileName: fileName)
        migrationCommitState = .idle
        migrationReportURL = nil
        pendingMigrationSnapshot = nil
        pendingMigrationResult = nil
        pendingMigrationSourceURL = nil

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try await migrationService.inspectSource(at: url)
            pendingMigrationSnapshot = result.snapshot
            pendingMigrationResult = result
            pendingMigrationSourceURL = url
            migrationInspectionState = .ready(result.report)
            migrationReadiness = .ready(sourceCount: 1)
        } catch {
            let message = error.localizedDescription
            migrationInspectionState = .failed(message)
            migrationReadiness = .blocked(reason: message)
            if let discoverySource = discoveredSource(matching: url),
               error is V1SourceDiscoveryError {
                migrationDiscoveryState = .blocked(discoverySource, reason: message)
            }
        }
    }

    var hasExistingV2Data: Bool {
        // Without a loaded snapshot the stored state is unknown, so the UI
        // must assume data exists and warn before replacing it.
        guard loadState == .loaded else { return true }
        return snapshot.counts.totalItems > 0 || snapshot.counts.photos > 0
    }

    var canCommitMigration: Bool {
        // A failed load may still be replaced by a migration, because the
        // commit moves the unreadable data into a backup first. While the
        // initial load is pending the outcome is unknown, so wait for it.
        switch loadState {
        case .idle, .loading:
            return false
        case .loaded, .failed:
            break
        }
        guard case let .ready(report) = migrationInspectionState,
              report.canImport,
              pendingMigrationResult != nil,
              pendingMigrationSourceURL != nil else {
            return false
        }
        if case .committing = migrationCommitState { return false }
        if case .succeeded = migrationCommitState { return false }
        return true
    }

    func commitPendingMigration() async {
        await serializedWrite { await self.performCommitPendingMigration() }
    }

    private func performCommitPendingMigration() async {
        guard let sourceURL = pendingMigrationSourceURL,
              let dryRun = pendingMigrationResult,
              canCommitMigration else {
            return
        }

        migrationCommitState = .committing(fileName: dryRun.report.sourceFileName)
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try await migrationCommitService.commit(
                backupURL: sourceURL,
                expectedDryRun: dryRun
            )
            await discardUndoableDeletion()
            snapshot = result.snapshot
            loadState = .loaded
            migrationReportURL = result.reportURL
            migrationCommitState = .succeeded(result.report)
            scheduleAutomaticBackup()
            migrationReadiness = .ready(sourceCount: 1)
        } catch {
            migrationCommitState = .failed(error.localizedDescription)
            if dryRun.report.sourceKind == .sqliteDirectory,
               let discoverySource = discoveredSource(matching: sourceURL),
               error is V1SourceDiscoveryError {
                migrationDiscoveryState = .blocked(
                    discoverySource,
                    reason: error.localizedDescription
                )
            }
        }
    }

    // MARK: Undo deletion

    static var finishDraftFirstMessage: String {
        L10n.text("Bitte speichere oder verwirf zuerst den geöffneten Entwurf.")
    }

    /// Restores the state from before the last deletion. It stays available
    /// only until the next change, so nothing newer can be lost by it.
    func undoLastDeletion() async {
        await serializedWrite { await self.performUndoLastDeletion() }
    }

    /// Makes the last deletion final and frees its photos.
    func dismissUndoableDeletion() async {
        await serializedWrite { await self.discardUndoableDeletion() }
    }

    /// Photos held by a previous session can no longer be restored.
    func purgeAbandonedDeletions() async {
        await serializedWrite {
            guard self.undoableDeletion == nil else { return }
            await self.photoService.discardAllHolds()
        }
    }

    private func performUndoLastDeletion() async {
        guard let undo = undoableDeletion, canWriteInventory else { return }
        guard !needsDiscardConfirmation else {
            editorSaveState = .failed(Self.finishDraftFirstMessage)
            return
        }
        do {
            try await photoService.restoreHeld(undo.photos, holdID: undo.holdID)
            do {
                try await repository.saveSnapshot(undo.previousSnapshot)
            } catch {
                _ = await photoService.hold(undo.photos, holdID: undo.holdID)
                throw error
            }
            await photoService.discardHold(undo.holdID)
            undoableDeletion = nil
            snapshot = undo.previousSnapshot
            isEditorDirty = false
            let undoneItemExists = InventoryQuery.items(in: undo.previousSnapshot, kind: undo.kind)
                .contains { $0.id == undo.itemID }
            scheduleOverviewRestore(kind: undo.kind, itemID: undoneItemExists ? undo.itemID : nil)
            route = .overview
            editorSaveState = .saved(undo.change.undoneMessage(name: undo.name))
            scheduleAutomaticBackup()
        } catch {
            editorSaveState = .failed(error.localizedDescription)
        }
    }

    private func discardUndoableDeletion() async {
        guard let undo = undoableDeletion else { return }
        undoableDeletion = nil
        await photoService.discardHold(undo.holdID)
    }

    // MARK: Restore from automatic backups

    /// Replaces the collection with an automatic backup through the migration
    /// pipeline: the backup is verified first and the current data is moved
    /// to `Backups/` before the restored state becomes active. Also works
    /// after a failed load, where it is the way back to a usable collection.
    func restoreAutomaticBackup(_ entry: AutomaticBackupEntry) async {
        await serializedWrite { await self.performRestoreAutomaticBackup(entry) }
    }

    func clearBackupRestoreStatus() {
        if case .restoring = backupRestoreState { return }
        backupRestoreState = .idle
    }

    private func performRestoreAutomaticBackup(_ entry: AutomaticBackupEntry) async {
        guard let automaticBackupService,
              AutomaticBackupService.entry(for: entry.url) != nil,
              entry.url.deletingLastPathComponent().standardizedFileURL
                == automaticBackupService.directoryURL else {
            backupRestoreState = .failed(L10n.text("Dieses Backup kann nicht wiederhergestellt werden."))
            return
        }
        guard !needsDiscardConfirmation else {
            backupRestoreState = .failed(Self.finishDraftFirstMessage)
            return
        }
        backupRestoreState = .restoring
        do {
            let dryRun = try await migrationService.inspectSource(at: entry.url)
            let result = try await migrationCommitService.commit(
                backupURL: entry.url,
                expectedDryRun: dryRun
            )
            await discardUndoableDeletion()
            snapshot = result.snapshot
            loadState = .loaded
            selectedItemID = nil
            isEditorDirty = false
            route = .overview
            pendingMigrationSnapshot = nil
            pendingMigrationResult = nil
            pendingMigrationSourceURL = nil
            migrationInspectionState = .idle
            migrationCommitState = .idle
            backupRestoreState = .succeeded(entry.createdAt)
        } catch {
            backupRestoreState = .failed(error.localizedDescription)
        }
    }

    // MARK: Automatic backups

    var automaticBackupsDirectoryURL: URL? {
        automaticBackupService?.directoryURL
    }

    /// Creates a backup right away, regardless of the daily interval.
    func backUpNow() async {
        await serializedWrite { await self.performAutomaticBackup(force: true) }
    }

    func refreshAutomaticBackupStatus() async {
        guard let automaticBackupService else { return }
        automaticBackupEntries = await automaticBackupService.entries()
        latestAutomaticBackup = automaticBackupEntries.first
    }

    /// Sets or clears the additional folder that receives a copy of every
    /// automatic backup, and copies the existing backups there right away.
    func setBackupMirror(_ url: URL?) async {
        await serializedWrite {
            self.backupMirrorURL = url
            self.backupMirrorError = nil
            if let url {
                self.backupDefaults.set(url.path, forKey: Self.backupMirrorPathKey)
            } else {
                self.backupDefaults.removeObject(forKey: Self.backupMirrorPathKey)
            }
            await self.syncBackupMirror()
        }
    }

    private func syncBackupMirror() async {
        guard let automaticBackupService, let backupMirrorURL else { return }
        do {
            try await automaticBackupService.syncMirror(to: backupMirrorURL)
            backupMirrorError = nil
        } catch {
            backupMirrorError = error.localizedDescription
        }
    }

    /// Waits until every queued write, including scheduled backups, is done.
    func waitForPendingWrites() async {
        await writeChain?.value
    }

    /// Queues a backup check behind the current write. It runs in the same
    /// queue so no save can remove a photo while the archive is being built.
    private func scheduleAutomaticBackup() {
        guard automaticBackupService != nil, automaticBackupsEnabled() else { return }
        enqueueWrite { await self.performAutomaticBackup(force: false) }
    }

    private func performAutomaticBackup(force: Bool) async {
        guard let automaticBackupService, canWriteInventory else { return }
        automaticBackupState = .running
        do {
            let outcome = try await automaticBackupService.backUpIfDue(
                snapshot: snapshot,
                appVersion: appVersion,
                force: force
            )
            switch outcome {
            case let .created(entry):
                latestAutomaticBackup = entry
                automaticBackupState = .created(entry.createdAt)
            case let .skippedUnchanged(entry), let .skippedRecent(entry):
                latestAutomaticBackup = entry
                automaticBackupState = .idle
            case .skippedEmpty:
                automaticBackupState = force ? .nothingToBackUp : .idle
            }
            await refreshAutomaticBackupStatus()
            await syncBackupMirror()
        } catch {
            automaticBackupState = .failed(error.localizedDescription)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Runs inventory writes strictly one after another. Every write builds a
    /// complete new snapshot from `snapshot` and then suspends for photo and
    /// database work; without this queue a second write could start from the
    /// same base and the one finishing last would silently drop the other.
    private func serializedWrite<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T {
        await enqueueWrite(operation).value
    }

    /// Appends a write to the queue synchronously, so the order of calls is
    /// the order of execution.
    @discardableResult
    private func enqueueWrite<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> T
    ) -> Task<T, Never> {
        let previous = writeChain
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        writeChain = Task { @MainActor in
            _ = await task.value
        }
        return task
    }

    private func discoveredSource(matching url: URL) -> V1DiscoveredSource? {
        let source: V1DiscoveredSource?
        switch migrationDiscoveryState {
        case let .found(value), let .blocked(value, _):
            source = value
        case .idle, .scanning, .notFound, .failed:
            source = nil
        }
        guard source?.directoryURL.standardizedFileURL == url.standardizedFileURL else {
            return nil
        }
        return source
    }
}

struct OverviewRestoreRequest: Equatable, Sendable {
    var revision: Int
    var kind: InventoryItemKind
    var itemID: String?
    var scrollOffset: Double?
}

private struct OverviewReturnContext {
    var kind: InventoryItemKind
    var itemID: String
    var scrollOffset: Double?
}

enum EditorSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved(String)
    case failed(String)
}

/// The last change that can still be undone: a deletion, a bulk edit or a
/// CSV import. It holds the complete state from before the change.
struct UndoableDeletion: Equatable, Sendable {
    var kind: InventoryItemKind
    var itemID: String
    var name: String
    var previousSnapshot: InventorySnapshot
    var photos: [PhotoRecord]
    var holdID: String
    var change: UndoableChange = .deletion
}

enum UndoableChange: Equatable, Sendable {
    case deletion
    case bulkEdit(Int)
    case csvImport(Int)

    func statusMessage(name: String) -> String {
        switch self {
        case .deletion: L10n.text("„%@“ wurde gelöscht.", arguments: name)
        case let .bulkEdit(count): L10n.text("%lld Einträge wurden gemeinsam geändert.", arguments: count)
        case let .csvImport(count): L10n.text("%lld Einträge wurden aus CSV importiert.", arguments: count)
        }
    }

    func undoneMessage(name: String) -> String {
        switch self {
        case .deletion: L10n.text("„%@“ wurde wiederhergestellt.", arguments: name)
        case .bulkEdit: L10n.text("Die Sammelbearbeitung wurde rückgängig gemacht.")
        case .csvImport: L10n.text("Der CSV-Import wurde rückgängig gemacht.")
        }
    }

    var menuTitle: String {
        switch self {
        case .deletion: L10n.text("Löschen rückgängig machen")
        case .bulkEdit: L10n.text("Sammelbearbeitung rückgängig machen")
        case .csvImport: L10n.text("CSV-Import rückgängig machen")
        }
    }
}

struct PendingDuplicate: Equatable, Sendable {
    var draft: InventoryDraft
    var photos: [PreparedPhoto]
}

enum BackupRestoreState: Equatable, Sendable {
    case idle
    case restoring
    case succeeded(Date)
    case failed(String)
}

enum AutomaticBackupState: Equatable, Sendable {
    case idle
    case running
    case created(Date)
    case nothingToBackUp
    case failed(String)
}

enum BackupExportState: Equatable, Sendable {
    case idle
    case exporting
    case succeeded(BackupExportResult)
    case failed(String)
}

private enum EditorNavigationTarget {
    case route(AppRoute)
    case new(InventoryItemKind)
    case edit(InventoryItemKind, String)
}
