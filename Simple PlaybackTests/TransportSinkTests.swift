import Foundation
import XCTest
@testable import Simple_Playback

final class TransportSinkTests: XCTestCase {

    // MARK: - TransportSinkStage

    func testStageDerivesRasterAndFrameRateFromStageValue() {
        let stage = Stage(name: "Program", width: 3840, height: 2160, frameRateNumerator: 60_000, frameRateDenominator: 1001)
        let sinkStage = TransportSinkStage(stage: stage)
        XCTAssertEqual(sinkStage.width, 3840)
        XCTAssertEqual(sinkStage.height, 2160)
        XCTAssertEqual(sinkStage.size, CGSize(width: 3840, height: 2160))
        XCTAssertEqual(sinkStage.framesPerSecond, 60_000.0 / 1001.0, accuracy: 0.0001)
    }

    func testStageFrameIntervalClampsAt60FPS() {
        let veryFast = TransportSinkStage(width: 1920, height: 1080, frameRateNumerator: 240, frameRateDenominator: 1)
        XCTAssertEqual(veryFast.frameInterval, 1.0 / 60.0, accuracy: 0.0001,
                       "Frame interval should not drop below 1/60 — protects the output queue from busy-loop scheduling.")
    }

    func testStageHandlesZeroDenominatorGracefully() {
        let bogus = TransportSinkStage(width: 100, height: 100, frameRateNumerator: 30, frameRateDenominator: 0)
        XCTAssertEqual(bogus.framesPerSecond, 60, "Default of 60 FPS protects callers from divide-by-zero.")
    }

    // MARK: - PreviewTransportSink

    func testPreviewSinkLifecycleAndStatusTransitions() throws {
        let sink = PreviewTransportSink()
        XCTAssertFalse(sink.isRunning)
        XCTAssertEqual(sink.status, "Software preview output")

        let stage = TransportSinkStage(width: 1920, height: 1080, frameRateNumerator: 30, frameRateDenominator: 1)
        try sink.start(stage: stage)
        XCTAssertTrue(sink.isRunning)
        XCTAssertEqual(sink.status, "Software preview running")
        XCTAssertEqual(sink.activeStage, stage)

        sink.stop()
        XCTAssertFalse(sink.isRunning)
        XCTAssertNil(sink.activeStage)
        XCTAssertEqual(sink.status, "Software preview output")
    }

    func testPreviewSinkStopIsIdempotent() {
        let sink = PreviewTransportSink()
        sink.stop()
        sink.stop()
        XCTAssertFalse(sink.isRunning)
    }

    // MARK: - TransportSinkRouter

    func testRouterFansFrameOutToAllRunningSinks() throws {
        let router = TransportSinkRouter()
        let a = MockTransportSink(sinkID: "a")
        let b = MockTransportSink(sinkID: "b")
        let stage = TransportSinkStage(width: 1920, height: 1080, frameRateNumerator: 30, frameRateDenominator: 1)
        try a.start(stage: stage)
        try b.start(stage: stage)
        router.setSinks([a, b])

        let frame = RenderedFrame(data: Data([1, 2, 3, 4]), width: 1, height: 1, rowBytes: 4)
        let errors = router.submit(frame: frame)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(a.framesSubmitted.count, 1)
        XCTAssertEqual(b.framesSubmitted.count, 1)
    }

    func testRouterSkipsSinksThatHaveNotStarted() {
        let router = TransportSinkRouter()
        let a = MockTransportSink(sinkID: "a")
        router.setSinks([a])
        let frame = RenderedFrame(data: Data(), width: 1, height: 1, rowBytes: 4)
        router.submit(frame: frame)
        XCTAssertEqual(a.framesSubmitted.count, 0,
                       "Idle sink should not see frames — frames are only delivered between start() and stop().")
    }

    func testRouterCapturesPerSinkErrorsWithoutKillingOthers() throws {
        let router = TransportSinkRouter()
        let healthy = MockTransportSink(sinkID: "healthy")
        let broken = MockTransportSink(sinkID: "broken")
        broken.frameError = NSError(domain: "test", code: 1)
        let stage = TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1)
        try healthy.start(stage: stage)
        try broken.start(stage: stage)
        router.setSinks([healthy, broken])

        let frame = RenderedFrame(data: Data(), width: 1, height: 1, rowBytes: 4)
        let errors = router.submit(frame: frame)

