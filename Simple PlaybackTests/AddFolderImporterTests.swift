import Foundation
import XCTest
@testable import Simple_Playback

/// C5c-a — `AddFolderImporter` walks one folder a single level deep, runs the C5a
/// detector, and partitions the results for the host. Tests pin: hidden-file skipping,
/// non-recursive walk, deterministic ordering, and the sequence-vs-standalone split.
final class AddFolderImporterTests: XCTestCase {

    private var workingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddFolderImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: -

    func testPlanGroupsContiguousFramesIntoSequence() throws {
        try touch("shot01.0001.png")
        try touch("shot01.0002.png")
        try touch("shot01.0003.png")
        try touch("README.txt")

        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)

        XCTAssertEqual(plan.sequences.count, 1)
        XCTAssertEqual(plan.sequences.first?.baseName, "shot01")
        XCTAssertEqual(plan.sequences.first?.frameURLs.count, 3)
        // README.txt is unrecognized; detector spits it into leftovers.
        XCTAssertEqual(plan.standaloneMediaURLs.map(\.lastPathComponent), ["README.txt"])
    }

    func testPlanSeparatesMultipleSequencesAndStandaloneMedia() throws {
        try touch("shotA.0001.png")
        try touch("shotA.0002.png")
        try touch("shotB.0001.exr")
        try touch("shotB.0002.exr")
        try touch("hero.mov")
        try touch("logo.png")  // singleton — not a sequence

        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)

        XCTAssertEqual(plan.sequences.count, 2)
        let baseNames = Set(plan.sequences.map(\.baseName))
        XCTAssertEqual(baseNames, ["shotA", "shotB"])
        let standaloneNames = Set(plan.standaloneMediaURLs.map(\.lastPathComponent))
        XCTAssertEqual(standaloneNames, ["hero.mov", "logo.png"])
    }

    func testPlanSkipsHiddenFiles() throws {
        try touch(".DS_Store")
        try touch("shot.0001.png")
        try touch("shot.0002.png")

        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)

        XCTAssertEqual(plan.sequences.count, 1)
        // .DS_Store must not appear in standaloneMediaURLs — operators should never see
        // ".DS_Store: unsupported media" in the import banner from a folder drop.
        XCTAssertFalse(plan.standaloneMediaURLs.contains { $0.lastPathComponent == ".DS_Store" })
    }

    func testPlanDoesNotRecurseIntoSubfolders() throws {
        let nested = workingDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try touch("shot.0001.png")
        try touch("shot.0002.png")
        try touch("nested/inner.0001.png")
        try touch("nested/inner.0002.png")

        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)

        XCTAssertEqual(plan.sequences.count, 1, "Subfolders should not be recursed into.")
        XCTAssertEqual(plan.sequences.first?.baseName, "shot")
        // The `nested` directory itself appears as a leftover URL via contentsOfDirectory.
        // That's harmless — MediaImporter would reject it as unsupported, surfacing in the
        // banner once C5c-b kicks off the import. Tests don't pin the leftover shape.
    }

    func testPlanReturnsEmptyForEmptyFolder() throws {
        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)
        XCTAssertEqual(plan, .empty)
    }

    func testPlanThrowsForMissingFolder() {
        let bogus = workingDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertThrowsError(try AddFolderImporter.plan(folderURL: bogus))
    }

    func testPlanProducesDeterministicOrdering() throws {
        // Filesystem enumeration order is not guaranteed; the importer normalizes by
        // last-path-component so the operator sees a stable list in the sheet.
        try touch("zebra.0001.png")
        try touch("zebra.0002.png")
        try touch("alpha.0001.png")
        try touch("alpha.0002.png")

        let plan = try AddFolderImporter.plan(folderURL: workingDirectory)

        let names = plan.sequences.map(\.baseName)
        XCTAssertEqual(names, ["alpha", "zebra"])
    }

    // MARK: -

    private func touch(_ relativePath: String) throws {
        let url = workingDirectory.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
