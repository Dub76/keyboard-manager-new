import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: InventoryStore
    @Bindable var updateController: AppUpdateController
    @Binding var preferredLanguage: String
    @AppStorage("followSystemAppearance") private var followSystemAppearance = true
    @AppStorage(InventoryStore.automaticBackupsPreferenceKey) private var automaticBackupsEnabled = true
    @State private var backupPendingRestore: AutomaticBackupEntry?

    var body: some View {
        Form {
            Picker("Sprache", selection: $preferredLanguage) {
                Text("Deutsch").tag("de")
                Text("English").tag("en")
            }

            Toggle("Systemdarstellung verwenden", isOn: $followSystemAppearance)
            Text(
                followSystemAppearance
                    ? "Die App folgt Hell- oder Dunkelmodus von macOS."
                    : "Die App verwendet den hellen Modus."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            LabeledContent("Datenhaltung", value: "SQLite · lokal")
            LabeledContent("Migrationsmodus", value: "Nur lesende V1-Quelle")

            if store.automaticBackupsDirectoryURL != nil {
                automaticBackupSection
            }

            Section("Updates") {
                LabeledContent("Installierte Version", value: updateController.installedVersion)
                updateStatus
                Button("Nach Updates suchen") {
                    Task {
                        await updateController.checkForUpdates()
                    }
                }
                .disabled(updateController.isWorking)
            }

            if let message = store.languagePersistenceError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .confirmationDialog(
            "Dieses Backup wiederherstellen?",
            isPresented: restoreConfirmationPresented,
            titleVisibility: .visible,
            presenting: backupPendingRestore
        ) { entry in
            Button("Wiederherstellen", role: .destructive) {
                Task {
                    await store.restoreAutomaticBackup(entry)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { entry in
            Text("Die Sammlung wird auf den Stand vom \(backupDateText(entry.createdAt)) zurückgesetzt. Der aktuelle Stand wird vorher in den Ordner „Backups“ verschoben.")
        }
        .task {
            await store.refreshAutomaticBackupStatus()
        }
        .navigationTitle("Allgemein")
    }

    private var automaticBackupSection: some View {
        Section("Automatische Backups") {
            Toggle("Täglich automatisch sichern", isOn: $automaticBackupsEnabled)
            LabeledContent("Letztes Backup", value: latestBackupText)
            automaticBackupStatus
            HStack {
                Button("Jetzt sichern") {
                    Task {
                        await store.backUpNow()
                    }
                }
                .disabled(store.automaticBackupState == .running || !store.canWriteInventory)

                Button("Im Finder zeigen") {
                    showBackupsInFinder()
                }
            }
            Text("Höchstens ein Backup pro Tag und nur, wenn sich etwas geändert hat. Die letzten 7 bleiben erhalten.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            backupMirrorRows
            backupRestoreRows
        }
    }

    @ViewBuilder
    private var backupMirrorRows: some View {
        LabeledContent("Zweiter Speicherort") {
            Text(store.backupMirrorURL?.lastPathComponent ?? L10n.text("Keiner"))
                .lineLimit(1)
                .help(store.backupMirrorURL?.path ?? "")
        }
        HStack {
            Button("Ordner wählen …") {
                chooseBackupMirror()
            }
            if store.backupMirrorURL != nil {
                Button("Entfernen") {
                    Task {
                        await store.setBackupMirror(nil)
                    }
                }
            }
        }
        if let message = store.backupMirrorError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        Text("Kopiert jedes automatische Backup zusätzlich dorthin, zum Beispiel nach iCloud Drive oder auf eine externe Festplatte.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var backupRestoreRows: some View {
        ForEach(store.automaticBackupEntries, id: \.url) { entry in
            LabeledContent(backupDateText(entry.createdAt)) {
                Button("Wiederherstellen …") {
                    store.clearBackupRestoreStatus()
                    backupPendingRestore = entry
                }
                .disabled(store.backupRestoreState == .restoring)
            }
        }
        switch store.backupRestoreState {
        case .idle:
            EmptyView()
        case .restoring:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Backup wird geprüft und wiederhergestellt …")
            }
        case let .succeeded(date):
            Label("Stand vom \(backupDateText(date)) wiederhergestellt.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label("Wiederherstellen fehlgeschlagen: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var restoreConfirmationPresented: Binding<Bool> {
        Binding(
            get: { backupPendingRestore != nil },
            set: { if !$0 { backupPendingRestore = nil } }
        )
    }

    private func backupDateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseBackupMirror() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store.setBackupMirror(url)
        }
    }

    private var latestBackupText: String {
        guard let latest = store.latestAutomaticBackup else {
            return L10n.text("Noch keines")
        }
        return latest.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var automaticBackupStatus: some View {
        switch store.automaticBackupState {
        case .idle:
            EmptyView()
        case .running:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Backup wird erstellt und kontrolliert …")
            }
        case .created:
            Label("Backup gespeichert.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .nothingToBackUp:
            Label("Der Bestand ist leer, es gibt nichts zu sichern.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label("Automatisches Backup fehlgeschlagen: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func showBackupsInFinder() {
        guard let url = store.automaticBackupsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateController.state {
        case .idle:
            VStack(alignment: .leading, spacing: 2) {
                Text("Beim Start wird höchstens einmal täglich nach stabilen GitHub-Releases gesucht.")
                if let lastCheckDate = updateController.lastCheckDate {
                    Text("Zuletzt geprüft: \(lastCheckDate.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .foregroundStyle(.secondary)
        case .checking:
            Label("Suche nach Updates …", systemImage: "arrow.triangle.2.circlepath")
        case .upToDate:
            Label("Die App ist aktuell.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .updateAvailable(update):
            HStack {
                Label("Version \(update.version.description) ist verfügbar.", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Laden") {
                    Task {
                        await updateController.downloadAndOpen(update)
                    }
                }
            }
        case .downloading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Installer wird geladen und geprüft …")
            }
        case let .installerOpened(update, url):
            Label(
                "Version \(update.version.description) wurde geprüft und geöffnet: \(url.lastPathComponent)",
                systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(.green)
        case let .failed(message):
            Label("Updateprüfung fehlgeschlagen: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
