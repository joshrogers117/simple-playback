import Foundation
import XCTest
@testable import Simple_Playback

/// C5c-b — `PendingFolderImport` is the operator-supplied configuration for one Add
/// Folder…  import. Tests pin the gating logic that the sheet's Encode button reads
/// (`canConfirm`) and the helper that lists which sequences actually get encoded.
final class PendingFolderImportTests: XCTestCase {

    // MARK: - canConfirm

    func testCanConfirmFalseWhenNoSequencesAndNoStandalones() {
        let pending = PendingFolderImport(folderURL: anyFolder, plan: .empty)
        XCTAssertFalse(pending.canConfirm)
    }

    func testCanConfirmTrueWhenStandalonesPresentAndNoSequences() {
        let plan = AddFolderImporter.Plan(
            sequences: [],
            standaloneMediaURLs: [URL(fileURLWithPath: "/tmp/hero.mov")]
        )
        let pending = PendingFolderImport(folderURL: anyFolder, plan: plan)
        XCTAssertTrue(pending.canConfirm)
    }

    func testCanConfirmFalseWhenSequenceMarkedEncodeButRateUnset() {
        var pending = pendingWithOneSequence()
        pending.sequencePlans[0].encode = true
        pending.sequencePlans[0].frameRate = 0
        XCTAssertFalse(pending.canConfirm)
    }

    func testCanConfirmTrueWhenSequenceMarkedEncodeWithRate() {
        var pending = pendingWithOneSequence()
        pending.sequencePlans[0].encode = true
        pending.sequencePlans[0].frameRate = 30
        XCTAssertTrue(pending.canConfirm)
    }

    func testCanConfirmTrueWhenSequenceUnchecked() {
        // Operator unchecked the only sequence — but we have no standalones either, so
        // there's nothing to do. Confirm should remain disabled.
        var pending = pendingWithOneSequence()
        pending.sequencePlans[0].encode = false
        pending.sequencePlans[0].frameRate = 0
        XCTAssertFalse(pending.canConfirm)
    }

    func testCanConfirmTrueWhenSequenceUncheckedButStandalonePresent() {
        let sequence = ImageSequenceDetector.Sequence(
            baseName: "shot",
            fileExtension: "png",
            frameURLs: [URL(fileURLWithPath: "/tmp/shot.0001.png"), URL(fileURLWithPath: "/tmp/shot.0002.png")],
            counterPadWidth: 4
        )
        let plan = AddFolderImporter.Plan(
            sequences: [sequence],
            standaloneMediaURLs: [URL(fileURLWithPath: "/tmp/hero.mov")]
        )
        var pending = PendingFolderImport(folderURL: anyFolder, plan: plan)
        pending.sequencePlans[0].encode = false
        pending.sequencePlans[0].frameRate = 0
        XCTAssertTrue(pending.canConfirm)
    }

    // MARK: - encodableSequences

    func testEncodableSequencesExcludesUnchecked() {
        var pending = pendingWithTwoSequences()
        pending.sequencePlans[0].encode = false
        pending.sequencePlans[0].frameRate = 30
        pending.sequencePlans[1].encode = true
        pending.sequencePlans[1].frameRate = 24
        XCTAssertEqual(pending.encodableSequences.count, 1)
        XCTAssertEqual(pending.encodableSequences.first?.frameRate, 24)
    }

    func testEncodableSequencesExcludesZeroRate() {
        var pending = pendingWithTwoSequences()
        pending.sequencePlans[0].encode = true
        pending.sequencePlans[0].frameRate = 0
        pending.sequencePlans[1].encode = true
        pending.sequencePlans[1].frameRate = 30
        XCTAssertEqual(pending.encodableSequences.count, 1)
        XCTAssertEqual(pending.encodableSequences.first?.frameRate, 30)
    }

    // MARK: -

    private var anyFolder: URL { URL(fileURLWithPath: "/tmp/folder") }

    private func pendingWithOneSequence() -> PendingFolderImport {
        let sequence = ImageSequenceDetector.Sequence(
            baseName: "shot",
            fileExtension: "png",
            frameURLs: [
                URL(fileURLWithPath: "/tmp/shot.0001.png"),
                URL(fileURLWithPath: "/tmp/shot.0002.png")
            ],
            counterPadWidth: 4
        )
        let plan = AddFolderImporter.Plan(sequences: [sequence], standaloneMediaURLs: [])
        return PendingFolderImport(folderURL: anyFolder, plan: plan)
    }

    private func pendingWithTwoSequences() -> PendingFolderImport {
        let a = ImageSequenceDetector.Sequence(
            baseName: "a",
            fileExtension: "png",
            frameURLs: [
                URL(fileURLWithPath: "/tmp/a.0001.png"),
                URL(fileURLWithPath: "/tmp/a.0002.png")
            ],
            counterPadWidth: 4
        )
        let b = ImageSequenceDetector.Sequence(
            baseName: "b",
            fileExtension: "png",
            frameURLs: [
                URL(fileURLWithPath: "/tmp/b.0001.png"),
                URL(fileURLWithPath: "/tmp/b.0002.png")
            ],
            counterPadWidth: 4
        )
        let plan = AddFolderImporter.Plan(sequences: [a, b], standaloneMediaURLs: [])
        return PendingFolderImport(folderURL: anyFolder, plan: plan)
    }
}
