import AppKit
import CryptoKit
import Foundation
import Observation

struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(releaseTag: String) {
        let normalized = releaseTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .drop(while: { $0 == "v" })
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(bundleVersion: String) {
        self.init(releaseTag: bundleVersion)
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct AppUpdate: Equatable, Sendable {
    let version: AppVersion
    let releasePageURL: URL
    let diskImageURL: URL
    let checksumURL: URL
}

enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate
    case updateAvailable(AppUpdate)
}

protocol AppUpdateChecking: Sendable {
    func checkForUpdate(currentVersion: AppVersion) async throws -> AppUpdateCheckResult
    func downloadAndVerify(_ update: AppUpdate) async throws -> URL
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case unexpectedResponse
    case noPublishedRelease
    case noInstallableDiskImage
    case missingChecksum
    case invalidChecksum
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            "Die installierte App-Version konnte nicht gelesen werden."
        case .unexpectedResponse:
            "Der Update-Server hat keine gültige Antwort geliefert."
        case .noPublishedRelease:
            "Für dieses Repository wurde noch kein Release veröffentlicht."
        case .noInstallableDiskImage:
            "Für dieses Update wurde kein macOS-Installer gefunden."
        case .missingChecksum:
            "Für dieses Update fehlt die veröffentlichte Prüfsumme."
        case .invalidChecksum:
            "Die veröffentlichte Prüfsumme ist ungültig."
        case .checksumMismatch:
            "Der geladene Installer stimmt nicht mit der veröffentlichten Prüfsumme überein."
        }
    }
}

struct GitHubReleaseUpdateService: AppUpdateChecking {
    static let repository = "Dub76/keyboard-manager-new"

    private let repository: String
    private let loadData: @Sendable (URL) async throws -> Data

    init(
        repository: String = Self.repository,
        loadData: @escaping @Sendable (URL) async throws -> Data = Self.loadData
    ) {
        self.repository = repository
        self.loadData = loadData
    }

    func checkForUpdate(currentVersion: AppVersion) async throws -> AppUpdateCheckResult {
        let releaseURL = URL(
            string: "https://api.github.com/repos/\(repository)/releases/latest"
        )!
        let releaseData: Data
        do {
            releaseData = try await loadData(releaseURL)
        } catch AppUpdateError.noPublishedRelease {
            // A repository without any release has nothing newer to offer.
            return .upToDate
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)

        guard !release.draft, !release.prerelease,
              let version = AppVersion(releaseTag: release.tagName) else {
            return .upToDate
        }
        guard currentVersion < version else {
            return .upToDate
        }
        // This fork publishes Apple Silicon builds; universal ones still work.
        guard let diskImage = release.assets.first(where: { $0.name.hasSuffix("-arm64.dmg") })
            ?? release.assets.first(where: { $0.name.hasSuffix("-universal.dmg") }) else {
            throw AppUpdateError.noInstallableDiskImage
        }
        guard let checksum = release.assets.first(where: {
            $0.name == "\(diskImage.name).sha256"
        }) else {
            throw AppUpdateError.missingChecksum
        }

        return .updateAvailable(
            AppUpdate(
                version: version,
                releasePageURL: release.htmlURL,
                diskImageURL: diskImage.downloadURL,
                checksumURL: checksum.downloadURL
            )
        )
    }

    func downloadAndVerify(_ update: AppUpdate) async throws -> URL {
        let expectedChecksum = try Self.checksum(
            from: try await loadData(update.checksumURL)
        )
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: update.diskImageURL
        )
        // Remove the download on every path, including a rejected response.
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw AppUpdateError.unexpectedResponse
        }

        guard try Self.sha256Hex(ofFileAt: temporaryURL) == expectedChecksum else {
            throw AppUpdateError.checksumMismatch
        }

        let updatesDirectory = try Self.updatesDirectory()
        let destinationURL = updatesDirectory.appendingPathComponent(
            update.diskImageURL.lastPathComponent
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file in chunks so a large installer is never held in memory.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func checksum(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.invalidChecksum
        }
        let checksum = text
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased()
        guard let checksum,
              checksum.count == 64,
              checksum.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdateError.invalidChecksum
        }
        return checksum
    }

    private static func loadData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KeyboardManager/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateError.unexpectedResponse
        }
        if response.statusCode == 404 {
            throw AppUpdateError.noPublishedRelease
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdateError.unexpectedResponse
        }
        return data
    }

    private static func updatesDirectory() throws -> URL {
        let downloadsDirectory = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let updatesDirectory = downloadsDirectory.appendingPathComponent(
            "Keyboard Manager Updates",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: updatesDirectory,
            withIntermediateDirectories: true
        )
        return updatesDirectory
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubReleaseAsset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }
}

@MainActor
@Observable
final class AppUpdateController {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(AppUpdate)
        case downloading(AppUpdate)
        case installerOpened(AppUpdate, URL)
        case failed(String)
    }

    static let lastCheckKey = "keyboardManager.updates.lastCheck"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let service: any AppUpdateChecking
    private let currentVersion: AppVersion
    private let defaults: UserDefaults
    var state: State = .idle
    var availableUpdate: AppUpdate?
    private(set) var lastCheckDate: Date?

    init(
        service: any AppUpdateChecking = GitHubReleaseUpdateService(),
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        lastCheckDate = defaults.object(forKey: Self.lastCheckKey) as? Date
        currentVersion = AppVersion(
            bundleVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? ""
        ) ?? AppVersion(releaseTag: "0.0.0")!
    }

    var installedVersion: String { currentVersion.description }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading:
            true
        default:
            false
        }
    }

    /// The launch-time check: asks GitHub at most once a day, like V1 did.
    /// A failed check is not counted, so the next launch tries again.
    func checkForUpdatesIfDue(now: Date = .now) async {
        if let lastCheckDate {
            let age = now.timeIntervalSince(lastCheckDate)
            if age >= 0, age < Self.automaticCheckInterval { return }
        }
        await checkForUpdates(now: now)
    }

    func checkForUpdates(now: Date = .now) async {
        guard !isWorking else { return }
        state = .checking
        do {
            let result = try await service.checkForUpdate(currentVersion: currentVersion)
            lastCheckDate = now
            defaults.set(now, forKey: Self.lastCheckKey)
            switch result {
            case .upToDate:
                availableUpdate = nil
                state = .upToDate
            case let .updateAvailable(update):
                availableUpdate = update
                state = .updateAvailable(update)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func downloadAndOpen(_ update: AppUpdate) async {
        guard !isWorking else { return }
        state = .downloading(update)
        do {
            let diskImageURL = try await service.downloadAndVerify(update)
            NSWorkspace.shared.open(diskImageURL)
            state = .installerOpened(update, diskImageURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
