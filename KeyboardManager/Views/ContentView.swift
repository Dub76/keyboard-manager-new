import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: InventoryStore
    @Bindable var updateController: AppUpdateController
    @Binding var preferredLanguage: String
    let shouldAdoptStoredLanguage: Bool
    let shouldCheckForUpdates: Bool
    @State private var didInitializeLanguage = false
    @State private var isUpdateAlertPresented = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                detailView
                reportExportStatus
                backupExportStatus
            }
                .navigationTitle(store.route.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            chooseBackupDestination()
                        } label: {
                            Label("ZIP-Backup", systemImage: "externaldrive.badge.plus")
                        }
                        .help("V1-kompatibles ZIP-Backup erstellen")
                        .disabled(isBackupExporting || store.loadState != .loaded)

                        Button {
                            store.showMigration()
                        } label: {
                            Label("V1-Migration", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        }

                        Button {
                            store.prepareNewItem(.board)
                        } label: {
                            Label("Neues Board", systemImage: "plus")
                        }
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Manager Hauptfenster")
        .contextMenu {
            Button("Rückgängig", systemImage: "arrow.uturn.backward") {
                performResponderAction(Selector(("undo:")))
            }
            .disabled(!canPerformResponderAction(Selector(("undo:"))))
            Button("Wiederholen", systemImage: "arrow.uturn.forward") {
                performResponderAction(Selector(("redo:")))
            }
            .disabled(!canPerformResponderAction(Selector(("redo:"))))

            Divider()

            Button("Ausschneiden", systemImage: "scissors") {
                performResponderAction(#selector(NSText.cut(_:)))
            }
            .disabled(!canPerformResponderAction(#selector(NSText.cut(_:))))
            Button("Kopieren", systemImage: "doc.on.doc") {
                performResponderAction(#selector(NSText.copy(_:)))
            }
            .disabled(!canPerformResponderAction(#selector(NSText.copy(_:))))
            Button("Einfügen", systemImage: "doc.on.clipboard") {
                performResponderAction(#selector(NSText.paste(_:)))
            }
            .disabled(!canPerformResponderAction(#selector(NSText.paste(_:))))

            Divider()

            Button("Alles auswählen", systemImage: "textformat") {
                performResponderAction(#selector(NSText.selectAll(_:)))
            }
            .disabled(!canPerformResponderAction(#selector(NSText.selectAll(_:))))
        }
        .task {
            await store.load()
            if shouldAdoptStoredLanguage {
                preferredLanguage = AppLanguage.normalized(
                    store.snapshot.metadata.preferredLanguage
                ).rawValue
            } else {
                preferredLanguage = AppLanguage.normalized(preferredLanguage).rawValue
            }
            await store.updatePreferredLanguage(preferredLanguage)
            didInitializeLanguage = true
            if shouldCheckForUpdates {
                await updateController.checkForUpdatesIfDue()
            }
        }
        .onChange(of: preferredLanguage) { _, newValue in
            guard didInitializeLanguage else { return }
            Task {
                await store.updatePreferredLanguage(newValue)
            }
        }
        .onChange(of: store.snapshot.metadata.preferredLanguage) { _, storedValue in
            guard didInitializeLanguage,
                  AppLanguage.normalized(storedValue).rawValue
                    != AppLanguage.normalized(preferredLanguage).rawValue else {
                return
            }
            Task {
                await store.updatePreferredLanguage(preferredLanguage)
            }
        }
        .background {
            WindowCloseGuard(
                closeRevision: store.windowCloseRevision,
                shouldAllowClose: store.shouldAllowWindowClose
            )
            .frame(width: 0, height: 0)
        }
        .onChange(of: updateController.availableUpdate) { _, update in
            isUpdateAlertPresented = update != nil
        }
        .alert(
            "Update verfügbar",
            isPresented: $isUpdateAlertPresented,
            presenting: updateController.availableUpdate
        ) { update in
            Button("Jetzt laden") {
                Task {
                    await updateController.downloadAndOpen(update)
                }
            }
            Button("Später", role: .cancel) {}
        } message: { update in
            Text(
                "Version \(update.version.description) ist verfügbar. Der Installer wird vor dem Öffnen gegen die veröffentlichte SHA-256-Prüfsumme geprüft."
            )
        }
        .confirmationDialog(
            "Fenster mit ungespeicherten Änderungen schließen?",
            isPresented: $store.isWindowCloseConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Änderungen verwerfen und schließen", role: .destructive) {
                store.confirmDiscardAndCloseWindow()
            }
            Button("Weiter bearbeiten", role: .cancel) {
                store.cancelWindowClose()
            }
        } message: {
            Text("Der aktuelle Entwurf wurde noch nicht gespeichert.")
        }
    }

    @ViewBuilder
    private var reportExportStatus: some View {
        switch store.reportExportState {
        case .idle:
            EmptyView()
        case let .exporting(format):
            statusBar {
                ProgressView()
                    .controlSize(.small)
                Text("\(format.title)-Bestandsbericht wird erstellt und kontrolliert …")
            }
        case let .succeeded(result):
            statusBar {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(
                    "Bericht gespeichert: \(result.destinationURL.lastPathComponent) · "
                    + "\(result.itemCount) Einträge · "
                    + result.byteCount.formatted(.byteCount(style: .file))
                )
                Spacer()
                Button("Schließen") {
                    store.clearReportExportStatus()
                }
            }
        case let .failed(message):
            statusBar {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Bericht fehlgeschlagen: \(message)")
                    .lineLimit(2)
                Spacer()
                Button("Schließen") {
                    store.clearReportExportStatus()
                }
            }
        }
    }

    @ViewBuilder
    private var backupExportStatus: some View {
        switch store.backupExportState {
        case .idle:
            EmptyView()
        case .exporting:
            statusBar {
                ProgressView()
                    .controlSize(.small)
                Text("ZIP-Backup wird erstellt und kontrolliert …")
            }
        case let .succeeded(result):
            statusBar {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(
                    "Backup gespeichert: \(result.destinationURL.lastPathComponent) · "
                    + result.byteCount.formatted(.byteCount(style: .file))
                )
                if result.transcodedHEICPhotoCount > 0 {
                    Text("· \(result.transcodedHEICPhotoCount) HEIC als JPEG kopiert")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") {
                    store.clearBackupExportStatus()
                }
            }
        case let .failed(message):
            statusBar {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Backup fehlgeschlagen: \(message)")
                    .lineLimit(2)
                Spacer()
                Button("Schließen") {
                    store.clearBackupExportStatus()
                }
            }
        }
    }

    private func statusBar<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8, content: content)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
    }

    private var isBackupExporting: Bool {
        if case .exporting = store.backupExportState {
            return true
        }
        return false
    }

    private func chooseBackupDestination() {
        guard let destinationURL = BackupSavePanel.chooseDestination() else {
            return
        }
        Task {
            await store.exportBackup(to: destinationURL)
        }
    }

    private func performResponderAction(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    private func canPerformResponderAction(_ action: Selector) -> Bool {
        NSApp.target(forAction: action, to: nil, from: nil) != nil
    }

    @ViewBuilder
    private var detailView: some View {
        if case let .failed(message) = store.loadState, store.route != .migration {
            loadFailureView(message)
        } else {
            routeView
        }
    }

    private func loadFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Bestand konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text("Die gespeicherten Daten bleiben unverändert. Erfassen und Löschen sind gesperrt, bis der Bestand geladen ist.")
            }
        } actions: {
            Button("Erneut laden") {
                Task {
                    await store.retryLoad()
                }
            }
        }
        .accessibilityIdentifier("load-failure")
    }

    @ViewBuilder
    private var routeView: some View {
        switch store.route {
        case .overview:
            OverviewView(store: store)
        case .capture:
            CaptureView(store: store)
        case .gallery:
            GalleryView(store: store)
        case .migration:
            MigrationView(store: store)
        }
    }
}
