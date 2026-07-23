import XCTest
@testable import BarKeep

final class AppVersionTests: XCTestCase {
    func testUsesBundleShortVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]

        XCTAssertEqual(AppVersion.displayVersion(from: info), "1.2.3")
    }

    func testFallsBackForDevelopmentBuilds() {
        XCTAssertEqual(AppVersion.displayVersion(from: nil), "development")
    }
}
