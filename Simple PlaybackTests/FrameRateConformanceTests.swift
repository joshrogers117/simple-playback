import Foundation
import XCTest
@testable import Simple_Playback

final class FrameRateConformanceTests: XCTestCase {

    // MARK: - Severity matrix

    func testMatchesWithinTolerance() {
        // 23.976 vs 24 — Δ ≈ 0.024 — within tolerance, treated as a match. The fractional /
        // integer pair is the canonical "is your master fractional?" trap; we don't blow it
        // up into a warning.
        XCTAssertEqual(FrameRateConformance(clipFPS: 23.976, stageFPS: 24).severity, .match)
        XCTAssertEqual(FrameRateConformance(clipFPS: 24, stageFPS: 23.976).severity, .match)
        XCTAssertEqual(FrameRateConformance(clipFPS: 29.97, stageFPS: 30).severity, .match)
        XCTAssertEqual(FrameRateConformance(clipFPS: 59.94, stageFPS: 60).severity, .match)
    }

    func testFlagsCadenceMismatches() {
        XCTAssertEqual(FrameRateConformance(clipFPS: 24, stageFPS: 25).severity, .mismatch)
        XCTAssertEqual(FrameRateConformance(clipFPS: 23.976, stageFPS: 59.94).severity, .mismatch)
        XCTAssertEqual(FrameRateConformance(clipFPS: 30, stageFPS: 60).severity, .mismatch)
        XCTAssertEqual(FrameRateConformance(clipFPS: 25, stageFPS: 29.97).severity, .mismatch)
    }

    func testUnknownClipRateIsInformational() {
        XCTAssertEqual(FrameRateConformance(clipFPS: nil, stageFPS: 60).severity, .unknown)
        XCTAssertEqual(FrameRateConformance(clipFPS: 0, stageFPS: 60).severity, .unknown,
                       "Zero clip FPS (asset failed to inspect) reads as unknown, not a mismatch.")
    }

    // MARK: - Stage convenience

    func testInitFromStage() {
        let stage = Stage(name: "P", frameRateNumerator: 60_000, frameRateDenominator: 1001)
        let c = FrameRateConformance(clipFPS: 23.976, stage: stage)
        XCTAssertEqual(c.severity, .mismatch)
        XCTAssertEqual(c.stageFPS, 60_000.0 / 1001.0, accuracy: 0.0001)
    }

    // MARK: - Operator-facing strings

    func testSummaryStringsAreStable() {
        XCTAssertEqual(FrameRateConformance(clipFPS: 60, stageFPS: 60).summary,
                       "Frame rate matches Stage.")
        XCTAssertEqual(FrameRateConformance(clipFPS: nil, stageFPS: 60).summary,
                       "Native frame rate unknown — verify on the timeline.")
        let mismatch = FrameRateConformance(clipFPS: 23.976, stageFPS: 59.94)
        XCTAssertTrue(mismatch.summary.contains("AVFoundation will re-time"),
                      "Summary should explain what happens at runtime, not just that there's a mismatch.")
    }

    func testFormatRendersIntegersWithoutDecimals() {
        XCTAssertEqual(FrameRateConformance.format(30), "30")
        XCTAssertEqual(FrameRateConformance.format(60), "60")
        XCTAssertEqual(FrameRateConformance.format(24), "24")
    }

    func testFormatPreservesFractionalRates() {
        XCTAssertTrue(FrameRateConformance.format(29.97).contains("29.9"))
        XCTAssertTrue(FrameRateConformance.format(23.976).contains("24") ||
                      FrameRateConformance.format(23.976).contains("23"),
                      "Fractional rates render with enough precision for the operator to recognise them.")
    }

    // MARK: - Slide migration safety

    func testLegacySlideJSONWithoutNativeFrameRateDecodes() throws {
        // A v1/v2 project saved before B14 had no `nativeFrameRate` field. The decoder must
        // tolerate its absence — projects on disk must keep opening cleanly.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "old clip",
          "mediaKind": "video",
          "media": { "originalPath": "/tmp/missing.mov" },
          "settings": {
            "scaleMode": "fit",
            "alignment": "center",
            "customScale": 1.0,
            "offsetX": 0,
            "offsetY": 0,
            "loopVideo": true,
            "volume": 1.0
          }
        }
        """.data(using: .utf8)!
        let slide = try JSONDecoder().decode(MediaSlide.self, from: json)
        XCTAssertNil(slide.nativeFrameRate,
                     "A pre-B14 slide must decode with nativeFrameRate == nil, not a default like 30.")
        XCTAssertEqual(slide.title, "old clip")
        XCTAssertEqual(slide.mediaKind, .video)
    }

    func testNewSlideRoundTripsNativeFrameRate() throws {
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        var slide = MediaSlide(url: url, mediaKind: .video, nativeFrameRate: 23.976)
        slide.title = "round trip"

        let data = try JSONEncoder().encode(slide)
        let decoded = try JSONDecoder().decode(MediaSlide.self, from: data)
        XCTAssertEqual(decoded.nativeFrameRate, 23.976)
        XCTAssertEqual(decoded.title, "round trip")
        XCTAssertEqual(decoded.mediaKind, .video)
    }
}
