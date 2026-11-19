import XCTest
@testable import WindowDockCore

final class UILanguageTests: XCTestCase {
    func testFirstSupportedLanguageWins() {
        XCTAssertEqual(UILanguage.resolve(preferred: ["fr-FR", "ko-KR", "ja-JP"]), .ko)
        XCTAssertEqual(UILanguage.resolve(preferred: ["ja-JP", "en-US"]), .ja)
    }

    func testChineseVariantsAndCase() {
        XCTAssertEqual(UILanguage.resolve(preferred: ["zh-Hans-CN"]), .zh)
        XCTAssertEqual(UILanguage.resolve(preferred: ["ES-mx"]), .es)
    }

    func testFallsBackToEnglish() {
        XCTAssertEqual(UILanguage.resolve(preferred: ["fr-FR", "de-DE"]), .en)
        XCTAssertEqual(UILanguage.resolve(preferred: []), .en)
    }
}
