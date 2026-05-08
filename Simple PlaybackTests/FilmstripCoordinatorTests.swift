import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

@MainActor
final class FilmstripCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Default stubs that succeed quickly without filesystem I/O.
        FilmstripCoordinator.generator = { _, _, _, _ in Data([0x89, 0x50, 0x4E, 0x47]) }
        FilmstripCoordinator.writer = { _, _ in }
    }

    override func tearDown() async throws {
        FilmstripCoordinator.generator = { url, count, cols, size in
            try await FilmstripGenerator.generateSpriteSheet(
                for: url,
                frameCount: count,
                columns: cols,
                frameSize: size
            )
        }
        FilmstripCoordinator.writer = { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        try await super.tearDown()
    }

    func testEnqueueCallsGeneratorAndWriterAndCompletesWithDestination() async {
        nonisolated(unsafe) var generatorCallCount = 0
        nonisolated(unsafe) var writerCalls: [(Int, URL)] = []
        FilmstripCoordinator.generator = { _, count, _, _ in
            generatorCallCount += 1
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        FilmstripCoordinator.writer = { data, url in
            writerCalls.append((data.count, url))
        }

        let coordinator = FilmstripCoordinator()
        let dest = URL(fileURLWithPath: "/tmp/Filmstrips/abc.png")
        let exp = expectation(description: "completion")
        var observed: FilmstripCoordinator.Outcome?
        coordinator.enqueue(
            slideID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/source.mov"),
            destinationURL: dest
        ) { outcome in
            observed = outcome
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(generatorCallCount, 1)
        XCTAssertEqual(writerCalls.count, 1)
        XCTAssertEqual(writerCalls.first?.1, dest)
        XCTAssertEqual(observed, .completed(dest))
        XCTAssertTrue(coordinator.jobs.isEmpty,
                      "Completed job must be removed from the running-jobs list.")
    }

    func testEnqueueIsNoOpWhenJobAlreadyRunningForSameSlide() async {
        nonisolated(unsafe) var generatorCallCount = 0
        // Block the generator until the test releases it so the first job
        // remains in the running-jobs list during the second enqueue call.
        let gate = AsyncSemaphore()
        FilmstripCoordinator.generator = { _, _, _, _ in
            gate.wait()
            generatorCallCount += 1
            return Data([0x89, 0x50, 0x4E, 0x47])
        }

        let coordinator = FilmstripCoordinator()
        let slideID = UUID()
        let firstExp = expectation(description: "first completion")
        coordinator.enqueue(
            slideID: slideID,
            sourceURL: URL(fileURLWithPath: "/x/a.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/a.png")
        ) { _ in firstExp.fulfill() }

        // Wait for the first job to be on the running list.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(coordinator.isRunning(slideID: slideID))

        // Repeated enqueue for the same slide while running — must no-op.
        var secondCompletionFired = false
        coordinator.enqueue(
            slideID: slideID,
            sourceURL: URL(fileURLWithPath: "/x/a.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/a.png")
        ) { _ in secondCompletionFired = true }

        gate.signal()
        await fulfillment(of: [firstExp], timeout: 2.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(generatorCallCount, 1,
                       "Repeated enqueue while running must not stack a second extraction.")
        XCTAssertFalse(secondCompletionFired,
                       "Repeated enqueue while running must not fire a phantom completion.")
    }

    func testGeneratorFailureReportsFailedOutcomeAndDropsJob() async {
        FilmstripCoordinator.generator = { _, _, _, _ in
            throw FilmstripGenerator.Failure.durationUnknown
        }

        let coordinator = FilmstripCoordinator()
        let exp = expectation(description: "completion")
        var observed: FilmstripCoordinator.Outcome?
        coordinator.enqueue(
            slideID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/bad.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/bad.png")
        ) { outcome in
            observed = outcome
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(observed, .failed(.durationUnknown))
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    func testWriterFailureMapsToEncodingFailedOutcome() async {
        FilmstripCoordinator.writer = { _, _ in
            throw NSError(domain: "Test", code: 28, userInfo: [NSLocalizedDescriptionKey: "no space"])
        }

        let coordinator = FilmstripCoordinator()
        let exp = expectation(description: "completion")
        var observed: FilmstripCoordinator.Outcome?
        coordinator.enqueue(
            slideID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/a.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/a.png")
        ) { outcome in
            observed = outcome
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(observed, .failed(.encodingFailed))
    }

    func testDistinctSlideIDsRunConcurrently() async {
        nonisolated(unsafe) var generatorCallCount = 0
        let gate = AsyncSemaphore()
        FilmstripCoordinator.generator = { _, _, _, _ in
            gate.wait()
            generatorCallCount += 1
            return Data([0x89, 0x50, 0x4E, 0x47])
        }

        let coordinator = FilmstripCoordinator()
        let slideA = UUID()
        let slideB = UUID()

        let firstExp = expectation(description: "A completes")
        let secondExp = expectation(description: "B completes")
        coordinator.enqueue(
            slideID: slideA,
            sourceURL: URL(fileURLWithPath: "/x/a.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/a.png")
        ) { _ in firstExp.fulfill() }
        coordinator.enqueue(
            slideID: slideB,
            sourceURL: URL(fileURLWithPath: "/x/b.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/b.png")
        ) { _ in secondExp.fulfill() }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.jobs.count, 2,
                       "Distinct slide IDs must each produce a running job.")

        gate.signal()
        gate.signal()
        await fulfillment(of: [firstExp, secondExp], timeout: 2.0)
        XCTAssertEqual(generatorCallCount, 2)
    }
}

/// Minimal binary semaphore for orchestrating concurrent stub invocations
/// in coordinator tests. Mirrors a `DispatchSemaphore` interface but
/// avoids blocking the test thread on a real wait/signal pair when the
/// generator stub is called from a `Task.detached`.
private final class AsyncSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func signal() { semaphore.signal() }
}
