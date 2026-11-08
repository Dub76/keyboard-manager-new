import AppKit
import SwiftUI

struct OverviewView: View {
    @Bindable var store: InventoryStore
    @State private var spotlightItemID: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var isReportExportPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                statusBanner
                countCards

                Picker("Inventartyp", selection: $store.selectedKind) {
                    ForEach(InventoryItemKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.selectedKind) {
                    store.selectedItemID = currentSelection
                    normalizeSort()
                }

                InventoryFilterBar(
                    kind: store.selectedKind,
                    items: items,
                    filters: filtersBinding,
                    sort: sortBinding,
                    resultCount: filteredItems.count
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if filteredItems.isEmpty {
                emptyState
            } else {
                inventoryTable
            }

            actionBar
        }
        .searchable(
            text: Binding(
                get: { currentFilters.searchText },
                set: {
                    store.overviewFiltersByKind[
                        store.selectedKind,
                        default: InventoryFilters()
                    ].searchText = $0
                }
            ),
            placement: .toolbar,
            prompt: "Bestand durchsuchen"
        )
        .onAppear {
            if let id = store.selectedItemID,
               items.contains(where: { $0.id == id }) {
                store.updateOverviewSelection(id, for: store.selectedKind)
            }
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
        .confirmationDialog(
            "Eintrag wirklich löschen?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                guard let selection = currentSelection else { return }
                Task {
                    let deleted = await store.deleteItem(kind: store.selectedKind, id: selection)
                    if deleted {
                        store.updateOverviewSelection(nil, for: store.selectedKind)
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Eintrag, seine verwalteten Fotos und seine Beziehungen werden konsistent entfernt.")
        }
        .sheet(isPresented: $isReportExportPresented) {
            InventoryReportExportView(currentKind: store.selectedKind) { options in
                guard let destinationURL = InventoryReportSavePanel.chooseDestination(for: options.format) else {
                    return
                }
                let context = InventoryReportContext(
                    currentKind: store.selectedKind,
                    filtersByKind: store.overviewFiltersByKind,
                    sortsByKind: store.overviewSortsByKind
                )
                Task {
                    await store.exportReport(context: context, options: options, to: destinationURL)
                }
            }
        }
    }

    @ViewBuilder
    private var inventoryTable: some View {
        switch store.selectedKind {
        case .board:
            configuredTable(
                Table(filteredItems, selection: selectionBinding) {
                    photoColumn
                    TableColumn("Keyboard") { row in
                        nameCell(row, detail: row.secondaryDetail)
                    }
                    .width(min: 130, ideal: 180)
                    TableColumn("Hersteller", value: \.manufacturer)
                        .width(min: 90, ideal: 130)
                    Group {
                        TableColumn("Format", value: \InventoryItemSummary.format)
                            .width(min: 65, ideal: 80)
                        TableColumn("Farbe", value: \InventoryItemSummary.color)
                            .width(min: 60, ideal: 90)
                        TableColumn("Gewicht-Material", value: \InventoryItemSummary.weightMaterial)
                            .width(min: 110, ideal: 120)
                        TableColumn("Status", value: \InventoryItemSummary.status)
                            .width(min: 70, ideal: 85)
                        TableColumn("Preis", value: \InventoryItemSummary.priceText)
                            .width(min: 60, ideal: 80)
                    }
                    TableColumn("Switches") { row in
                        summaryCell(row.switchesSummary)
                    }
                    .width(min: 150, ideal: 230)
                    TableColumn("Keycaps") { row in
                        summaryCell(row.keycapsSummary)
                    }
                    .width(min: 130, ideal: 190)
                    photoCountColumn
                }
            )
        case .keycapSet:
            configuredTable(
                Table(filteredItems, selection: selectionBinding) {
                    photoColumn
                    TableColumn("Set") { row in
                        nameCell(row, detail: row.secondaryDetail)
                    }
                    .width(min: 130, ideal: 190)
                    TableColumn("Hersteller", value: \.manufacturer)
                        .width(min: 90, ideal: 140)
                    TableColumn("Profil", value: \.profile)
                        .width(min: 70, ideal: 100)
                    TableColumn("Kits") { row in
                        summaryCell(row.contentsSummary)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn("Board") { row in
                        summaryCell(row.mountedBoardSummary)
                    }
                    .width(min: 120, ideal: 180)
                    photoCountColumn
                }
            )
        case .artisanSet:
            configuredTable(
                Table(filteredItems, selection: selectionBinding) {
                    photoColumn
                    TableColumn("Artisan") { row in
                        nameCell(row, detail: row.secondaryDetail)
                    }
                    .width(min: 130, ideal: 190)
                    TableColumn("Hersteller", value: \.manufacturer)
                        .width(min: 90, ideal: 140)
                    TableColumn("Profil", value: \.profile)
                        .width(min: 70, ideal: 100)
                    TableColumn("Tags") { row in
                        summaryCell(row.contentsSummary)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn("Board") { row in
                        summaryCell(row.mountedBoardSummary)
                    }
                    .width(min: 120, ideal: 180)
                    photoCountColumn
                }
            )
        case .switchSet:
            configuredTable(
                Table(filteredItems, selection: selectionBinding) {
                    photoColumn
                    TableColumn("Name / Bezeichnung") { row in
                        nameCell(row, detail: row.secondaryDetail)
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Switch Type", value: \.switchType)
                        .width(min: 90, ideal: 120)
                    TableColumn(Text(stockColumnTitle)) { row in
                        Text(row.stockSummary)
                            .monospacedDigit()
                    }
                    .width(min: 170, ideal: 210)
                    TableColumn("Board") { row in
                        summaryCell(row.mountedBoardSummary)
                    }
                    .width(min: 160, ideal: 250)
                    TableColumn("Operating Force", value: \.operatingForce)
                        .width(min: 95, ideal: 130)
                    photoCountColumn
                }
            )
        }
    }

    private var photoColumn: TableColumn<InventoryItemSummary, Never, some View, Text> {
        TableColumn("Foto") { row in
            Button {
                store.updateOverviewSelection(row.id, for: store.selectedKind)
                spotlightItemID = row.id
            } label: {
                ManagedPhotoView(
                    store: store,
                    record: store.photoRecord(id: row.mainPhotoID ?? row.photoIDs.first),
                    purpose: .thumbnail,
                    showsCompactPlaceholder: true
                )
                .frame(width: 68, height: 46)
                .background(.quaternary.opacity(0.35))
                .clipShape(.rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.text("Details zu %@ öffnen", arguments: row.name)
            )
        }
        .width(78)
    }

    private var photoCountColumn: TableColumn<InventoryItemSummary, Never, some View, Text> {
        TableColumn("Fotos") { row in
            Text(row.photoCount, format: .number)
                .monospacedDigit()
        }
        .width(60)
    }

    private func configuredTable<Content: View>(_ table: Content) -> some View {
        table
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let id = selectedIDs.first {
                Button("Details", systemImage: "eye") {
                    store.updateOverviewSelection(id, for: store.selectedKind)
                    spotlightItemID = id
                }
                Button("Bearbeiten", systemImage: "pencil") {
                    store.editItem(kind: store.selectedKind, id: id)
                }
                Button("Name kopieren", systemImage: "doc.on.doc") {
                    if let item = filteredItems.first(where: { $0.id == id }) {
                        copyToPasteboard(item.name)
                    }
                }
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    store.updateOverviewSelection(id, for: store.selectedKind)
                    isDeleteConfirmationPresented = true
                }
            }
        } primaryAction: { selectedIDs in
            if let id = selectedIDs.first {
                store.updateOverviewSelection(id, for: store.selectedKind)
                spotlightItemID = id
            }
        }
        .background {
            OverviewTableFocusBridge(
                restoreRequest: activeRestoreRequest,
                selectedRow: restoredRowIndex,
                rowCount: filteredItems.count
            ) { offset in
                store.updateOverviewScrollOffset(offset, for: store.selectedKind)
            } onRestoreApplied: { revision in
                store.consumeOverviewRestoreRequest(revision: revision)
            }
        }
        .accessibilityIdentifier("overview.table")
    }

    private func nameCell(_ row: InventoryItemSummary, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name)
                .fontWeight(.semibold)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(row.name)
    }

    @ViewBuilder
    private func summaryCell(_ value: String) -> some View {
        if value.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            Text(value)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(value)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var stockColumnTitle: String {
        [
            L10n.text("Bestand"),
            L10n.text("Verbaut"),
            L10n.text("Verfügbar")
        ]
        .joined(separator: " / ")
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch store.editorSaveState {
        case let .saved(message):
            PhaseBanner(title: "Gespeichert", message: message)
        case let .failed(message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
        case .idle, .saving:
            EmptyView()
        }
    }

    private var countCards: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            CountCard(title: "Keyboards", value: store.snapshot.counts.boards, systemImage: "keyboard")
            CountCard(title: "Keycap-Sets", value: store.snapshot.counts.keycapSets, systemImage: "square.grid.3x3.fill")
            CountCard(title: "Artisans", value: store.snapshot.counts.artisanSets, systemImage: "sparkles")
            CountCard(title: "Switches", value: store.snapshot.counts.switchSets, systemImage: "switch.2")
            CountCard(title: "Fotos", value: store.snapshot.counts.photos, systemImage: "photo.on.rectangle.angled")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bestandsübersicht")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                currentFilters.isEmpty(for: store.selectedKind)
                    ? "Noch keine \(store.selectedKind.displayName)"
                    : "Keine Treffer",
                systemImage: store.selectedKind.systemImage
            )
        } description: {
            if currentFilters.isEmpty(for: store.selectedKind) {
                Text("Erfasse einen neuen Eintrag oder importiere den V1-Bestand.")
            } else {
                Text("Passe Suche oder Filter an.")
            }
        } actions: {
            if currentFilters.isEmpty(for: store.selectedKind) {
                Button("\(store.selectedKind.singularName) erfassen") {
                    store.prepareNewItem(store.selectedKind)
                }
            } else {
                Button("Filter zurücksetzen") {
                    store.overviewFiltersByKind[store.selectedKind] = InventoryFilters()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack {
            Button {
                store.prepareNewItem(store.selectedKind)
            } label: {
                Label("Neu", systemImage: "plus")
            }

            Button {
                guard let selection = currentSelection else { return }
                spotlightItemID = selection
            } label: {
                Label("Details", systemImage: "eye")
            }
            .disabled(currentSelection == nil)

            Button {
                guard let selection = currentSelection else { return }
                store.editItem(kind: store.selectedKind, id: selection)
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            .disabled(currentSelection == nil)

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            .disabled(currentSelection == nil)

            Spacer()

            Button {
                isReportExportPresented = true
            } label: {
                Label("Bestand exportieren …", systemImage: "square.and.arrow.up")
            }
            .disabled(isReportExporting || store.loadState != .loaded)
        }
        .padding(10)
        .background(.bar)
    }

    private var items: [InventoryItemSummary] {
        InventoryQuery.items(in: store.snapshot, kind: store.selectedKind)
    }

    private var filteredItems: [InventoryItemSummary] {
        InventoryQuery.results(
            in: store.snapshot,
            kind: store.selectedKind,
            filters: currentFilters,
            sort: currentSort
        )
    }

    private func normalizeSort() {
        if !InventorySort.available(for: store.selectedKind).contains(currentSort) {
            store.overviewSortsByKind[store.selectedKind] = .name
        }
    }

    private var currentFilters: InventoryFilters {
        store.overviewFiltersByKind[store.selectedKind, default: InventoryFilters()]
    }

    private var currentSort: InventorySort {
        store.overviewSortsByKind[store.selectedKind, default: .name]
    }

    private var filtersBinding: Binding<InventoryFilters> {
        Binding(
            get: { currentFilters },
            set: { store.overviewFiltersByKind[store.selectedKind] = $0 }
        )
    }

    private var sortBinding: Binding<InventorySort> {
        Binding(
            get: { currentSort },
            set: { store.overviewSortsByKind[store.selectedKind] = $0 }
        )
    }

    private var currentSelection: String? {
        store.overviewSelectionByKind[store.selectedKind]
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { currentSelection },
            set: { store.updateOverviewSelection($0, for: store.selectedKind) }
        )
    }

    private var activeRestoreRequest: OverviewRestoreRequest? {
        guard store.overviewRestoreRequest?.kind == store.selectedKind else {
            return nil
        }
        return store.overviewRestoreRequest
    }

    private var restoredRowIndex: Int? {
        guard let itemID = activeRestoreRequest?.itemID else { return nil }
        return filteredItems.firstIndex { $0.id == itemID }
    }

    private var isReportExporting: Bool {
        if case .exporting = store.reportExportState {
            return true
        }
        return false
    }
}

@MainActor
struct OverviewTableFocusBridge: NSViewRepresentable {
    var restoreRequest: OverviewRestoreRequest?
    var selectedRow: Int?
    var rowCount: Int
    var onScrollOffsetChange: (Double) -> Void
    var onRestoreApplied: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScrollOffsetChange: onScrollOffsetChange,
            onRestoreApplied: onRestoreApplied
        )
    }

    func makeNSView(context: Context) -> TableLocatorView {
        let view = TableLocatorView()
        view.onResolve = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.resolveTable(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: TableLocatorView, context: Context) {
        context.coordinator.update(
            restoreRequest: restoreRequest,
            selectedRow: selectedRow,
            rowCount: rowCount,
            onScrollOffsetChange: onScrollOffsetChange,
            onRestoreApplied: onRestoreApplied
        )
        context.coordinator.resolveTable(from: nsView)
    }

    static func dismantleNSView(_ nsView: TableLocatorView, coordinator: Coordinator) {
        nsView.onResolve = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var restoreRequest: OverviewRestoreRequest?
        private var selectedRow: Int?
        private var rowCount = 0
        private var onScrollOffsetChange: (Double) -> Void
        private var onRestoreApplied: (Int) -> Void
        private weak var tableView: NSTableView?
        private weak var clipView: NSClipView?
        private var lastAppliedRevision = 0
        private var isApplyingRestore = false

        init(
            onScrollOffsetChange: @escaping (Double) -> Void,
            onRestoreApplied: @escaping (Int) -> Void
        ) {
            self.onScrollOffsetChange = onScrollOffsetChange
            self.onRestoreApplied = onRestoreApplied
        }

        func update(
            restoreRequest: OverviewRestoreRequest?,
            selectedRow: Int?,
            rowCount: Int,
            onScrollOffsetChange: @escaping (Double) -> Void,
            onRestoreApplied: @escaping (Int) -> Void
        ) {
            self.restoreRequest = restoreRequest
            self.selectedRow = selectedRow
            self.rowCount = rowCount
            self.onScrollOffsetChange = onScrollOffsetChange
            self.onRestoreApplied = onRestoreApplied
            applyRestoreIfNeeded()
        }

        func resolveTable(from anchor: NSView) {
            guard let contentView = anchor.window?.contentView,
                  let table = findInventoryTable(in: contentView) else {
                return
            }
            if tableView !== table {
                detach()
                tableView = table
                let clipView = table.enclosingScrollView?.contentView
                self.clipView = clipView
                clipView?.postsBoundsChangedNotifications = true
                if let clipView {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(scrollBoundsDidChange(_:)),
                        name: NSView.boundsDidChangeNotification,
                        object: clipView
                    )
                }
            }
            applyRestoreIfNeeded()
        }

        func detach() {
            if let clipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
            }
            tableView = nil
            clipView = nil
        }

        @objc
        private func scrollBoundsDidChange(_ notification: Notification) {
            guard !isApplyingRestore,
                  let clipView = notification.object as? NSClipView else {
                return
            }
            onScrollOffsetChange(Double(clipView.bounds.origin.y))
        }

        private func applyRestoreIfNeeded() {
            guard let request = restoreRequest,
                  request.revision != lastAppliedRevision,
                  let tableView,
                  let clipView,
                  tableView.numberOfRows == rowCount else {
                return
            }

            isApplyingRestore = true
            defer { isApplyingRestore = false }
            if let offset = request.scrollOffset {
                let maximumOffset = max(
                    0,
                    tableView.bounds.height - clipView.bounds.height
                )
                clipView.scroll(
                    to: NSPoint(
                        x: clipView.bounds.origin.x,
                        y: min(maximumOffset, max(0, offset))
                    )
                )
                tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
            } else if let selectedRow,
                      selectedRow >= 0,
                      selectedRow < tableView.numberOfRows {
                tableView.scrollRowToVisible(selectedRow)
            }

            tableView.window?.makeFirstResponder(tableView)
            lastAppliedRevision = request.revision
            Task { @MainActor [onRestoreApplied] in
                await Task.yield()
                onRestoreApplied(request.revision)
            }
        }

        private func findInventoryTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfColumns >= 5 {
                return table
            }
            for subview in view.subviews {
                if let table = findInventoryTable(in: subview) {
                    return table
                }
            }
            return nil
        }
    }
}

@MainActor
final class TableLocatorView: NSView {
    var onResolve: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?()
    }

    override func layout() {
        super.layout()
        onResolve?()
    }
}

private struct CountCard: View {
    var title: String
    var value: Int
    var systemImage: String

    var body: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Spacer()
                Text(value, format: .number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
        }
    }
}
