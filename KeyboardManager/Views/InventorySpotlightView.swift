import AppKit
import SwiftUI

struct InventorySpotlightView: View {
    @Bindable var store: InventoryStore
    var items: [InventoryItemSummary]

    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var selectedPhotoID: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var isClearWarningsConfirmationPresented = false
    @State private var largePhotoWindow = InventoryLargePhotoWindowController()

    init(
        store: InventoryStore,
        items: [InventoryItemSummary],
        initialID: String
    ) {
        self.store = store
        self.items = items
        _currentID = State(initialValue: initialID)
        let initialItem = items.first { $0.id == initialID }
        _selectedPhotoID = State(initialValue: initialItem?.mainPhotoID ?? initialItem?.photoIDs.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()

            if let item = currentItem {
                HStack(spacing: 0) {
                    photoArea(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    detailInspector(for: item)
                        .frame(width: 310)
                }
            } else {
                ContentUnavailableView(
                    "Eintrag nicht mehr verfügbar",
                    systemImage: "questionmark.folder"
                )
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background {
            SpotlightWindowReference { window in
                largePhotoWindow.parentWindow = window
            }
            .frame(width: 0, height: 0)
        }
        .onExitCommand {
            dismiss()
        }
        .confirmationDialog(
            "Eintrag wirklich löschen?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                guard let item = currentItem else { return }
                Task {
                    if await store.deleteItem(kind: item.kind, id: item.id) {
                        dismiss()
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Eintrag, seine Fotos und seine Beziehungen werden konsistent entfernt.")
        }
        .confirmationDialog(
            "Importhinweise entfernen?",
            isPresented: $isClearWarningsConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Entfernen") {
                guard let item = currentItem else { return }
                Task {
                    _ = await store.clearImportWarnings(switchSetID: item.id)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Hinweise verschwinden aus der Anzeige. Ihr Wortlaut wird mit Datum in den Notizen des Eintrags festgehalten.")
        }
        .onDisappear {
            largePhotoWindow.close()
        }
    }

    @ViewBuilder
    private func importWarningsSection(for item: InventoryItemSummary) -> some View {
        let warnings = item.kind == .switchSet
            ? store.importWarnings(forSwitchSetID: item.id)
            : []
        if !warnings.isEmpty {
            Divider()
            Text("Migrationshinweise")
                .font(.headline)
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .textSelection(.enabled)
            }
            Button("Hinweise entfernen …") {
                isClearWarningsConfirmationPresented = true
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                showPreviousItemOrPhoto()
            } label: {
                Label("Vorheriger Eintrag", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(items.count < 2)

            Button {
                showNextItemOrPhoto()
            } label: {
                Label("Nächster Eintrag", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(items.count < 2)

            Text(positionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if let item = currentItem {
                Button("Groß ansehen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showLargePhoto(for: item)
                }
                .disabled(selectedPhoto(for: item) == nil)

                Button("Bearbeiten", systemImage: "pencil") {
                    dismiss()
                    store.editItem(kind: item.kind, id: item.id)
                }

                Button("Löschen", systemImage: "trash", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            }

            Button("Schließen", systemImage: "xmark") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .background(.bar)
    }

    private func photoArea(for item: InventoryItemSummary) -> some View {
        VStack(spacing: 14) {
            Group {
                if selectedPhoto(for: item) == nil, item.externalImageCount > 0 {
                    ContentUnavailableView {
                        Label("Externes Importbild", systemImage: "icloud.and.arrow.down")
                    } description: {
                        Text(
                            "\(item.externalImageCount) externe \(item.externalImageCount == 1 ? "Bildadresse" : "Bildadressen") "
                            + "werden aus Datenschutzgründen nicht automatisch geladen."
                        )
                    } actions: {
                        Button("Zum lokalen Übernehmen bearbeiten") {
                            dismiss()
                            store.editItem(kind: item.kind, id: item.id)
                        }
                    }
                } else {
                    Button {
                        showLargePhoto(for: item)
                    } label: {
                        ManagedPhotoView(
                            store: store,
                            record: selectedPhoto(for: item),
                            purpose: .full
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPhoto(for: item) == nil)
                    .accessibilityLabel("Foto in Großansicht öffnen")
                    .help("Foto groß ansehen")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.9))
            .clipShape(.rect(cornerRadius: 12))

            if !item.photoIDs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(item.photoIDs, id: \.self) { photoID in
                            Button {
                                selectedPhotoID = photoID
                            } label: {
                                ManagedPhotoView(
                                    store: store,
                                    record: store.photoRecord(id: photoID),
                                    purpose: .thumbnail
                                )
                                .frame(width: 86, height: 64)
                                .clipShape(.rect(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(
                                            photoID == selectedPhotoID ? Color.accentColor : .clear,
                                            lineWidth: 3
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Foto \(photoID == item.mainPhotoID ? "– Hauptfoto" : "")")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .frame(height: 68)
            }
        }
        .padding(18)
    }

    private func detailInspector(for item: InventoryItemSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(item.kind.singularName, systemImage: item.kind.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(item.name)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                if !item.secondaryDetail.isEmpty {
                    Text(item.secondaryDetail)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(visibleMetadata(for: item), id: \.self) { field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .textSelection(.enabled)
                        }
                    }
                    GridRow {
                        Text("Lokale Fotos")
                            .foregroundStyle(.secondary)
                        Text(item.photoCount, format: .number)
                            .monospacedDigit()
                    }
                    if item.externalImageCount > 0 {
                        GridRow {
                            Text("Externe Importbilder")
                                .foregroundStyle(.secondary)
                            Text(item.externalImageCount, format: .number)
                                .monospacedDigit()
                        }
                    }
                }

                if !item.notes.isEmpty {
                    Divider()
                    Text("Notizen")
                        .font(.headline)
                    Text(item.notes)
                        .textSelection(.enabled)
                }

                importWarningsSection(for: item)

                if let url = validatedHTTPSURL(item.sourceURL) {
                    Divider()
                    Button("Quelle im Browser öffnen", systemImage: "safari") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var currentItem: InventoryItemSummary? {
        items.first { $0.id == currentID }
    }

    private var currentIndex: Int? {
        items.firstIndex { $0.id == currentID }
    }

    private var positionText: String {
        guard let currentIndex else {
            return L10n.text("0 von %lld", arguments: items.count)
        }
        return L10n.text(
            "%lld von %lld",
            arguments: currentIndex + 1,
            items.count
        )
    }

    private func selectedPhoto(for item: InventoryItemSummary) -> PhotoRecord? {
        let id = selectedPhotoID ?? item.mainPhotoID ?? item.photoIDs.first
        return store.photoRecord(id: id)
    }

    private func visibleMetadata(for item: InventoryItemSummary) -> [InventoryMetadataValue] {
        item.metadata.filter { !$0.value.isEmpty }
    }

    private func showPrevious() {
        guard let currentIndex, !items.isEmpty else { return }
        select(items[(currentIndex - 1 + items.count) % items.count])
    }

    private func showPreviousItemOrPhoto() {
        guard !largePhotoWindow.stepPhotoIfPresented(by: -1) else { return }
        showPrevious()
    }

    private func showNext() {
        guard let currentIndex, !items.isEmpty else { return }
        select(items[(currentIndex + 1) % items.count])
    }

    private func showNextItemOrPhoto() {
        guard !largePhotoWindow.stepPhotoIfPresented(by: 1) else { return }
        showNext()
    }

    private func select(_ item: InventoryItemSummary) {
        currentID = item.id
        selectedPhotoID = item.mainPhotoID ?? item.photoIDs.first
    }

    private func showLargePhoto(for item: InventoryItemSummary) {
        let selection = $selectedPhotoID
        largePhotoWindow.present(
            store: store,
            item: item,
            selectedPhotoID: selection.wrappedValue,
            onPhotoSelection: { selection.wrappedValue = $0 }
        )
    }

    private func validatedHTTPSURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else {
            return nil
        }
        return components.url
    }
}

enum ManagedPhotoPurpose: Hashable {
    case thumbnail
    case full
}

struct ManagedPhotoView: View {
    @Bindable var store: InventoryStore
    var record: PhotoRecord?
    var purpose: ManagedPhotoPurpose
    var showsCompactPlaceholder = false

    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if showsCompactPlaceholder {
                VStack(spacing: 2) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 15, weight: .regular))
                    Text("Kein Foto")
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kein Foto")
            } else {
                ContentUnavailableView {
                    Label("Kein Foto", systemImage: "photo")
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskID) {
            await loadImage()
        }
    }

    private var taskID: String {
        "\(record?.id ?? "none")::\(purpose)"
    }

    @MainActor
    private func loadImage() async {
        image = nil
        guard let record else {
            isLoading = false
            return
        }
        isLoading = true
        let data: Data?
        switch purpose {
        case .thumbnail:
            data = await store.thumbnailData(for: record)
        case .full:
            data = await store.photoData(for: record)
        }
        image = data.flatMap(NSImage.init(data:))
        isLoading = false
    }
}
