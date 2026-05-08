import AppKit
import SwiftUI
import XCTest
@testable import Simple_Playback

/// View-level unit coverage for the B12d overlay inspector. SwiftUI bodies are not
/// reachable from XCTest without a UI host, so the assertions here cover the model
/// helpers the inspector relies on:
///   - the `RGBAColor(color:)` SwiftUI bridge round-trip,
///   - the `InspectorMode` enum that drives the segmented picker.
final class OverlayInspectorTests: XCTestCase {

    func testRGBAColorRoundTripFromSwiftUIColor() {
        let red = RGBAColor(color: Color(red: 1, green: 0, blue: 0, opacity: 1))
        XCTAssertEqual(red.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(red.green, 0.0, accuracy: 0.001)
        XCTAssertEqual(red.blue, 0.0, accuracy: 0.001)
        XCTAssertEqual(red.alpha, 1.0, accuracy: 0.001)

        let translucentBlue = RGBAColor(color: Color(red: 0, green: 0, blue: 1, opacity: 0.4))
        XCTAssertEqual(translucentBlue.blue, 1.0, accuracy: 0.001)
        XCTAssertEqual(translucentBlue.alpha, 0.4, accuracy: 0.01)
    }

    func testInspectorModeCasesAndLabels() {
        XCTAssertEqual(InspectorMode.allCases, [.selection, .overlays])
        XCTAssertEqual(InspectorMode.selection.label, "Selection")
        XCTAssertEqual(InspectorMode.overlays.label, "Overlays")
    }
}
