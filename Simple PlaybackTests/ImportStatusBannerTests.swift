import Foundation
import XCTest
@testable import Simple_Playback

/// C-banner-b — `ImportStatusBanner` aggregates failures across the import + transcode
/// surfaces. UI tests don't drive SwiftUI popovers; this suite pins the model and the
/// `headline` copy so regressions in counter agreement (singular vs. plural) bubble up.
@MainActor
final class ImportStatusBannerTests: XCTestCase {

    func testStartsEmpty() {
        let banner = ImportStatusBanner()
        XCTAssertEqual(banner.failures, [])
        XCTAssertEqual(banner.headline, "")
    }

    func testRecordEmptyArrayIsNoop() {
        let banner = ImportStatusBanner()
        banner.record([])
        XCTAssertEqual(banner.failures, [])
    }

    func testRecordAppendsBatch() {
        let banner = ImportStatusBanner()
        let failure = MediaImportFailure(
            url: URL(fileURLWithPath: "/tmp/deck.pdf"),
            kind: .pdfImport,
            summary: "PDF could not be opened: deck.pdf"
        )
        banner.record([failure])
        XCTAssertEqual(banner.failures, [failure])
        XCTAssertEqual(banner.headline, "1 item failed to import",
                       "Singular form when there's exactly one failure.")
    }

    func testRecordTwiceIsAppendOnly() {
        let banner = ImportStatusBanner()
        let f1 = MediaImportFailure(url: nil, kind: .pdfImport, summary: "a")
        let f2 = MediaImportFailure(url: nil, kind: .keynoteImport, summary: "b")
        banner.record([f1])
        banner.record([f2])
        XCTAssertEqual(banner.failures.count, 2,
                       "A second failed import must not overwrite the first — banner is append-only until dismiss.")
        XCTAssertEqual(banner.headline, "2 items failed to import")
    }

    func testRecordTranscodeAppendsTranscodeFailure() {
        let banner = ImportStatusBanner()
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        banner.recordTranscode(url: url, error: .exportFailed("preset incompatible"))
        XCTAssertEqual(banner.failures.count, 1)
        XCTAssertEqual(banner.failures.first?.kind, .transcode)
        XCTAssertEqual(banner.failures.first?.url, url)
        XCTAssertTrue(banner.failures.first?.summary.contains("preset incompatible") ?? false,
                      "Transcode failure summary must propagate the underlying reason.")
    }

    func testDismissClearsAllFailures() {
        let banner = ImportStatusBanner()
        banner.record([MediaImportFailure(url: nil, kind: .pdfImport, summary: "a")])
        banner.recordTranscode(url: nil, error: .exportFailed("b"))
        XCTAssertEqual(banner.failures.count, 2)
        banner.dismiss()
        XCTAssertEqual(banner.failures, [])
        XCTAssertEqual(banner.headline, "")
    }

    func testHasKeynoteFailureFalseForNonKeynoteFailures() {
        let banner = ImportStatusBanner()
        banner.record([
            MediaImportFailure(url: nil, kind: .pdfImport, summary: "a"),
            MediaImportFailure(url: nil, kind: .transcode, summary: "b"),
            MediaImportFailure(url: nil, kind: .unsupportedMedia, summary: "c")
        ])
        XCTAssertFalse(banner.hasKeynoteFailure,
                       "Non-Keynote failures must not trip the automation deep-link.")
    }

    func testHasKeynoteFailureTrueWhenAnyKeynoteFailurePresent() {
        let banner = ImportStatusBanner()
        banner.record([
            MediaImportFailure(url: nil, kind: .pdfImport, summary: "a"),
            MediaImportFailure(url: nil, kind: .keynoteImport, summary: "b")
        ])
        XCTAssertTrue(banner.hasKeynoteFailure)
    }

    func testAutomationPrivacySettingsURLIsValidDeepLink() {
        // Spec contract — deep-link must use the macOS x-apple.systempreferences scheme
        // and target the Automation Privacy pane. NSWorkspace will open whatever URL we
        // hand it, so a typo here would silently fail to surface the right setting.
        XCTAssertEqual(
            AutomationPrivacySettings.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )
    }

    func testHeadlinePluralization() {
        let banner = ImportStatusBanner()
        XCTAssertEqual(banner.headline, "")

        banner.record([MediaImportFailure(url: nil, kind: .pdfImport, summary: "a")])
        XCTAssertEqual(banner.headline, "1 item failed to import")

        banner.record([
            MediaImportFailure(url: nil, kind: .pdfImport, summary: "b"),
            MediaImportFailure(url: nil, kind: .keynoteImport, summary: "c")
        ])
        XCTAssertEqual(banner.headline, "3 items failed to import")
    }
}
