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

    /// Photos of the most recent deletion, kept until it can no longer be undone.
    var deletedPhotosRootURL: URL {
        rootURL.appendingPathComponent("DeletedPhotos", isDirectory: true)
    }

    var reportsRootURL: URL {
        rootURL.appendingPathComponent("MigrationReports", isDirectory: true)
    }
}

/// Ensures only one app process works on a data folder. Every process keeps
/// its own copy of the collection in memory, so a second one could overwrite
/// the first one's changes. The system releases the lock when the process
/// ends, even after a crash.
final class InstanceLock: @unchecked Sendable {
    private let directoryURL: URL
    private var descriptor: Int32 = -1

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    deinit {
        release()
    }

    /// Returns false only if another process holds the lock. If the lock file
    /// cannot be created at all, the app must still be able to start.
    func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let path = directoryURL.appendingPathComponent(".instance.lock").path
        let candidate = open(path, O_CREAT | O_RDWR, 0o644)
        guard candidate >= 0 else { return true }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            let lockedByOtherProcess = errno == EWOULDBLOCK
            close(candidate)
            return !lockedByOtherProcess
        }
        descriptor = candidate
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}
