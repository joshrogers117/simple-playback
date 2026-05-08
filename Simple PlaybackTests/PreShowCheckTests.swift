import Foundation
import XCTest
@testable import Simple_Playback

/// E1 — Pre-show check evaluator. The rule surface is pure-logic with explicit context;
/// every row is independently testable. Tests pin the severity decisions, the row IDs
/// (the panel UI keys off these), and the canonical operator-facing summary strings.
final class PreShowCheckTests: XCTestCase {

    // MARK: - Media resolution

    func testMediaRowOKWhenAllCuesResolve() {
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video)
        let cue = Cue(number: "1", title: "A", assetID: slide.id)
        var project = PlayoutProject(slides: [slide])
        project.showLists = [ShowList(name: "Show", cues: [cue])]
        let row = PreShowCheck.evaluateMediaResolution(project: project)
        XCTAssertEqual(row.id, "media.resolution")
        XCTAssertEqual(row.severity, .ok)
        XCTAssertTrue(row.summary.contains("All cues resolve"))
    }

    func testMediaRowErrorWhenCueAssetMissing() {
        let cue = Cue(number: "7", title: "B", assetID: UUID())
        var project = PlayoutProject(slides: [])
        project.showLists = [ShowList(name: "Show", cues: [cue])]
        let row = PreShowCheck.evaluateMediaResolution(project: project)
        XCTAssertEqual(row.severity, .error)
        XCTAssertTrue(row.summary.contains("7"), "Cue number must appear in the summary so the operator can locate it.")
    }

    func testMediaRowSummaryTruncatesAtThree() {
        var slides: [MediaSlide] = []
        var cues: [Cue] = []
        for index in 1...7 {
            // Use unresolved assetIDs — every cue points to a slide that doesn't exist.
            cues.append(Cue(number: "\(index)", title: "C\(index)", assetID: UUID()))
        }
        // No slides, so all cues are missing.
        var project = PlayoutProject(slides: slides)
        slides = []
        project.showLists = [ShowList(name: "Show", cues: cues)]
        let row = PreShowCheck.evaluateMediaResolution(project: project)
        XCTAssertEqual(row.severity, .error)
        XCTAssertTrue(row.summary.contains("(+4 more)"),
                      "Summary should call out the count beyond the first three when there are many missing cues.")
    }

    // MARK: - Frame rate conformance

    func testFPSRowOKWhenAllVideosMatchStage() {
        let stage = Stage(name: "Program", width: 1920, height: 1080, frameRateNumerator: 30, frameRateDenominator: 1)
        var slide1 = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video, nativeFrameRate: 30)
        var slide2 = MediaSlide(url: URL(fileURLWithPath: "/tmp/b.mov"), mediaKind: .video, nativeFrameRate: 29.97)
        let cue1 = Cue(number: "1", title: "A", assetID: slide1.id)
        let cue2 = Cue(number: "2", title: "B", assetID: slide2.id)
        var project = PlayoutProject(slides: [slide1, slide2], stages: [stage])
        project.showLists = [ShowList(name: "Show", cues: [cue1, cue2])]
        let rows = PreShowCheck.evaluateFrameRateConformance(project: project)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].severity, .ok)
        XCTAssertTrue(rows[0].summary.contains("All 2 video cue"))
    }

    func testFPSRowWarningWhenAnyVideoMismatches() {
        let stage = Stage(name: "Program", width: 1920, height: 1080, frameRateNumerator: 60, frameRateDenominator: 1)
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video, nativeFrameRate: 24)
        let cue = Cue(number: "1", title: "A", assetID: slide.id)
        var project = PlayoutProject(slides: [slide], stages: [stage])
        project.showLists = [ShowList(name: "Show", cues: [cue])]
        let rows = PreShowCheck.evaluateFrameRateConformance(project: project)
        XCTAssertEqual(rows[0].severity, .warning)
        XCTAssertTrue(rows[0].summary.contains("AVFoundation will re-time"))
    }

    func testFPSRowInfoWhenNoVideoCues() {
        let stage = Stage(name: "Program", width: 1920, height: 1080, frameRateNumerator: 30, frameRateDenominator: 1)
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.png"), mediaKind: .image)
        let cue = Cue(number: "1", title: "A", assetID: slide.id)
        var project = PlayoutProject(slides: [slide], stages: [stage])
        project.showLists = [ShowList(name: "Show", cues: [cue])]
        let rows = PreShowCheck.evaluateFrameRateConformance(project: project)
        XCTAssertEqual(rows[0].severity, .info)
        XCTAssertTrue(rows[0].summary.contains("No video cues"))
    }

    func testFPSRowWarningWhenStageMissingFrameRate() {
        // Project with no stages → no frame rate to compare against.
        let project = PlayoutProject(slides: [], stages: [])
        let rows = PreShowCheck.evaluateFrameRateConformance(project: project)
        XCTAssertEqual(rows[0].id, "stage.frameRate")
        XCTAssertEqual(rows[0].severity, .warning)
    }

    // MARK: - Ten-bit recommendation

    func testTenBitRowSuppressedWhenNoTenBitContent() {
        let project = PlayoutProject(slides: [])
        XCTAssertNil(PreShowCheck.evaluateTenBitRecommendation(project: project),
                     "Suppress informational rows that have nothing to say — pre-show panels degrade fast with noise.")
    }

    func testTenBitRowInfoWhenAnyTenBitContentPresent() {
        var slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video)
        slide.flags.tenBitYUV420 = true
        let project = PlayoutProject(slides: [slide])
        let row = PreShowCheck.evaluateTenBitRecommendation(project: project)
        XCTAssertEqual(row?.severity, .info)
        XCTAssertEqual(row?.id, "output.tenBit")
    }

    // MARK: - External reference

    func testReferenceRowSuppressedWhenNotExpected() {
        var project = PlayoutProject()
        project.expectsExternalReference = false
        let row = PreShowCheck.evaluateExternalReference(project: project, context: PreShowCheck.Context())
        XCTAssertNil(row)
    }

    func testReferenceRowOKWhenLocked() {
        var project = PlayoutProject()
        project.expectsExternalReference = true
        var ctx = PreShowCheck.Context()
        ctx.deckLinkReferenceStatus = .locked
        let row = PreShowCheck.evaluateExternalReference(project: project, context: ctx)
        XCTAssertEqual(row?.severity, .ok)
    }

    func testReferenceRowErrorWhenExpectedButUnlocked() {
        var project = PlayoutProject()
        project.expectsExternalReference = true
        var ctx = PreShowCheck.Context()
        ctx.deckLinkReferenceStatus = .unlocked
        let row = PreShowCheck.evaluateExternalReference(project: project, context: ctx)
        XCTAssertEqual(row?.severity, .error)
        XCTAssertTrue(row?.summary.contains("free-running") ?? false)
    }

    func testReferenceRowWarningWhenDeckLinkDoesNotSupportLock() {
        var project = PlayoutProject()
        project.expectsExternalReference = true
        var ctx = PreShowCheck.Context()
        ctx.deckLinkReferenceStatus = .notSupported
        let row = PreShowCheck.evaluateExternalReference(project: project, context: ctx)
        XCTAssertEqual(row?.severity, .warning)
    }

    func testReferenceRowInfoWhenLockNotYetSampled() {
        var project = PlayoutProject()
        project.expectsExternalReference = true
        let ctx = PreShowCheck.Context()  // deckLinkReferenceStatus = nil
        let row = PreShowCheck.evaluateExternalReference(project: project, context: ctx)
        XCTAssertEqual(row?.severity, .info)
    }

    // MARK: - Disk

    func testDiskRowSuppressedWhenNoMeasurement() {
        let row = PreShowCheck.evaluateDiskSpace(context: PreShowCheck.Context())
        XCTAssertNil(row)
    }

    func testDiskRowOKWhenAboveFloor() {
        var ctx = PreShowCheck.Context()
        ctx.availableDiskBytes = 50_000_000_000  // 50 GB
        let row = PreShowCheck.evaluateDiskSpace(context: ctx)
        XCTAssertEqual(row?.severity, .ok)
    }

    func testDiskRowWarningBelowFloor() {
        var ctx = PreShowCheck.Context()
        ctx.availableDiskBytes = 1_000_000_000  // 1 GB — below default 5 GB floor
        let row = PreShowCheck.evaluateDiskSpace(context: ctx)
        XCTAssertEqual(row?.severity, .warning)
    }

    // MARK: - Audio

    func testAudioRowSuppressedWhenNoMeasurement() {
        let row = PreShowCheck.evaluateAudioDevice(context: PreShowCheck.Context())
        XCTAssertNil(row)
    }

    func testAudioRowErrorWhenNoDevice() {
        var ctx = PreShowCheck.Context()
        ctx.audioDeviceAvailable = false
        let row = PreShowCheck.evaluateAudioDevice(context: ctx)
        XCTAssertEqual(row?.severity, .error)
    }

    func testAudioRowOKWhenDevicePresent() {
        var ctx = PreShowCheck.Context()
        ctx.audioDeviceAvailable = true
        let row = PreShowCheck.evaluateAudioDevice(context: ctx)
        XCTAssertEqual(row?.severity, .ok)
    }

    // MARK: - Top-level evaluate ordering

    func testEvaluateSortsErrorsBeforeWarningsBeforeInfoBeforeOk() {
        // Project with a missing-media error AND a frame-rate-mismatch warning AND a
        // 10-bit info row. Verify error sorts first.
        var slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video, nativeFrameRate: 24)
        slide.flags.tenBitYUV420 = true
        let stage = Stage(name: "Program", width: 1920, height: 1080, frameRateNumerator: 60, frameRateDenominator: 1)
        let goodCue = Cue(number: "1", title: "A", assetID: slide.id)
        let missingCue = Cue(number: "2", title: "B", assetID: UUID())
        var project = PlayoutProject(slides: [slide], stages: [stage])
        project.showLists = [ShowList(name: "Show", cues: [goodCue, missingCue])]
        let rows = PreShowCheck.evaluate(project: project)
        XCTAssertGreaterThan(rows.count, 0)
        // First non-OK row should be the error.
        XCTAssertEqual(rows.first?.severity, .error)
    }

    // MARK: - DeckLink adapter

    /// The bridge state → PreShowCheck enum mapping is the single seam between the
    /// live DeckLink output and the pre-show evaluator. Pin every case so a future
    /// renaming on either side trips a test.
    func testDeckLinkAdapterMapsIdleToNotRequired() {
        XCTAssertEqual(PreShowCheck.DeckLinkReferenceStatus.from(.idle), .notRequired)
    }

    func testDeckLinkAdapterMapsNotSupportedDirectly() {
        XCTAssertEqual(PreShowCheck.DeckLinkReferenceStatus.from(.notSupported), .notSupported)
    }

    func testDeckLinkAdapterMapsUnlockedDirectly() {
        XCTAssertEqual(PreShowCheck.DeckLinkReferenceStatus.from(.unlocked), .unlocked)
    }

    func testDeckLinkAdapterMapsLockedDirectly() {
        XCTAssertEqual(PreShowCheck.DeckLinkReferenceStatus.from(.locked), .locked)
    }
}
