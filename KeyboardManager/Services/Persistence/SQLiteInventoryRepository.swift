import Foundation
import SQLite3

enum SQLiteInventoryRepositoryError: LocalizedError, Sendable {
    case open(String)
    case execute(String)
    case encode(String)
    case decode(String)
    case integrity(String)

    var errorDescription: String? {
        switch self {
        case let .open(message):
            L10n.text("Die V2-Datenbank konnte nicht geöffnet werden: %@", arguments: message)
        case let .execute(message):
            L10n.text("Die V2-Datenbankoperation ist fehlgeschlagen: %@", arguments: message)
        case let .encode(message):
            L10n.text("Der V2-Bestand konnte nicht serialisiert werden: %@", arguments: message)
        case let .decode(message):
            L10n.text("Der gespeicherte V2-Bestand ist nicht lesbar: %@", arguments: message)
        case let .integrity(message):
            L10n.text("Die SQLite-Integritätsprüfung ist fehlgeschlagen: %@", arguments: message)
        }
    }
}

actor SQLiteInventoryRepository: InventoryRepository {
    static let schemaVersion = 1

    let databaseURL: URL

    init(databaseURL: URL = MigrationStorageLayout.default.currentDatabaseURL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    func loadSnapshot() async throws -> InventorySnapshot {
        let databaseURL = databaseURL
        return try await Task.detached(priority: .userInitiated) {
            try Self.loadSynchronously(from: databaseURL)
        }.value
    }

    func saveSnapshot(_ snapshot: InventorySnapshot) async throws {
        let databaseURL = databaseURL
        try await Task.detached(priority: .userInitiated) {
            try Self.saveSynchronously(snapshot, to: databaseURL)
        }.value
    }

    func verifyIntegrity() async throws {
        let databaseURL = databaseURL
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw SQLiteInventoryRepositoryError.integrity(
                    L10n.text("Datenbankdatei fehlt.")
                )
            }
            let database = try Self.openDatabase(at: databaseURL, createIfNeeded: false)
            defer { sqlite3_close(database) }
            try Self.verifyIntegrity(of: database)
        }.value
    }

    private static func loadSynchronously(from url: URL) throws -> InventorySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        let database = try openDatabase(at: url, createIfNeeded: false)
        defer { sqlite3_close(database) }
        try configure(database)
        try createSchema(in: database)

        let statement = try prepare(
            "SELECT snapshot_json FROM app_snapshot WHERE id = 1;",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw SQLiteInventoryRepositoryError.decode(
                    L10n.text("Snapshot enthält keine Daten.")
                )
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: byteCount)
            do {
                return try decoder().decode(InventorySnapshot.self, from: data)
            } catch {
                throw SQLiteInventoryRepositoryError.decode(error.localizedDescription)
            }
        case SQLITE_DONE:
            return .empty
        default:
            throw SQLiteInventoryRepositoryError.execute(errorMessage(database))
        }
    }

    private static func saveSynchronously(_ snapshot: InventorySnapshot, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SQLiteInventoryRepositoryError.open(error.localizedDescription)
        }

        let data: Data
        do {
            data = try encoder().encode(snapshot)
        } catch {
            throw SQLiteInventoryRepositoryError.encode(error.localizedDescription)
        }

        let database = try openDatabase(at: url, createIfNeeded: true)
        defer { sqlite3_close(database) }
        try configure(database)
        try createSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)

        do {
            let statement = try prepare(
                """
                INSERT INTO app_snapshot (id, schema_version, snapshot_json, updated_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    schema_version = excluded.schema_version,
                    snapshot_json = excluded.snapshot_json,
                    updated_at = excluded.updated_at;
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            guard sqlite3_bind_int(statement, 1, Int32(schemaVersion)) == SQLITE_OK else {
                throw SQLiteInventoryRepositoryError.execute(errorMessage(database))
            }
            let bindResult = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(
                    statement,
                    2,
                    rawBuffer.baseAddress,
                    Int32(rawBuffer.count),
                    sqliteTransient
                )
            }
            guard bindResult == SQLITE_OK,
                  sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteInventoryRepositoryError.execute(errorMessage(database))
            }

            // Check inside the transaction: once COMMIT has run, ROLLBACK can no
            // longer undo the write, and reporting a failure then would make
            // callers clean up files the stored snapshot already references.
            try verifyIntegrity(of: database)
            try execute("COMMIT;", in: database)
        } catch {
            try? execute("ROLLBACK;", in: database)
            throw error
        }
    }

    private static func openDatabase(at url: URL, createIfNeeded: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | (createIfNeeded ? SQLITE_OPEN_CREATE : 0)
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database {
                let message = errorMessage(database)
                sqlite3_close(database)
                throw SQLiteInventoryRepositoryError.open(message)
            }
            throw SQLiteInventoryRepositoryError.open(
                L10n.text("SQLite-Fehler %lld", arguments: result)
            )
        }
        return database
    }

    private static func configure(_ database: OpaquePointer) throws {
        try execute("PRAGMA foreign_keys = ON;", in: database)
        try execute("PRAGMA journal_mode = WAL;", in: database)
        try execute("PRAGMA synchronous = FULL;", in: database)
        try execute("PRAGMA busy_timeout = 5000;", in: database)
    }

    private static func createSchema(in database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS app_snapshot (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                schema_version INTEGER NOT NULL,
                snapshot_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            PRAGMA user_version = 1;
            """,
            in: database
        )
    }

    private static func verifyIntegrity(of database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA integrity_check;", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              String(cString: value) == "ok" else {
            throw SQLiteInventoryRepositoryError.integrity(errorMessage(database))
        }
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(errorPointer)
            throw SQLiteInventoryRepositoryError.execute(message)
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteInventoryRepositoryError.execute(errorMessage(database))
        }
        return statement
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
