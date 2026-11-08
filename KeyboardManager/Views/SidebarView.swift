import SwiftUI

struct SidebarView: View {
    @Bindable var store: InventoryStore
    @AppStorage("keyboardManager.sidebar.dataSectionExpanded")
    private var isDataSectionExpanded = false

    var body: some View {
        List(selection: routeSelection) {
            Section("Sammlung") {
                ForEach(AppRoute.primary) { route in
                    Label(route.title, systemImage: route.systemImage)
                        .tag(route)
                        .accessibilityIdentifier("sidebar.\(route.rawValue)")
                }
                Label(AppRoute.statistics.title, systemImage: AppRoute.statistics.systemImage)
                    .tag(AppRoute.statistics)
                    .accessibilityIdentifier("sidebar.\(AppRoute.statistics.rawValue)")
            }

            Section(isExpanded: $isDataSectionExpanded) {
                Label(AppRoute.migration.title, systemImage: AppRoute.migration.systemImage)
                    .tag(AppRoute.migration)
                    .accessibilityIdentifier("sidebar.\(AppRoute.migration.rawValue)")
            } header: {
                Text("Daten")
                    .accessibilityRepresentation {
                        Button("Daten") {
                            isDataSectionExpanded.toggle()
                        }
                        .accessibilityIdentifier("sidebar.data")
                    }
            }

            Section("Bestand") {
                SidebarCountRow(title: "Boards", count: store.snapshot.counts.boards)
                SidebarCountRow(title: "Keycap-Sets", count: store.snapshot.counts.keycapSets)
                SidebarCountRow(title: "Artisans", count: store.snapshot.counts.artisanSets)
                SidebarCountRow(title: "Switches", count: store.snapshot.counts.switchSets)
                SidebarCountRow(title: "Fotos", count: store.snapshot.counts.photos)
            }
        }
        .listStyle(.sidebar)
        .id(store.navigationRevision)
        .navigationTitle("Keyboard Manager")
        .onAppear {
            if store.route == .migration {
                isDataSectionExpanded = true
            }
        }
        .onChange(of: store.route) { _, route in
            if route == .migration {
                isDataSectionExpanded = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                storageStatus
                Text("Version \(appVersion)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.storageStatus")
        }
    }

    /// A clear storage and error status, most severe state first.
    @ViewBuilder
    private var storageStatus: some View {
        switch store.loadState {
        case .idle, .loading:
            Label("Bestand wird geladen …", systemImage: "hourglass")
        case .failed:
            Label("Bestand nicht geladen", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .loaded:
            if case .failed = store.editorSaveState {
                Label("Letztes Speichern fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if case .failed = store.automaticBackupState {
                Label("Automatisches Backup fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(
                    "Gespeichert · \(store.snapshot.metadata.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "checkmark.circle"
                )
                .help("SQLite · lokal")
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var routeSelection: Binding<AppRoute?> {
        Binding(
            get: { store.route },
            set: { route in
                if let route {
                    store.requestRoute(route)
                }
            }
        )
    }
}

private struct SidebarCountRow: View {
    var title: String
    var count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
