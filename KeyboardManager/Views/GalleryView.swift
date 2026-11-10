import AppKit
import SwiftUI

struct GalleryView: View {
    @Bindable var store: InventoryStore
    @State private var filters = InventoryFilters()
    @State private var sort = InventorySort.name
    @State private var spotlightItemID: String?
    @State private var dropTargetID: String?

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)
    ]

    var body: some View {
        VStack(spacing: 0) {
            galleryToolbar
            Divider()

            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(filteredItems) { item in
                            GalleryCard(
                                store: store,
                                item: item,
                                mainPhoto: store.photoRecord(id: item.mainPhotoID ?? item.photoIDs.first)
                            )
                            .onTapGesture {
                                spotlightItemID = item.id
                            }
                            .dropDestination(for: DroppedImageFile.self) { files, _ in
                                addDroppedPhotos(files, to: item)
                                return true
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTargetID = item.id
                                } else if dropTargetID == item.id {
                                    dropTargetID = nil
                                }
                            }
                            .overlay {
                                if dropTargetID == item.id {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                                        .overlay {
                                            Label("Fotos hinzufügen", systemImage: "photo.badge.plus")
                                                .font(.headline)
                                                .padding(10)
                                                .background(.regularMaterial, in: .capsule)
                                        }
                                        .allowsHitTesting(false)
                                }
                            }
                            .contextMenu {
                                Button("Details", systemImage: "eye") {
                                    spotlightItemID = item.id
                                }
                                Button("Bearbeiten", systemImage: "pencil") {
                                    store.editItem(kind: item.kind, id: item.id)
                                }
                                Button("Duplizieren", systemImage: "plus.square.on.square") {
                                    Task {
                                        await store.duplicateItem(kind: item.kind, id: item.id)
                                    }
                                }
                                Button("Name kopieren", systemImage: "doc.on.doc") {
                                    copyToPasteboard(item.name)
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .searchable(text: $filters.searchText, placement: .toolbar, prompt: "Galerie durchsuchen")
        .onAppear {
            if !InventoryQuery.galleryKinds.contains(store.selectedKind) {
                store.selectedKind = .board
            }
            normalizeSort()
        }
        .onChange(of: store.selectedKind) {
            filters = InventoryFilters()
            normalizeSort()
        }
        .sheet(
            isPresented: Binding(
                get: { spotlightItemID != nil },
                set: { if !$0 { spotlightItemID = nil } }
            )
        ) {
            if let spotlightItemID {
                InventorySpotlightView(
                    store: store,
                    items: filteredItems,
                    initialID: spotlightItemID
                )
            }
        }
    }

    private func addDroppedPhotos(_ files: [DroppedImageFile], to item: InventoryItemSummary) {
        let urls = DroppedImageFile.usableURLs(files)
        Task {
            if !urls.isEmpty {
                await store.addPhotos(urls: urls, toItem: item.kind, id: item.id)
            }
            DroppedImageFile.removeTemporaryCopies(files)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var galleryToolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Inventartyp", selection: $store.selectedKind) {
                    ForEach(InventoryQuery.galleryKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)

                Spacer()

                Label(
                    "\(filteredItems.count) Einträge",
                    systemImage: "square.grid.2x2"
                )
                .foregroundStyle(.secondary)
            }

            InventoryFilterBar(
                kind: store.selectedKind,
                items: items,
                filters: $filters,
                sort: $sort,
                resultCount: filteredItems.count
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                filters.isEmpty(for: store.selectedKind)
                    ? "Noch keine \(store.selectedKind.displayName)"
                    : "Keine Treffer",
                systemImage: "photo.stack"
            )
        } description: {
            Text(
                filters.isEmpty(for: store.selectedKind)
                    ? "Erfasse einen Eintrag mit Foto oder importiere deinen V1-Bestand."
                    : "Passe Suche oder Filter an."
            )
        } actions: {
            if filters.isEmpty(for: store.selectedKind) {
                Button("\(store.selectedKind.singularName) erfassen") {
                    store.prepareNewItem(store.selectedKind)
                }
            } else {
                Button("Filter zurücksetzen") {
                    filters = InventoryFilters()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var items: [InventoryItemSummary] {
        InventoryQuery.items(in: store.snapshot, kind: store.selectedKind)
    }

    private var filteredItems: [InventoryItemSummary] {
        InventoryQuery.results(
            in: store.snapshot,
            kind: store.selectedKind,
            filters: filters,
            sort: sort
        )
    }

    private func normalizeSort() {
        if !InventorySort.available(for: store.selectedKind).contains(sort) {
            sort = .name
        }
    }
}

private struct GalleryCard: View {
    @Bindable var store: InventoryStore
    var item: InventoryItemSummary
    var mainPhoto: PhotoRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagedPhotoView(store: store, record: mainPhoto, purpose: .thumbnail)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.35))
                .clipped()

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Label("\(item.photoCount)", systemImage: "photo")
                        if item.externalImageCount > 0 {
                            Label("\(item.externalImageCount)", systemImage: "icloud.and.arrow.down")
                                .help("Externe Importbilder – werden nicht automatisch geladen")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !item.manufacturer.isEmpty {
                    Text(item.manufacturer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if !item.primaryDetail.isEmpty {
                        Text(item.primaryDetail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.12), in: .capsule)
                    }
                    if !item.secondaryDetail.isEmpty {
                        Text(item.secondaryDetail)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .padding(14)
        }
        .background(.background, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Öffnet die Großansicht")
    }
}
