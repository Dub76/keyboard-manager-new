import Foundation

struct MigrationStorageLayout: Hashable, Sendable {
    static let applicationDirectoryName = "de.r3d42.KeyboardManagerV2"

    var rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static var `default`: MigrationStorageLayout {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return MigrationStorageLayout(
            rootURL: applicationSupport.appendingPathComponent(applicationDirectoryName, isDirectory: true)
        )
    }

    var currentDirectoryURL: URL {
        rootURL.appendingPathComponent("Current", isDirectory: true)
    }

    var currentDatabaseURL: URL {
        currentDirectoryURL.appendingPathComponent("inventory.sqlite")
    }

    var currentPhotosDirectoryURL: URL {
        currentDirectoryURL.appendingPathComponent("Photos", isDirectory: true)
    }

    var currentThumbnailsDirectoryURL: URL {
        currentDirectoryURL.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    var stagingRootURL: URL {
        rootURL.appendingPathComponent("Staging", isDirectory: true)
    }

    var backupsRootURL: URL {
        rootURL.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Daily ZIP backups, kept apart from the `<migration-id>-previous`
    /// folders that a migration moves into `Backups/`.
    var automaticBackupsRootURL: URL {
        backupsRootURL.appendingPathComponent("Automatic", isDirectory: true)
    }

    var reportsRootURL: URL {
        rootURL.appendingPathComponent("MigrationReports", isDirectory: true)
    }
}
