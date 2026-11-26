import WindowDockCore
import XCTest

final class AudioPlaybackTests: XCTestCase {
    func testPlayingHelpersCountForTheirApplications() {
        // 200: browser audio helper of 100. 300: WebKit GPU process that launchd started for 150.
        // 400: command-line player in shell 401 of terminal 402. 500: unrelated application.
        let parents: [pid_t: pid_t] = [200: 100, 100: 1, 300: 1, 150: 1, 400: 401, 401: 402, 402: 1, 500: 1]
        let responsible: [pid_t: pid_t] = [300: 150, 400: 402]
        let applications = AudioPlaybackAttribution.applications(
            of: [200, 300, 400], responsible: { responsible[$0] ?? -1 }, parent: { parents[$0] })
        XCTAssertEqual(applications, [200, 100, 300, 150, 400, 401, 402])
    }

    func testAncestorWalkStopsOnCyclesAndDeepChains() {
        let cycle = AudioPlaybackAttribution.applications(
            of: [10], responsible: { _ in nil }, parent: { $0 == 10 ? 11 : 10 })
        XCTAssertEqual(cycle, [10, 11])
        let deep = AudioPlaybackAttribution.applications(of: [1000], responsible: { _ in nil }, parent: { $0 + 1 })
        XCTAssertEqual(deep.count, 16)
    }

    func testStoppedApplicationsStayAudibleUntilTheHoldExpires() {
        var recent = RecentlyAudibleApplications(hold: 2)
        XCTAssertEqual(recent.update(playing: [1, 2], at: 0), [1, 2])
        XCTAssertNil(recent.nextExpiry)
        XCTAssertEqual(recent.update(playing: [2], at: 1), [1, 2])
        XCTAssertEqual(recent.nextExpiry, 3)
        XCTAssertEqual(recent.update(playing: [2], at: 2.9), [1, 2])
        XCTAssertEqual(recent.update(playing: [2], at: 3), [2])
        XCTAssertNil(recent.nextExpiry)
    }

    func testResumingCancelsTheHold() {
        var recent = RecentlyAudibleApplications(hold: 2)
        _ = recent.update(playing: [1], at: 0)
        _ = recent.update(playing: [], at: 1)
        XCTAssertEqual(recent.update(playing: [1], at: 1.5), [1])
        XCTAssertNil(recent.nextExpiry)
        XCTAssertEqual(recent.update(playing: [], at: 2), [1])
        XCTAssertEqual(recent.nextExpiry, 4)
        XCTAssertEqual(recent.update(playing: [], at: 4), [])
    }

    func testChromeTabLabelsTellPlayingFromMutedTabsInAnyLanguage() {
        func audio(_ name: String, indicator: Bool = false) -> BrowserTabAudio {
            BrowserTabAudio(name: name, hasAlertIndicator: { indicator })
        }
        XCTAssertEqual(audio("Tone Probe - オーディオ再生中です - メモリ使用量 - 16.9 MB"), .playing)
        XCTAssertEqual(audio("Video - Audio playing - Memory usage - 80 MB"), .playing)
        XCTAssertEqual(audio("Video – Audio playing"), .playing)
        XCTAssertEqual(audio("„Vaizdo įrašas“ – garso įrašo paleidimas"), .playing)
        XCTAssertEqual(audio("Vidéo\u{00A0}–\u{00A0}Lecture audio"), .playing)
        XCTAssertEqual(audio("Video - Audio muted", indicator: true), .muted)
        XCTAssertEqual(audio("動画 - オーディオがミュートされています"), .muted)
        XCTAssertEqual(audio("Silent Probe - メモリ使用量 - 16.2 MB"), .silent)
        XCTAssertFalse(audio("Silent Probe - メモリ使用量 - 16.2 MB").mayBePlaying)
        XCTAssertFalse(audio("Video - Audio muted").mayBePlaying)
    }

    func testUnrecognizedAlertsMayHideAPlayingTab() {
        let meeting = BrowserTabAudio(name: "Meet - Camera recording", hasAlertIndicator: { true })
        XCTAssertEqual(meeting, .otherAlert)
        XCTAssertTrue(meeting.mayBePlaying)
        let labelled = BrowserTabAudio(name: "Video - Audio playing") {
            XCTFail("a recognized label needs no indicator check")
            return true
        }
        XCTAssertEqual(labelled, .playing)
    }
}
