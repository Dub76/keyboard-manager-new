import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptureView: View {
    @Bindable var store: InventoryStore
    @Environment(\.undoManager) private var undoManager
    @State private var draft = InventoryDraft(kind: .board)
    @State private var baseline = InventoryDraft(kind: .board)
    @State private var preparedPhotos: [PreparedPhoto] = []
    @State private var isPhotoImporterPresented = false
    @State private var isExternalPhotoConfirmationPresented = false
    @State private var isDownloadingExternalPhotos = false
    @State private var externalPhotoDownloadTask: Task<Void, Never>?
    @State private var isDeleteConfirmationPresented = false
    @State private var photoImportError: String?
    @State private var isPhotoDropTargeted = false
    @State private var isLoadingDroppedPhotos = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = CaptureLayout(availableWidth: geometry.size.width)

            VStack(spacing: 0) {
                editorHeader
                Divider()
                HStack(spacing: 0) {
                    editorForm
                        .frame(width: layout.formWidth)
                        .clipped()

                    Divider()

                    preview
                        .frame(width: layout.previewWidth)
                        .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
                if isPhotoDropTargeted {
                    photoDropOverlay
                }
            }
            .onDrop(of: DroppedPhotoLoader.acceptedTypes, isTargeted: $isPhotoDropTargeted) { providers in
                handlePhotoDrop(providers)
            }
        }
        .task(id: store.editorIdentity) {
            loadDraft()
        }
        .onChange(of: draft) {
            updateDirtiness()
        }
        .onChange(of: preparedPhotos) {
            updateDirtiness()
        }
        .onDisappear {
            externalPhotoDownloadTask?.cancel()
            externalPhotoDownloadTask = nil
            isDownloadingExternalPhotos = false
        }
        .fileImporter(
            isPresented: $isPhotoImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handlePhotoSelection
        )
        .alert("Fotoimport fehlgeschlagen", isPresented: photoErrorPresented) {
            Button("OK", role: .cancel) {
                photoImportError = nil
            }
        } message: {
            Text(photoImportError ?? "")
        }
        .confirmationDialog(
            "Externe Importbilder lokal übernehmen?",
            isPresented: $isExternalPhotoConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Herunterladen und lokal übernehmen") {
                downloadExternalPhotos()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                "Keyboard Manager verbindet sich einmalig mit \(externalImageHostSummary). "
                + "Die Antworten werden nur über HTTPS geladen, als Bilder geprüft und erst beim Speichern "
                + "in den lokalen Fotobestand übernommen. Die externen Bildadressen werden danach aus diesem Eintrag entfernt."
            )
        }
        .confirmationDialog(
            "Ungespeicherte Änderungen verwerfen?",
            isPresented: $store.isDiscardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Änderungen verwerfen", role: .destructive) {
                store.confirmDiscardAndContinue()
            }
            Button("Weiter bearbeiten", role: .cancel) {
                store.cancelDiscard()
            }
        } message: {
            Text("Der aktuelle Entwurf wurde noch nicht gespeichert.")
        }
        .confirmationDialog(
            "\(draft.kind.singularName) wirklich löschen?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                Task {
                    _ = await store.deleteItem(kind: draft.kind, id: draft.id)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Eintrag und seine verwalteten Fotos werden dauerhaft entfernt. Verknüpfungen werden konsistent gelöst.")
        }
    }

    private var editorHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                inventoryKindPicker
                    .layoutPriority(1)

                Spacer(minLength: 8)

                editorActionButtons
            }

            VStack(alignment: .trailing, spacing: 10) {
                inventoryKindPicker
                editorActionButtons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inventoryKindPicker: some View {
        HStack(spacing: 10) {
            Text("Inventartyp")
                .font(.callout.weight(.medium))
                .fixedSize()

            Picker("Inventartyp", selection: kindSelection) {
                ForEach(InventoryItemKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
        }
    }

    private var editorActionButtons: some View {
        HStack(spacing: 10) {
            Button("Verwerfen", role: .cancel) {
                store.requestRoute(.overview)
            }
            .accessibilityIdentifier("capture.discard")
            .disabled(isSaving)

            if store.selectedItemID != nil {
                Button("Löschen", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            }

            Button("Speichern") {
                save()
            }
            .accessibilityIdentifier("capture.save")
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .fixedSize()
    }

    private var editorForm: some View {
        Form {
            identitySection
            kindSpecificSections
            relationshipSection
            photoSection
            notesSection
            migrationMetadataSection
        }
        .formStyle(.grouped)
    }

    private var identitySection: some View {
        Section("Basisdaten") {
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("capture.name")
                .focused($isNameFocused)
                .accessibilityLabel("Name, Pflichtfeld")
            if draft.kind != .switchSet {
                LibraryTextField(
                    title: "Hersteller",
                    text: $draft.manufacturer,
                    values: store.libraryValues(for: manufacturerLibraryKey)
                )
            }

            if draft.kind == .keycapSet || draft.kind == .artisanSet {
                LibraryTextField(
                    title: "Profil",
                    text: $draft.profile,
                    values: store.libraryValues(for: draft.kind == .keycapSet ? "keycapProfiles" : "artisanProfiles")
                )
                LibraryTextField(
                    title: "Material",
                    text: $draft.material,
                    values: store.libraryValues(for: draft.kind == .keycapSet ? "keycapMaterials" : "artisanMaterials")
                )
                LibraryTextField(
                    title: "Status",
                    text: $draft.status,
                    values: store.libraryValues(for: draft.kind == .keycapSet ? "keycapStatuses" : "artisanStatuses")
                )
            }
        }
    }

    @ViewBuilder
    private var kindSpecificSections: some View {
        switch draft.kind {
        case .board:
            Section("Keyboard") {
                LibraryTextField(title: "Format", text: $draft.format, values: store.libraryValues(for: "formats"))
                LibraryTextField(title: "Farbe", text: $draft.color, values: store.libraryValues(for: "boardColors"))
                LibraryTextField(title: "Gewicht-Material", text: $draft.weightMaterial, values: store.weightMaterialSuggestions())
                TextField("Gewicht (g)", text: $draft.weightGramsText)
                LibraryTextField(title: "Layout", text: $draft.layout, values: store.layoutSuggestions())
                LibraryTextField(title: "Mounting", text: $draft.mounting, values: store.mountingSuggestions())
                LibraryTextField(title: "Case-Material", text: $draft.caseMaterial, values: store.caseMaterialSuggestions())
                TextField("Tippwinkel", text: $draft.typingAngle)
                LibraryTextField(title: "Plate", text: $draft.plate, values: store.libraryValues(for: "plates"))
                LibraryTextField(title: "PCB", text: $draft.pcb, values: store.libraryValues(for: "pcbs"))
                LibraryTextField(title: "Stabilisatoren", text: $draft.stabilizers, values: store.libraryValues(for: "stabs"))
            }
            Section("Kauf") {
                Picker("Status", selection: $draft.status) {
                    ForEach(BoardStatus.allCases) { status in
                        Text(status.title).tag(status.rawValue)
                    }
                }
                TextField("Preis (€)", text: $draft.purchasePriceText)
                Toggle("Kaufdatum angeben", isOn: hasPurchaseDate)
                if draft.purchaseDate != nil {
                    DatePicker("Kaufdatum", selection: purchaseDate, displayedComponents: .date)
                }
                LibraryTextField(title: "Shop", text: $draft.purchaseShop, values: store.libraryValues(for: "boardShops"))
            }
        case .keycapSet:
            Section("Set-Inhalt") {
                TextField("Kits, durch Komma getrennt", text: listEntriesBinding)
                sourceFields
            }
        case .artisanSet:
            Section("Artisan") {
                TextField("Tags, durch Komma getrennt", text: listEntriesBinding)
                sourceFields
            }
        case .switchSet:
            switchTechnicalSection
        }
    }

    private var sourceFields: some View {
        Group {
            TextField("Shop", text: $draft.sourceShop)
            TextField("HTTPS-Quelladresse", text: $draft.sourceURL)
                .textContentType(.URL)
        }
    }

    private var switchTechnicalSection: some View {
        Group {
            Section("Switch") {
                LibraryTextField(title: "Typ", text: $draft.switchType, values: store.libraryValues(for: "switchTypes"))
                Picker("Pins", selection: $draft.pins) {
                    ForEach(SwitchPins.allCases) { pins in
                        Text(pins.displayName).tag(pins)
                    }
                }
                TextField("Gesamtbestand", value: $draft.quantity, format: .number)
                Toggle("LED-Diffusor", isOn: $draft.hasLEDDiffuser)
                Toggle("Werkseitig geschmiert", isOn: $draft.isFactoryLubed)
            }

            Section("Materialien") {
                LibraryTextField(title: "Top Housing", text: $draft.topHousingMaterial, values: store.libraryValues(for: "switchTopHousingMaterials"))
                LibraryTextField(title: "Bottom Housing", text: $draft.bottomHousingMaterial, values: store.libraryValues(for: "switchBottomHousingMaterials"))
                LibraryTextField(title: "Stem", text: $draft.stemMaterial, values: store.libraryValues(for: "switchStemMaterials"))
                LibraryTextField(title: "Federlänge", text: $draft.springLength, values: store.libraryValues(for: "switchSpringLengths"))
                LibraryTextField(title: "Federtyp", text: $draft.springType, values: store.libraryValues(for: "switchSpringTypes"))
            }

            Section("Wege und Kräfte") {
                LibraryTextField(title: "Pre-Travel", text: $draft.preTravel, values: store.libraryValues(for: "switchPreTravels"))
                LibraryTextField(title: "Total Travel", text: $draft.totalTravel, values: store.libraryValues(for: "switchTotalTravels"))
                LibraryTextField(title: "Operating Force", text: $draft.operatingForce, values: store.libraryValues(for: "switchOperatingForces"))
                LibraryTextField(title: "Bottom-out Force", text: $draft.bottomOutForce, values: store.libraryValues(for: "switchBottomOutForces"))
            }
        }
    }

    @ViewBuilder
    private var relationshipSection: some View {
        switch draft.kind {
        case .board:
            Section("Komponenten") {
                Picker("Keycap-Set", selection: optionalSelection($draft.keycapSetID)) {
                    Text("Nicht zugeordnet").tag("")
                    ForEach(store.snapshot.keycapSets.sorted(by: nameSort)) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                if store.snapshot.switchSets.isEmpty {
                    Text("Noch keine Switch-Sets vorhanden.")
                        .foregroundStyle(.secondary)
                } else {
                    boardSwitchInstallations
                }
            }
        case .keycapSet, .artisanSet:
            Section("Montage") {
                Picker("Board", selection: optionalSelection($draft.mountedBoardID)) {
                    Text("Nicht montiert").tag("")
                    ForEach(store.snapshot.boards.sorted(by: nameSort)) { board in
                        Text(board.name).tag(board.id)
                    }
                }
            }
        case .switchSet:
            Section("Installationen") {
                if store.snapshot.boards.isEmpty {
                    Text("Noch keine Boards vorhanden.")
                        .foregroundStyle(.secondary)
                } else {
                    switchBoardInstallations
                    LabeledContent("Verbaut") {
                        Text(draft.installations.values.reduce(0, +), format: .number)
                            .monospacedDigit()
                    }
                    LabeledContent("Verfügbar") {
                        Text(max(draft.quantity - draft.installations.values.reduce(0, +), 0), format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var photoSection: some View {
        Section("Fotos") {
            if allPhotoIDs.isEmpty {
                Text("Noch keine lokalen Fotos.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(allPhotoIDs, id: \.self) { photoID in
                            PhotoEditorTile(
                                image: image(for: photoID),
                                isMain: draft.mainPhotoID == photoID,
                                setMain: {
                                    registerStructuralUndo()
                                    draft.mainPhotoID = photoID
                                },
                                remove: {
                                    registerStructuralUndo()
                                    removePhoto(photoID)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 132)
            }

            HStack {
                Button {
                    isPhotoImporterPresented = true
                } label: {
                    Label("Fotos hinzufügen …", systemImage: "photo.badge.plus")
                }
                if isLoadingDroppedPhotos {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("Oder Fotos aus Finder, Fotos oder dem Browser hierher ziehen.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !externalImageURLs.isEmpty {
                Divider()
                LabeledContent("Externe Importbilder") {
                    Text(externalImageURLs.count, format: .number)
                        .monospacedDigit()
                }
                Text("Diese importierten Bildadressen werden nicht automatisch aufgerufen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    isExternalPhotoConfirmationPresented = true
                } label: {
                    Label(
                        isDownloadingExternalPhotos
                            ? "Importbilder werden geladen …"
                            : "Importbilder herunterladen und lokal übernehmen …",
                        systemImage: "icloud.and.arrow.down"
                    )
                }
                .disabled(isDownloadingExternalPhotos)

                if isDownloadingExternalPhotos {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("JPEG, PNG, GIF, WebP und HEIC; maximal 30 MiB. Große Bilder werden auf höchstens 1920 × 1080 Pixel skaliert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var notesSection: some View {
        Section("Notizen") {
            TextEditor(text: $draft.notes)
                .font(.body)
                .frame(minHeight: 100)
                .accessibilityLabel("Notizen")
        }
    }

    @ViewBuilder
    private var migrationMetadataSection: some View {
        if draft.kind == .switchSet, !draft.importWarnings.isEmpty {
            Section("Migrationshinweise") {
                ForEach(draft.importWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Group {
                if let mainPhotoID = draft.mainPhotoID, let image = image(for: mainPhotoID) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(.rect(cornerRadius: 10))
                } else {
                    ContentUnavailableView(
                        "Kein Hauptfoto",
                        systemImage: draft.kind.systemImage,
                        description: Text("Ein hinzugefügtes Foto kann als Hauptfoto markiert werden.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 190)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(draft.normalizedName.isEmpty ? "Unbenannter Entwurf" : draft.normalizedName)
                    .font(.title2.weight(.semibold))
                if !draft.manufacturer.isEmpty {
                    Text(draft.manufacturer)
                        .foregroundStyle(.secondary)
                }
                Label("\(allPhotoIDs.count) Fotos", systemImage: "photo.on.rectangle")
                previewDetails
            }

            Divider()
            saveStatus
            Spacer()
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var previewDetails: some View {
        switch draft.kind {
        case .board:
            if !draft.format.isEmpty { Label(draft.format, systemImage: "rectangle.split.3x1") }
            if !draft.color.isEmpty { Label(draft.color, systemImage: "paintpalette") }
            if !draft.weightMaterial.isEmpty { Label("Gewicht-Material: \(draft.weightMaterial)", systemImage: "scalemass") }
            if !draft.pcb.isEmpty { Label("PCB: \(draft.pcb)", systemImage: "cpu") }
            if !draft.plate.isEmpty { Label("Plate: \(draft.plate)", systemImage: "square.grid.3x3") }
        case .keycapSet:
            if !draft.profile.isEmpty { Label(draft.profile, systemImage: "square.grid.3x3") }
            if !draft.normalizedListEntries.isEmpty {
                Text(draft.normalizedListEntries.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .artisanSet:
            if !draft.normalizedListEntries.isEmpty {
                Text(draft.normalizedListEntries.map { "#\($0)" }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .switchSet:
            Label(draft.pins.displayName, systemImage: "switch.2")
            Label("\(draft.quantity) gesamt · \(max(draft.quantity - draft.installations.values.reduce(0, +), 0)) verfügbar", systemImage: "number")
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch store.editorSaveState {
        case .idle:
            Label(store.isEditorDirty ? "Ungespeicherte Änderungen" : "Keine Änderungen", systemImage: store.isEditorDirty ? "circle.fill" : "checkmark.circle")
                .foregroundStyle(store.isEditorDirty ? .orange : .secondary)
        case .saving:
            HStack {
                ProgressView().controlSize(.small)
                Text("Wird gespeichert …")
            }
        case let .saved(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var kindSelection: Binding<InventoryItemKind> {
        Binding(
            get: { store.selectedKind },
            set: { store.prepareNewItem($0) }
        )
    }

    private var listEntriesBinding: Binding<String> {
        Binding(
            get: { draft.listEntries.joined(separator: ", ") },
            set: { draft.listEntries = $0.components(separatedBy: ",") }
        )
    }

    private var allPhotoIDs: [String] {
        draft.photoIDs
    }

    private var manufacturerLibraryKey: String {
        switch draft.kind {
        case .board: "manufacturers"
        case .keycapSet: "keycapManufacturers"
        case .artisanSet: "artisanManufacturers"
        case .switchSet: ""
        }
    }

    private var isSaving: Bool {
        if isDownloadingExternalPhotos { return true }
        if case .saving = store.editorSaveState { return true }
        return false
    }

    private var externalImageURLs: [String] {
        var seen = Set<String>()
        return ([draft.coverURL] + draft.externalImageURLs).filter { value in
            !value.isEmpty && seen.insert(value).inserted
        }
    }

    private var externalImageHostSummary: String {
        let hosts = externalImageURLs.compactMap {
            URLComponents(string: $0)?.host
        }
        let uniqueHosts = Array(Set(hosts)).sorted()
        if uniqueHosts.isEmpty {
            return L10n.text("den hinterlegten Bildservern")
        }
        if uniqueHosts.count <= 3 {
            return uniqueHosts.joined(separator: ", ")
        }
        return uniqueHosts.prefix(3).joined(separator: ", ")
            + " und \(uniqueHosts.count - 3) weiteren Hosts"
    }

    private var photoErrorPresented: Binding<Bool> {
        Binding(
            get: { photoImportError != nil },
            set: { if !$0 { photoImportError = nil } }
        )
    }

    private func optionalSelection(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func installationRows(
        values: [(id: String, name: String, total: Int?)],
        label: String,
        removeLabel: String
    ) -> some View {
        Group {
            Text(label)
                .font(.headline)
            ForEach(values, id: \.id) { value in
                let installedQuantity = draft.installations[value.id, default: 0]
                HStack {
                    Text(value.name)
                    Spacer()
                    if let total = value.total {
                        Text("\(installedQuantity) von \(total) verbaut")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("\(installedQuantity) verbaut")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Stepper(
                        value: installationBinding(value.id),
                        in: 1 ... max(value.total ?? 10_000, 1)
                    ) {
                        EmptyView()
                    }
                    .labelsHidden()

                    Button(removeLabel, systemImage: "minus.circle") {
                        draft.installations.removeValue(forKey: value.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(value.name) entfernen")
                }
            }
        }
    }

    @ViewBuilder
    private var boardSwitchInstallations: some View {
        let installed = store.snapshot.switchSets
            .filter { (draft.installations[$0.id] ?? 0) > 0 }
            .sorted(by: nameSort)
            .map { ($0.id, $0.name, Optional($0.quantity)) }
        let available = store.snapshot.switchSets
            .filter { draft.installations[$0.id] == nil }
            .sorted(by: nameSort)

        if installed.isEmpty {
            Text("Noch keine Switches zugeordnet.")
                .foregroundStyle(.secondary)
        } else {
            installationRows(
                values: installed,
                label: "Verbaute Switches",
                removeLabel: "Switch entfernen"
            )
        }

        Menu("Switch hinzufügen …") {
            ForEach(available) { switchSet in
                Button(switchSet.name) {
                    draft.installations[switchSet.id] = 1
                }
            }
        }
        .disabled(available.isEmpty)
    }

    @ViewBuilder
    private var switchBoardInstallations: some View {
        let installed = store.snapshot.boards
            .filter { (draft.installations[$0.id] ?? 0) > 0 }
            .sorted(by: nameSort)
            .map { ($0.id, $0.name, Optional<Int>.none) }
        let available = store.snapshot.boards
            .filter { draft.installations[$0.id] == nil }
            .sorted(by: nameSort)

        if installed.isEmpty {
            Text("Noch auf keinem Board installiert.")
                .foregroundStyle(.secondary)
        } else {
            installationRows(
                values: installed,
                label: "Installierte Boards",
                removeLabel: "Board entfernen"
            )
        }

        Menu("Board hinzufügen …") {
            ForEach(available) { board in
                Button(board.name) {
                    draft.installations[board.id] = 1
                }
            }
        }
        .disabled(available.isEmpty)
    }

    private func installationBinding(_ id: String) -> Binding<Int> {
        Binding(
            get: { draft.installations[id, default: 0] },
            set: {
                if $0 == 0 {
                    draft.installations.removeValue(forKey: id)
                } else {
                    draft.installations[id] = $0
                }
            }
        )
    }

    private func loadDraft() {
        externalPhotoDownloadTask?.cancel()
        externalPhotoDownloadTask = nil
        isDownloadingExternalPhotos = false
        let loaded = store.editorDraft()
        draft = loaded
        baseline = loaded
        preparedPhotos = []
        photoImportError = nil
        store.isEditorDirty = false
        store.clearEditorStatus()
        Task { @MainActor in
            isNameFocused = true
        }
    }

    private func updateDirtiness() {
        store.isEditorDirty = draft != baseline || !preparedPhotos.isEmpty
        if store.isEditorDirty {
            store.clearEditorStatus()
        }
    }

    private func save() {
        Task {
            let succeeded = await store.save(draft, preparedPhotos: preparedPhotos)
            if succeeded {
                baseline = draft
                preparedPhotos = []
            }
        }
    }

    private var hasPurchaseDate: Binding<Bool> {
        Binding(
            get: { draft.purchaseDate != nil },
            set: { draft.purchaseDate = $0 ? (draft.purchaseDate ?? .now) : nil }
        )
    }

    private var purchaseDate: Binding<Date> {
        Binding(
            get: { draft.purchaseDate ?? .now },
            set: { draft.purchaseDate = $0 }
        )
    }

    private func handlePhotoSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task {
                await addPhotos(from: urls)
            }
        case let .failure(error):
            photoImportError = error.localizedDescription
        }
    }

    /// Shared by the file dialog and drag and drop, so dropped photos get the
    /// same checks, scaling and GPS removal as chosen ones.
    private func addPhotos(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            let photos = try await store.preparePhotos(urls: urls, for: draft)
            registerStructuralUndo()
            preparedPhotos.append(contentsOf: photos)
            draft.photoIDs.append(contentsOf: photos.map(\.record.id))
            if draft.mainPhotoID == nil {
                draft.mainPhotoID = photos.first?.record.id
            }
        } catch {
            photoImportError = error.localizedDescription
        }
    }

    private func handlePhotoDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !isLoadingDroppedPhotos else { return false }
        isLoadingDroppedPhotos = true
        let loader = DroppedPhotoLoader()
        Task {
            let result = await loader.load(providers)
            await addPhotos(from: result.urls)
            loader.removeTemporaryFiles()
            isLoadingDroppedPhotos = false
            if result.skippedCount > 0, photoImportError == nil {
                photoImportError = L10n.text(
                    "%lld abgelegte Elemente sind keine Bilder und wurden übersprungen.",
                    arguments: result.skippedCount
                )
            }
        }
        return true
    }

    private var photoDropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
            .overlay {
                Label("Fotos hier ablegen", systemImage: "photo.badge.plus")
                    .font(.title2.bold())
                    .padding(14)
                    .background(.regularMaterial, in: .capsule)
            }
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func downloadExternalPhotos() {
        guard !isDownloadingExternalPhotos, !externalImageURLs.isEmpty else { return }
        let urls = externalImageURLs
        isDownloadingExternalPhotos = true

        externalPhotoDownloadTask = Task {
            defer {
                isDownloadingExternalPhotos = false
                externalPhotoDownloadTask = nil
            }
            do {
                let photos = try await store.prepareExternalPhotos(urlStrings: urls, for: draft)
                try Task.checkCancellation()
                registerStructuralUndo()
                preparedPhotos.append(contentsOf: photos)
                draft.photoIDs.append(contentsOf: photos.map(\.record.id))
                if draft.mainPhotoID == nil {
                    draft.mainPhotoID = photos.first?.record.id
                }
                draft.coverURL = ""
                draft.externalImageURLs = []
            } catch is CancellationError {
                return
            } catch {
                photoImportError = error.localizedDescription
            }
        }
    }

    private func removePhoto(_ id: String) {
        draft.photoIDs.removeAll { $0 == id }
        preparedPhotos.removeAll { $0.record.id == id }
        if draft.mainPhotoID == id {
            draft.mainPhotoID = draft.photoIDs.first
        }
    }

    private func image(for photoID: String) -> NSImage? {
        if let prepared = preparedPhotos.first(where: { $0.record.id == photoID }) {
            return NSImage(data: prepared.data)
        }
        guard let record = store.snapshot.photos.first(where: { $0.id == photoID }) else {
            return nil
        }
        guard let fileName = record.managedFileName else { return nil }
        let url = MigrationStorageLayout.default.currentPhotosDirectoryURL
            .appendingPathComponent(fileName)
        return NSImage(contentsOf: url)
    }

    private func registerStructuralUndo() {
        let oldDraft = draft
        let oldPhotos = preparedPhotos
        undoManager?.registerUndo(withTarget: UndoBridge.shared) { _ in
            MainActor.assumeIsolated {
                draft = oldDraft
                preparedPhotos = oldPhotos
            }
        }
        undoManager?.setActionName("Editoränderung")
    }

    private func nameSort<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool where T: NamedInventoryItem {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

struct CaptureLayout: Equatable {
    static let minimumPreviewWidth: CGFloat = 280
    static let maximumPreviewWidth: CGFloat = 360
    static let previewFraction = 0.32
    static let dividerWidth: CGFloat = 1

    var availableWidth: CGFloat

    var previewWidth: CGFloat {
        min(
            Self.maximumPreviewWidth,
            max(Self.minimumPreviewWidth, availableWidth * Self.previewFraction)
        )
    }

    var formWidth: CGFloat {
        max(0, availableWidth - previewWidth - Self.dividerWidth)
    }
}

private protocol NamedInventoryItem {
    var name: String { get }
}

extension Board: NamedInventoryItem {}
extension KeycapSet: NamedInventoryItem {}
extension SwitchSet: NamedInventoryItem {}

@MainActor
private final class UndoBridge: NSObject {
    static let shared = UndoBridge()
}

private struct PhotoEditorTile: View {
    var image: NSImage?
    var isMain: Bool
    var setMain: () -> Void
    var remove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, height: 82)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isMain {
                    Image(systemName: "star.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .padding(5)
                }
            }

            HStack(spacing: 8) {
                Button(isMain ? "Hauptfoto" : "Als Hauptfoto", action: setMain)
                    .font(.caption)
                    .buttonStyle(.plain)
                    .disabled(isMain)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LibraryTextField: View {
    var title: String
    @Binding var text: String
    var values: [String]

    var body: some View {
        HStack {
            TextField(title, text: $text)
            if !values.isEmpty {
                Menu {
                    ForEach(values, id: \.self) { value in
                        Button(value) {
                            text = value
                        }
                    }
                } label: {
                    Label("\(title)-Bibliothek", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Vorhandenen Wert auswählen; freie Eingabe bleibt möglich.")
            }
        }
    }
}

/// Turns dropped items into local image files: Finder files are used where
/// they are, image data from Photos or a browser is first copied into a
/// private temporary folder that `removeTemporaryFiles()` deletes again.
@MainActor
final class DroppedPhotoLoader {
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    struct Result: Sendable {
        var urls: [URL]
        var skippedCount: Int
    }

    let temporaryDirectory: URL

    init(fileManager: FileManager = .default) {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("KeyboardManagerDrop-\(UUID().uuidString)", isDirectory: true)
    }

    func load(_ providers: [NSItemProvider]) async -> Result {
        var urls: [URL] = []
        var skipped = 0
        for provider in providers {
            if let url = await localImageURL(from: provider) {
                urls.append(url)
            } else {
                skipped += 1
            }
        }
        return Result(urls: urls, skippedCount: skipped)
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func localImageURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await fileURL(from: provider) {
            return Self.isImageFile(url) ? url : nil
        }
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            return nil
        }
        return await copiedImageFile(from: provider, typeIdentifier: typeIdentifier)
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// The system deletes the provided file when the callback returns, so it
    /// is copied while still inside the callback.
    private func copiedImageFile(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        let directory = temporaryDirectory
        let fallbackName = provider.suggestedName ?? L10n.text("Abgelegtes Foto")
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let ext = url.pathExtension.isEmpty
                        ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "img")
                        : url.pathExtension
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let name = (baseName.isEmpty ? fallbackName : baseName) + "." + ext
                    let target = directory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .appendingPathComponent(name)
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
