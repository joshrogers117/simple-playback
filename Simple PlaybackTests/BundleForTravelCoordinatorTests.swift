import Foundation
import XCTest
@testable import Simple_Playback

@MainActor
final class BundleForTravelCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        BundleForTravelCoordinator.copyFile = { _, _ in }
        BundleForTravelCoordinator.ensureDirectory = { _ in }
        BundleForTravelCoordinator.removeItem = { _ in }
    }

    override func tearDown() async throws {
        BundleForTravelCoordinator.copyFile = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        BundleForTravelCoordinator.ensureDirectory = { url in
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        BundleForTravelCoordinator.removeItem = { url in
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    func testEmptyPlanFinishesImmediately() {
        let coordinator = BundleForTravelCoordinator()
        let exp = expectation(description: "completion")
        var observed: Result<BundleForTravelPlanReport, BundleForTravelError>?

        coordinator.start(
            plan: .empty,
            mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")
        ) { result in
            observed = result
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)

        if case .success(let report) = observed {
            XCTAssertEqual(report, .empty)
        } else {
            XCTFail("Expected immediate success for empty plan.")
        }
        if case .finished(let report) = coordinator.state {
            XCTAssertEqual(report, .empty)
        } else {
            XCTFail("Expected finished state.")
        }
    }

    func testRunCopiesEachOperationToBundleMediaDirectory() async {
        let coordinator = BundleForTravelCoordinator()
        let mediaDir = URL(fileURLWithPath: "/bundle/Media")
        let plan = BundleForTravelPlanReport(
            operations: [
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/Footage/intro.mov"),
                    destinationFilename: "intro.mov"
                ),
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/Footage/outro.mov"),
                    destinationFilename: "outro.mov"
                )
            ],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 100
        )

        var copies: [(URL, URL)] = []
        BundleForTravelCoordinator.copyFile = { src, dst in
            copies.append((src, dst))
        }

        let exp = expectation(description: "completion")
        coordinator.start(plan: plan, mediaDirectoryURL: mediaDir) { _ in
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies[0].0.path, "/Footage/intro.mov")
        XCTAssertEqual(copies[0].1.path, "/bundle/Media/intro.mov")
        XCTAssertEqual(copies[1].1.path, "/bundle/Media/outro.mov")
    }

    func testFailedDirectoryPreparationAbortsAndDoesNotCopy() async {
        let coordinator = BundleForTravelCoordinator()
        BundleForTravelCoordinator.ensureDirectory = { _ in
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"])
        }
        var copyCount = 0
        BundleForTravelCoordinator.copyFile = { _, _ in copyCount += 1 }

        let plan = BundleForTravelPlanReport(
            operations: [BundleForTravelOperation(
                slideID: UUID(),
                sourceURL: URL(fileURLWithPath: "/x/a.mov"),
                destinationFilename: "a.mov"
            )],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        let exp = expectation(description: "completion")
        var observed: Result<BundleForTravelPlanReport, BundleForTravelError>?
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { result in
            observed = result
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(copyCount, 0,
                       "No copies should run if Media/ couldn't be prepared.")
        if case .failure(let err) = observed,
           case .mediaDirectoryUnwriteable = err {
            // expected
        } else {
            XCTFail("Expected mediaDirectoryUnwriteable failure, got \(String(describing: observed))")
        }
        if case .failed(.mediaDirectoryUnwriteable) = coordinator.state {
            // expected
        } else {
            XCTFail("Expected failed state, got \(coordinator.state)")
        }
    }

    func testFailedCopyClearsPartialDestinationBeforeReportingFailure() async {
        // FileManager.copyItem can leave a partial file at the destination when
        // it throws (out-of-space, source vanished mid-copy). The coordinator
        // must call removeItem on the failure path so a retry isn't blocked
        // and the bundle isn't littered with truncated files.
        let coordinator = BundleForTravelCoordinator()
        var removeCalls: [URL] = []
        BundleForTravelCoordinator.copyFile = { _, _ in
            throw NSError(domain: "Test", code: 28, userInfo: [NSLocalizedDescriptionKey: "no space left"])
        }
        BundleForTravelCoordinator.removeItem = { url in
            removeCalls.append(url)
        }

        let plan = BundleForTravelPlanReport(
            operations: [
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/x/a.mov"),
                    destinationFilename: "a.mov"
                )
            ],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        let exp = expectation(description: "completion")
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { _ in
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)

        let destination = URL(fileURLWithPath: "/bundle/Media/a.mov")
        // Pre-copy clear-stale + post-failure cleanup both target the same URL,
        // so two removeItem calls is the documented contract.
        XCTAssertEqual(removeCalls.count, 2,
                       "removeItem must be called pre-copy (clear stale) AND post-failure (clean partial).")
        XCTAssertEqual(removeCalls.last?.standardizedFileURL, destination.standardizedFileURL)
    }

    func testFailedCopyHaltsRemainingOperations() async {
        let coordinator = BundleForTravelCoordinator()
        var attempts = 0
        BundleForTravelCoordinator.copyFile = { _, _ in
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
        }

        let plan = BundleForTravelPlanReport(
            operations: [
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/x/a.mov"),
                    destinationFilename: "a.mov"
                ),
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/x/b.mov"),
                    destinationFilename: "b.mov"
                )
            ],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        let exp = expectation(description: "completion")
        var observed: Result<BundleForTravelPlanReport, BundleForTravelError>?
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { result in
            observed = result
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(attempts, 1,
                       "Failed copy should abort the rest of the pass.")
        if case .failure(let err) = observed, case .copyFailed = err {
            // expected
        } else {
            XCTFail("Expected copyFailed failure.")
        }
    }

    func testCancelDuringRunHaltsRemainingOperationsAndReportsCancelled() async {
        // Use a long-running copy that we can cancel between operations. Because
        // copyFile is called on the MainActor, we cancel from inside the closure
        // for the first op so the second never runs.
        let coordinator = BundleForTravelCoordinator()

        var attempts = 0
        BundleForTravelCoordinator.copyFile = { _, _ in
            attempts += 1
            if attempts == 1 {
                coordinator.cancel()
            }
        }

        let plan = BundleForTravelPlanReport(
            operations: [
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/x/a.mov"),
                    destinationFilename: "a.mov"
                ),
                BundleForTravelOperation(
                    slideID: UUID(),
                    sourceURL: URL(fileURLWithPath: "/x/b.mov"),
                    destinationFilename: "b.mov"
                )
            ],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        let exp = expectation(description: "completion")
        var observed: Result<BundleForTravelPlanReport, BundleForTravelError>?
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { result in
            observed = result
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(attempts, 1)
        if case .failure(.cancelled) = observed {
            // expected
        } else {
            XCTFail("Expected cancelled failure.")
        }
        XCTAssertEqual(coordinator.state, .cancelled)
    }

    func testStartIsNoOpWhileRunning() {
        let coordinator = BundleForTravelCoordinator()
        // Force the coordinator into running by injecting a never-completing
        // copy; the second start() must be ignored without invoking either
        // copy or completion.
        BundleForTravelCoordinator.copyFile = { _, _ in
            // No-op — but the state.isRunning predicate is only true between
            // start() and completion. Since the closure runs synchronously
            // here, we'll observe state after kickoff and use a separate plan
            // that's already started.
        }

        // Create a non-empty plan and call start once. Capture state.
        let plan = BundleForTravelPlanReport(
            operations: [BundleForTravelOperation(
                slideID: UUID(),
                sourceURL: URL(fileURLWithPath: "/x/a.mov"),
                destinationFilename: "a.mov"
            )],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        var firstCompletions = 0
        var secondCompletions = 0
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { _ in
            firstCompletions += 1
        }
        // The first start completes synchronously (Task @MainActor still
        // serializes through main actor — the completion will run after this
        // method returns control). To exercise the "no-op while running"
        // branch, we synthesize the running state manually via a second start
        // before yielding.
        coordinator.start(plan: plan, mediaDirectoryURL: URL(fileURLWithPath: "/bundle/Media")) { _ in
            secondCompletions += 1
        }

        // Drain the main queue so the first run can complete.
        let exp = expectation(description: "drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertGreaterThanOrEqual(firstCompletions, 1,
                                    "First run should always complete.")
        XCTAssertEqual(secondCompletions, 0,
                       "Second start while running must be a no-op.")
    }
}