        XCTAssertEqual(Array(errors.keys), ["broken"])
        XCTAssertEqual(healthy.framesSubmitted.count, 1, "A failing sink must not block siblings.")
        XCTAssertEqual(router.lastErrors.count, 1)
    }

    func testRouterStopsRemovedSinksOnSetSinks() throws {
        let router = TransportSinkRouter()
        let a = MockTransportSink(sinkID: "a")
        try a.start(stage: TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1))
        router.setSinks([a])
        router.setSinks([])
        XCTAssertFalse(a.isRunning, "setSinks([]) should stop sinks that are no longer registered.")
    }

    func testRouterRemoveSinkStopsIt() throws {
        let router = TransportSinkRouter()
        let a = MockTransportSink(sinkID: "a")
        try a.start(stage: TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1))
        router.addSink(a)
        router.removeSink(a)
        XCTAssertFalse(a.isRunning)
    }

    func testRouterAudioFanOut() throws {
        let router = TransportSinkRouter()
        let a = MockTransportSink(sinkID: "a")
        try a.start(stage: TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1))
        router.setSinks([a])
        let pcm = Data(count: 480 * 4)
        let errors = router.submit(audio: pcm, sampleFrameCount: 480)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(a.audioSubmitted.count, 1)
        XCTAssertEqual(a.audioSubmitted.first?.sampleFrameCount, 480)
    }

    func testRouterStopAllStopsEverySink() throws {
        let router = TransportSinkRouter()
        let stage = TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1)
        let a = MockTransportSink(sinkID: "a")
        let b = MockTransportSink(sinkID: "b")
        try a.start(stage: stage)
        try b.start(stage: stage)
        router.setSinks([a, b])
        router.stopAll()
        XCTAssertFalse(a.isRunning)
        XCTAssertFalse(b.isRunning)
    }

    // MARK: - PlaybackController auxiliary sink integration

    func testSinkRegisteredBeforeOutputStartsRemainsIdle() {
        let controller = PlaybackController()
        let aux = MockTransportSink(sinkID: "aux")
        controller.register(sink: aux)
        XCTAssertFalse(aux.isRunning,
                       "A sink registered before any output starts must stay idle until the controller starts.")
        controller.unregister(sink: aux)
    }

    // MARK: - DeckLink reference state

    func testReferenceStateLabels() {
        XCTAssertEqual(DeckLinkTransportSink.ReferenceState.idle.label, "Idle")
        XCTAssertEqual(DeckLinkTransportSink.ReferenceState.notSupported.label, "Not supported")
        XCTAssertEqual(DeckLinkTransportSink.ReferenceState.unlocked.label, "Free-run")
        XCTAssertEqual(DeckLinkTransportSink.ReferenceState.locked.label, "Locked")
    }

    func testIdleSinkReferenceStateIsIdle() {
        let sink = DeckLinkTransportSink(deviceID: "fake-device", modeID: "fake-mode")
        // Sink is constructed but never started; bridge has no active output.
        XCTAssertEqual(sink.referenceState, .idle,
                       "Without an active output, REF state must be reported as idle (not silently 'locked').")
    }

    func testPreviewDriverHasNoDeckLinkReferenceState() {
        let driver = PreviewVideoOutputDriver()
        XCTAssertNil(driver.deckLinkReferenceState,
                     "Software preview is not a DeckLink — REF state must be nil.")
    }

    func testUnregisteringSinkStopsItEvenWithoutOutput() throws {
        let controller = PlaybackController()
        let aux = MockTransportSink(sinkID: "aux")
        try aux.start(stage: TransportSinkStage(width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1))
        controller.register(sink: aux)
        controller.unregister(sink: aux)
        XCTAssertFalse(aux.isRunning, "unregister(sink:) must stop the sink unconditionally.")
    }
}

// MARK: - Test fixtures

final class MockTransportSink: TransportSink {
    let sinkID: String
    let label: String
    private(set) var status: String = "idle"
    private(set) var isRunning: Bool = false
    private(set) var activeStage: TransportSinkStage?

    var startError: Error?
    var frameError: Error?
    var audioError: Error?

    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0
    private(set) var framesSubmitted: [RenderedFrame] = []
    private(set) var audioSubmitted: [(data: Data, sampleFrameCount: Int)] = []

    init(sinkID: String, label: String? = nil) {
        self.sinkID = sinkID
        self.label = label ?? sinkID
    }

    func start(stage: TransportSinkStage) throws {
        if let startError { throw startError }
        startCount += 1
        isRunning = true
        activeStage = stage
        status = "running"
    }

    func stop() {
        guard isRunning else { return }
        stopCount += 1
        isRunning = false
        activeStage = nil
        status = "stopped"
    }

    func submit(frame: RenderedFrame) throws {
        if let frameError { throw frameError }
        framesSubmitted.append(frame)
    }

    func submit(audio: Data, sampleFrameCount: Int) throws {
        if let audioError { throw audioError }
        audioSubmitted.append((audio, sampleFrameCount))
    }
}
