import XCTest
@testable import KeyboardManager

final class AppUpdateServiceTests: XCTestCase {
    func testVersionComparisonAcceptsReleaseTags() throws {
        let current = try XCTUnwrap(AppVersion(releaseTag: "v1.0.0"))
        let newer = try XCTUnwrap(AppVersion(releaseTag: "1.0.1"))

        XCTAssertLessThan(current, newer)
        XCTAssertNil(AppVersion(releaseTag: "v1.0"))
        XCTAssertNil(AppVersion(releaseTag: "v1.0.0-beta"))
    }

    func testLatestReleaseReturnsVerifiedInstallerAssets() async throws {
        let fixture = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/example/keyboard/releases/tag/v1.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg"
            },
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg.sha256",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!
        let service = GitHubReleaseUpdateService(loadData: { _ in fixture })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: current)

        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(update.version.description, "1.2.0")
        XCTAssertEqual(update.diskImageURL.lastPathComponent, "Keyboard-Manager-1.2.0-universal.dmg")
        XCTAssertEqual(update.checksumURL.lastPathComponent, "Keyboard-Manager-1.2.0-universal.dmg.sha256")
    }

    func testCurrentVersionDoesNotOfferSameRelease() async throws {
        let fixture = """
        {
          "tag_name": "v1.0.0",
          "html_url": "https://github.com/example/keyboard/releases/tag/v1.0.0",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """.data(using: .utf8)!
        let service = GitHubReleaseUpdateService(loadData: { _ in fixture })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: current)
        XCTAssertEqual(result, .upToDate)
    }

    func testAppleSiliconInstallerIsPreferred() async throws {
        let fixture = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/example/keyboard/releases/tag/v1.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg"
            },
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg.sha256",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg.sha256"
            },
            {
              "name": "Keyboard-Manager-1.2.0-arm64.dmg",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-arm64.dmg"
            },
            {
              "name": "Keyboard-Manager-1.2.0-arm64.dmg.sha256",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-arm64.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!
        let service = GitHubReleaseUpdateService(loadData: { _ in fixture })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.1.2"))

        let result = try await service.checkForUpdate(currentVersion: current)

        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an update, got \(result)")
        }
        XCTAssertEqual(update.diskImageURL.lastPathComponent, "Keyboard-Manager-1.2.0-arm64.dmg")
        XCTAssertEqual(update.checksumURL.lastPathComponent, "Keyboard-Manager-1.2.0-arm64.dmg.sha256")
    }

    func testRepositoryWithoutReleaseCountsAsUpToDate() async throws {
        let service = GitHubReleaseUpdateService(loadData: { _ in
            throw AppUpdateError.noPublishedRelease
        })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: current)

        XCTAssertEqual(result, .upToDate)
    }

    func testOtherUpdateFailuresAreStillReported() async throws {
        let service = GitHubReleaseUpdateService(loadData: { _ in
            throw AppUpdateError.unexpectedResponse
        })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        do {
            _ = try await service.checkForUpdate(currentVersion: current)
            XCTFail("Expected the failure to be reported")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .unexpectedResponse)
        }
    }

    func testChecksumParserAndHashRejectTampering() throws {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            GitHubReleaseUpdateService.sha256Hex(of: data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            try GitHubReleaseUpdateService.checksum(
                from: Data("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  update.dmg\n".utf8)
            ),
            GitHubReleaseUpdateService.sha256Hex(of: data)
        )
        XCTAssertThrowsError(
            try GitHubReleaseUpdateService.checksum(from: Data("not-a-checksum".utf8))
        )
    }
    @MainActor
    func testAutomaticUpdateCheckRunsAtMostOncePerDay() async throws {
        let suiteName = "KeyboardManagerUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = CountingUpdateService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let controller = AppUpdateController(service: service, defaults: defaults)
        await controller.checkForUpdatesIfDue(now: start)
        await controller.checkForUpdatesIfDue(now: start + 3_600)
        var calls = await service.calls
        XCTAssertEqual(calls, 1)

        // A new launch reads the stored date; a manual check always runs.
        let relaunched = AppUpdateController(service: service, defaults: defaults)
        XCTAssertEqual(relaunched.lastCheckDate, start)
        await relaunched.checkForUpdatesIfDue(now: start + 7_200)
        await relaunched.checkForUpdates(now: start + 7_300)
        calls = await service.calls
        XCTAssertEqual(calls, 2)

        await relaunched.checkForUpdatesIfDue(now: start + 7_300 + 24 * 60 * 60)
        calls = await service.calls
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testFailedAutomaticUpdateCheckIsRetriedNextLaunch() async throws {
        let suiteName = "KeyboardManagerUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = CountingUpdateService(fails: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let controller = AppUpdateController(service: service, defaults: defaults)
        await controller.checkForUpdatesIfDue(now: start)
        await controller.checkForUpdatesIfDue(now: start + 60)

        let calls = await service.calls
        XCTAssertEqual(calls, 2)
        XCTAssertNil(controller.lastCheckDate)
    }
}

private actor CountingUpdateService: AppUpdateChecking {
    private(set) var calls = 0
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    func checkForUpdate(currentVersion: AppVersion) async throws -> AppUpdateCheckResult {
        calls += 1
        if fails { throw AppUpdateError.unexpectedResponse }
        return .upToDate
    }

    func downloadAndVerify(_ update: AppUpdate) async throws -> URL {
        throw AppUpdateError.unexpectedResponse
    }
}
