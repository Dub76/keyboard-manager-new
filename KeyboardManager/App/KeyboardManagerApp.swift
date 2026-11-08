import AppKit
import SwiftUI

@main
struct KeyboardManagerApp: App {
    @State private var store: InventoryStore
    @State private var updateController = AppUpdateController()
    @AppStorage(AppLanguage.preferenceKey) private var preferredLanguage = AppLanguage.german.rawValue
    @AppStorage("followSystemAppearance") private var followSystemAppearance = true
    private let shouldAdoptStoredLanguage: Bool
    /// View settings (`@AppStorage`). UI tests get a fresh, separate area so
    /// they neither depend on nor change the user's own settings.
    private let viewDefaults: UserDefaults

    init() {
        shouldAdoptStoredLanguage = UserDefaults.standard.object(
            forKey: AppLanguage.preferenceKey
        ) == nil
        let environment = ProcessInfo.processInfo.environment
        // A unit-test host must not compete with the user's running app.
        if environment["XCTestConfigurationFilePath"] == nil {
            let lockDirectory = environment["KEYBOARD_MANAGER_UI_TEST_ROOT"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? MigrationStorageLayout.default.rootURL
            let lock = InstanceLock(directoryURL: lockDirectory)
            guard lock.acquire() else {
                RunningInstance.handOver()
            }
            RunningInstance.lock = lock
        }
        if let testRoot = environment["KEYBOARD_MANAGER_UI_TEST_ROOT"], !testRoot.isEmpty {
            let suiteName = "de.r3d42.KeyboardManagerV2.uitests"
            let testDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            testDefaults.removePersistentDomain(forName: suiteName)
            viewDefaults = testDefaults
            let rootURL = URL(fileURLWithPath: testRoot, isDirectory: true)
            let databaseURL = rootURL
                .appendingPathComponent("inventory.sqlite")
            let processDetector = V1ProcessDetector(lookup: { false })
            let discoveryService = V1SourceDiscoveryService(
                applicationSupportRoots: {
                    [
                        rootURL.appendingPathComponent(
                            "V1 Application Support",
                            isDirectory: true
                        )
                    ]
                },
                processDetector: processDetector
            )
            _store = State(
                initialValue: InventoryStore(
                    repository: SQLiteInventoryRepository(databaseURL: databaseURL),
                    migrationService: V1MigrationService(
                        discoveryService: discoveryService
                    ),
                    migrationCommitService: MigrationCommitService(
                        layout: MigrationStorageLayout(
                            rootURL: rootURL.appendingPathComponent(
                                "Migration",
                                isDirectory: true
                            )
                        ),
                        v1ProcessDetector: processDetector
                    ),
                    photoService: PhotoImportService(
                        layout: MigrationStorageLayout(
                            rootURL: rootURL.appendingPathComponent(
                                "Migration",
                                isDirectory: true
                            )
                        )
                    ),
                    automaticBackupService: AutomaticBackupService(
                        directoryURL: rootURL.appendingPathComponent(
                            "AutomaticBackups",
                            isDirectory: true
                        )
                    ),
                    automaticBackupsEnabled: {
                        testDefaults.object(
                            forKey: InventoryStore.automaticBackupsPreferenceKey
                        ) as? Bool ?? true
                    },
                    backupDefaults: testDefaults
                )
            )
        } else {
            viewDefaults = .standard
            _store = State(
                initialValue: InventoryStore(
                    automaticBackupService: AutomaticBackupService()
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup("Keyboard Manager") {
            ContentView(
                store: store,
                updateController: updateController,
                preferredLanguage: $preferredLanguage,
                shouldAdoptStoredLanguage: shouldAdoptStoredLanguage,
                shouldCheckForUpdates: ProcessInfo.processInfo.environment[
                    "KEYBOARD_MANAGER_UI_TEST_ROOT"
                ] == nil
            )
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(followSystemAppearance ? nil : .light)
                .defaultAppStorage(viewDefaults)
                .environment(
                    \.locale,
                    AppLanguage.normalized(preferredLanguage).locale
                )
        }
        .defaultSize(width: 1600, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Über Keyboard Manager") {
                    AboutPanel.show()
                }
            }

            CommandMenu("Sammlung") {
                Button("Neues Board") {
                    store.prepareNewItem(.board)
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu("Neuer Eintrag") {
                    ForEach(InventoryItemKind.allCases) { kind in
                        Button(kind.singularName) {
                            store.prepareNewItem(kind)
                        }
                    }
                }

                Button("Löschen rückgängig machen") {
                    Task {
                        await store.undoLastDeletion()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store.undoableDeletion == nil)

                Divider()

                Button("V1-Migration öffnen") {
                    store.showMigration()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(
                store: store,
                updateController: updateController,
                preferredLanguage: $preferredLanguage
            )
            .preferredColorScheme(followSystemAppearance ? nil : .light)
            .defaultAppStorage(viewDefaults)
            .environment(
                \.locale,
                AppLanguage.normalized(preferredLanguage).locale
            )
        }
    }
}

/// Keeps the single-instance lock for the lifetime of the process and hands
/// a second launch over to the instance that is already running.
@MainActor
enum RunningInstance {
    static var lock: InstanceLock?

    static func handOver() -> Never {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if let other = others.first {
            other.activate(options: [.activateAllWindows])
        } else {
            let alert = NSAlert()
            alert.messageText = L10n.text("Keyboard Manager läuft bereits.")
            alert.informativeText = L10n.text("Ein anderer Vorgang verwendet gerade dieselben Daten. Bitte beende ihn und starte die App erneut.")
            alert.runModal()
        }
        exit(0)
    }
}

/// The standard macOS About panel with license, source and data location.
@MainActor
enum AboutPanel {
    static func show() {
        let dataPath = MigrationStorageLayout.default.rootURL.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let text = [
            L10n.text("Mechanische Tastatur-Sammlungen lokal erfassen, verwalten und sichern."),
            L10n.text("Lizenz: GNU GPL Version 3 oder später."),
            L10n.text("Quellcode: %@", arguments: "https://github.com/\(GitHubReleaseUpdateService.repository)"),
            L10n.text("Daten: %@", arguments: dataPath)
        ].joined(separator: "\n")
        let credits = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
