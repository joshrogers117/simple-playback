import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

final class ModelTests: XCTestCase {
    func testProjectDocumentTypeUsesSPBAsPrimaryExtension() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let projectType = try XCTUnwrap(declarations.first { declaration in
            declaration["UTTypeIdentifier"] as? String == "com.josh.simpleplayback.project"
        })
        let tagSpecification = try XCTUnwrap(projectType["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try XCTUnwrap(tagSpecification["public.filename-extension"] as? [String])

        XCTAssertEqual(extensions.first, "spb")
        XCTAssertTrue(extensions.contains("splayback"))
    }

    func testProjectDocumentTypeRegistersNSDocumentClass() throws {
        let documentTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let projectType = try XCTUnwrap(documentTypes.first { documentType in
            documentType["CFBundleTypeName"] as? String == "Simple Playback Project"
        })
        let documentClassName = try XCTUnwrap(projectType["NSDocumentClass"] as? String)

        XCTAssertTrue(documentClassName.hasSuffix(".SimplePlaybackProjectDocument"))
        XCTAssertNotNil(NSClassFromString(documentClassName) as? NSDocument.Type)
    }

    func testStartupProjectLaunchUsesFirstExistingRecentProject() {
        let missingProject = URL(fileURLWithPath: "/tmp/missing-project.spb")
        let existingProject = URL(fileURLWithPath: "/tmp/existing-project.spb")
        let olderProject = URL(fileURLWithPath: "/tmp/older-project.spb")

        let selectedURL = StartupProjectLaunch.firstExistingRecentProjectURL(
            from: [missingProject, existingProject, olderProject],
            fileExists: { $0 == existingProject || $0 == olderProject }
        )

        XCTAssertEqual(selectedURL, existingProject)
    }

    func testProjectRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        var slide = MediaSlide(url: url, mediaKind: .video)
        slide.title = "Countdown"
        slide.settings.scaleMode = .fill
        slide.settings.loopVideo = true
        slide.settings.volume = 0.42

        let project = PlayoutProject(
            slides: [slide],
            selectedDeviceID: "preview:software",
            selectedModeID: "preview-mode:1080p30",
            outputWidth: 1920,
            outputHeight: 1080,
            transitionSettings: PlayoutTransitionSettings(crossfadeEnabled: true, crossfadeDuration: 1.2)
        )

        let data = try JSONEncoder.simplePlayback.encode(project)
        let decoded = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)

        XCTAssertEqual(decoded.slides.count, 1)
        XCTAssertEqual(decoded.slides[0].title, "Countdown")
        XCTAssertEqual(decoded.slides[0].mediaKind, .video)
        XCTAssertEqual(decoded.slides[0].settings.scaleMode, .fill)
        XCTAssertEqual(decoded.slides[0].settings.volume, 0.42, accuracy: 0.001)
        XCTAssertEqual(decoded.selectedDeviceID, "preview:software")
        XCTAssertTrue(decoded.transitionSettings.crossfadeEnabled)
        XCTAssertEqual(decoded.transitionSettings.crossfadeDuration, 1.2, accuracy: 0.001)
    }

    func testProjectFormatVersionDefaultsToCurrentForFreshProjects() {
        let project = PlayoutProject()
        XCTAssertEqual(project.formatVersion, PlayoutProject.currentFormatVersion)
    }

    func testProjectFormatVersionDefaultsToOneWhenAbsentInJSON() throws {
        let legacyJSON = """
        {
          "slides": [],
          "outputWidth": 1920,
          "outputHeight": 1080
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let project = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
        XCTAssertEqual(project.formatVersion, 1)
    }

    func testMarkCurrentFormatVersionUpgradesLegacyProject() {
        var legacy = PlayoutProject(formatVersion: 1)
        XCTAssertEqual(legacy.formatVersion, 1)
        legacy.markCurrentFormatVersion()
        XCTAssertEqual(legacy.formatVersion, PlayoutProject.currentFormatVersion)
    }

    func testProjectBundleRoundTripsThroughFileWrapper() throws {
        let project = PlayoutProject(
            slides: [],
            selectedDeviceID: "preview:software",
            selectedModeID: "preview-mode:1080p30",
            outputWidth: 1920,
            outputHeight: 1080,
            transitionSettings: PlayoutTransitionSettings(crossfadeEnabled: true, crossfadeDuration: 0.75)
        )

        let data = try JSONEncoder.simplePlayback.encode(project)
        let projectWrapper = FileWrapper(regularFileWithContents: data)
        projectWrapper.preferredFilename = ProjectBundleLayout.projectFilename
        let bundleWrapper = FileWrapper(directoryWithFileWrappers: [
            ProjectBundleLayout.projectFilename: projectWrapper
        ])

        let extracted = try SimplePlaybackProjectDocument.projectData(from: bundleWrapper)
        let decoded = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: extracted)
        XCTAssertEqual(decoded.formatVersion, PlayoutProject.currentFormatVersion)
        XCTAssertEqual(decoded.selectedDeviceID, "preview:software")
        XCTAssertTrue(decoded.transitionSettings.crossfadeEnabled)
    }

    func testProjectReaderAcceptsLegacyFlatFileWrapper() throws {
        let legacyJSON = """
        {
          "slides": [],
          "selectedDeviceID": "legacy:device",
          "outputWidth": 1280,
          "outputHeight": 720,
          "transitionSettings": { "crossfadeEnabled": false, "crossfadeDuration": 0.5 }
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let flatWrapper = FileWrapper(regularFileWithContents: data)
        let extracted = try SimplePlaybackProjectDocument.projectData(from: flatWrapper)
        let decoded = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: extracted)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.selectedDeviceID, "legacy:device")
        XCTAssertEqual(decoded.outputWidth, 1280)
        XCTAssertEqual(decoded.outputHeight, 720)
    }

    func testMarkCurrentFormatVersionEnsuresAtLeastOneShowList() {
        var project = PlayoutProject()
        XCTAssertTrue(project.showLists.isEmpty)
        project.markCurrentFormatVersion()
        XCTAssertEqual(project.showLists.count, 1)
        XCTAssertEqual(project.showLists.first?.name, "Show 1")
        XCTAssertEqual(project.activeShowListID, project.showLists.first?.id)
    }

    func testMarkCurrentFormatVersionResetsUnknownActiveShowListID() {
        let realList = ShowList(name: "A")
        var project = PlayoutProject(showLists: [realList], activeShowListID: UUID())
        project.markCurrentFormatVersion()
        XCTAssertEqual(project.activeShowListID, realList.id)
    }

    func testActiveShowListFallsBackToFirstWhenIDIsNil() {
        let listA = ShowList(name: "A")
        let listB = ShowList(name: "B")
        let project = PlayoutProject(showLists: [listA, listB], activeShowListID: nil)
        XCTAssertEqual(project.activeShowList?.id, listA.id)
    }

    func testGenerateDefaultShowListCreatesOneCuePerSlide() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let slide1 = MediaSlide(url: url, mediaKind: .image)
        let slide2 = MediaSlide(url: url, mediaKind: .image)
        var project = PlayoutProject(slides: [slide1, slide2])
        project.generateDefaultShowList()

        let list = try XCTUnwrap(project.showLists.first)
        XCTAssertEqual(list.cues.count, 2)
        XCTAssertEqual(list.cues[0].number, "1")
        XCTAssertEqual(list.cues[1].number, "2")
        XCTAssertEqual(list.cues[0].assetID, slide1.id)
        XCTAssertEqual(list.cues[1].assetID, slide2.id)
        XCTAssertEqual(project.activeShowListID, list.id)
    }

    func testProjectReaderRejectsBundleWithMissingProjectFile() {
        let stray = FileWrapper(regularFileWithContents: Data("hello".utf8))
        stray.preferredFilename = "notes.txt"
        let bundleWrapper = FileWrapper(directoryWithFileWrappers: ["notes.txt": stray])
        XCTAssertThrowsError(try SimplePlaybackProjectDocument.projectData(from: bundleWrapper))
    }

    // MARK: - Cue model (A2 / A3)

    func testCueDefaultsToHoldContinuationAndZeroWaits() {
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        XCTAssertEqual(cue.continuation, .hold)
        XCTAssertEqual(cue.preWait, 0)
        XCTAssertEqual(cue.postWait, 0)
        XCTAssertEqual(cue.notes, "")
        XCTAssertTrue(cue.overrides.isEmpty)
    }

    func testCueOverridesEmptyByDefaultAndDetectsAnyField() {
        var overrides = CueOverrides()
        XCTAssertTrue(overrides.isEmpty)
        overrides.fadeIn = 1.0
        XCTAssertFalse(overrides.isEmpty)

        var overrides2 = CueOverrides()
        overrides2.holdLastFrame = true
        XCTAssertFalse(overrides2.isEmpty)

        var overrides3 = CueOverrides()
        overrides3.inPoint = 2.5
        XCTAssertFalse(overrides3.isEmpty)
    }

    func testCueRoundTripsThroughJSONPreservingAllFields() throws {
        let assetID = UUID()
        let cueID = UUID()
        var overrides = CueOverrides()
        overrides.fadeIn = 0.4
        overrides.crossfadeDuration = 1.2
        overrides.holdLastFrame = true
        overrides.loop = false
        overrides.inPoint = 3.0
        overrides.outPoint = 12.5

        let cue = Cue(
            id: cueID,
            number: "Q12.5",
            title: "Sponsor Reel",
            assetID: assetID,
            continuation: .autoContinue,
            preWait: 0.5,
            postWait: 1.0,
            notes: "wait for VO",
            overrides: overrides
        )

        let data = try JSONEncoder.simplePlayback.encode(cue)
        let decoded = try JSONDecoder.simplePlayback.decode(Cue.self, from: data)

        XCTAssertEqual(decoded.id, cueID)
        XCTAssertEqual(decoded.number, "Q12.5")
        XCTAssertEqual(decoded.title, "Sponsor Reel")
        XCTAssertEqual(decoded.assetID, assetID)
        XCTAssertEqual(decoded.continuation, .autoContinue)
        XCTAssertEqual(decoded.preWait, 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded.postWait, 1.0, accuracy: 0.001)
        XCTAssertEqual(decoded.notes, "wait for VO")
        XCTAssertEqual(decoded.overrides.fadeIn, 0.4)
        XCTAssertEqual(decoded.overrides.crossfadeDuration, 1.2)
        XCTAssertEqual(decoded.overrides.holdLastFrame, true)
        XCTAssertEqual(decoded.overrides.loop, false)
        XCTAssertEqual(decoded.overrides.inPoint, 3.0)
        XCTAssertEqual(decoded.overrides.outPoint, 12.5)
    }

    func testCueDecodesWithMissingOptionalFields() throws {
        let assetID = UUID()
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "number": "1",
          "assetID": "\(assetID.uuidString)"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder.simplePlayback.decode(Cue.self, from: data)
        XCTAssertEqual(decoded.number, "1")
        XCTAssertEqual(decoded.title, "")
        XCTAssertEqual(decoded.continuation, .hold)
        XCTAssertEqual(decoded.preWait, 0)
        XCTAssertEqual(decoded.postWait, 0)
        XCTAssertEqual(decoded.notes, "")
        XCTAssertTrue(decoded.overrides.isEmpty)
    }

    func testCueContinuationHasAllExpectedCases() {
        XCTAssertEqual(CueContinuation.allCases, [.hold, .autoContinue, .autoFollow])
        XCTAssertEqual(CueContinuation.hold.label, "Hold")
        XCTAssertEqual(CueContinuation.autoContinue.label, "Auto-continue")
        XCTAssertEqual(CueContinuation.autoFollow.label, "Auto-follow")
    }

    // MARK: - ShowList (A4a)

    func testEmptyShowListHasNoPlayhead() {
        let list = ShowList()
        XCTAssertNil(list.playheadCue)
        XCTAssertNil(list.playheadIndex)
        XCTAssertNil(list.nextCueAfterPlayhead)
        XCTAssertTrue(list.isValid)
    }

    func testShowListInitializesPlayheadToFirstCue() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let list = ShowList(cues: [cueA, cueB])
        XCTAssertEqual(list.playheadCue?.id, cueA.id)
        XCTAssertEqual(list.playheadIndex, 0)
        XCTAssertEqual(list.nextCueAfterPlayhead?.id, cueB.id)
    }

    func testShowListLooksUpCueByNumberCaseInsensitively() {
        let asset = UUID()
        let intro = Cue(number: "INTRO", title: "Intro", assetID: asset)
        let bumper = Cue(number: "Q12.5", title: "Bumper", assetID: asset)
        let list = ShowList(cues: [intro, bumper])

        XCTAssertEqual(list.cue(number: "intro")?.id, intro.id)
        XCTAssertEqual(list.cue(number: "Intro")?.id, intro.id)
        XCTAssertEqual(list.cue(number: "INTRO")?.id, intro.id)
        XCTAssertEqual(list.cue(number: "q12.5")?.id, bumper.id)
        XCTAssertNil(list.cue(number: "missing"))
    }

    func testShowListAppendRejectsDuplicateNumberCaseInsensitively() throws {
        let asset = UUID()
        var list = ShowList()
        try list.append(Cue(number: "INTRO", title: "Intro", assetID: asset))
        XCTAssertThrowsError(try list.append(Cue(number: "intro", title: "Dup", assetID: asset))) { error in
            guard case ShowListValidationError.duplicateCueNumber(let number) = error else {
                XCTFail("Expected duplicateCueNumber, got \(error)")
                return
            }
            XCTAssertEqual(number, "intro")
        }
        XCTAssertEqual(list.cues.count, 1)
    }

    func testShowListAppendRejectsEmptyOrWhitespaceCueNumber() {
        var list = ShowList()
        XCTAssertThrowsError(try list.append(Cue(number: "", title: "Bad", assetID: UUID())))
        XCTAssertThrowsError(try list.append(Cue(number: "   ", title: "Bad", assetID: UUID())))
        XCTAssertTrue(list.cues.isEmpty)
    }

    func testShowListValidateReportsAllDuplicates() {
        let asset = UUID()
        let list = ShowList(cues: [
            Cue(number: "1", title: "a", assetID: asset),
            Cue(number: "1", title: "b", assetID: asset),
            Cue(number: "Intro", title: "c", assetID: asset),
            Cue(number: "INTRO", title: "d", assetID: asset)
        ])
        let errors = list.validate()
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.contains(.duplicateCueNumber("1")))
        XCTAssertTrue(errors.contains(.duplicateCueNumber("INTRO")))
        XCTAssertFalse(list.isValid)
    }

    func testAdvancePlayheadStepsForwardThenLandsAtEnd() throws {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let cueC = Cue(number: "3", title: "C", assetID: asset)
        var list = ShowList(cues: [cueA, cueB, cueC])

        XCTAssertEqual(list.playheadCue?.id, cueA.id)
        list.advancePlayhead()
        XCTAssertEqual(list.playheadCue?.id, cueB.id)
        list.advancePlayhead()
        XCTAssertEqual(list.playheadCue?.id, cueC.id)
        list.advancePlayhead()
        XCTAssertNil(list.playheadCue, "Playhead should land off the end after the last cue")
    }

    func testRetreatPlayheadFromEndReturnsToLastCue() throws {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        var list = ShowList(cues: [cueA, cueB])
        list.advancePlayhead() // → B
        list.advancePlayhead() // → off the end
        XCTAssertNil(list.playheadCue)
        list.retreatPlayhead()
        XCTAssertEqual(list.playheadCue?.id, cueB.id)
        list.retreatPlayhead()
        XCTAssertEqual(list.playheadCue?.id, cueA.id)
        list.retreatPlayhead()
        XCTAssertEqual(list.playheadCue?.id, cueA.id, "Retreat at start is a no-op")
    }

    func testRemoveCueAtPlayheadAdvancesPlayheadToCueThatTookItsSlot() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let cueC = Cue(number: "3", title: "C", assetID: asset)
        var list = ShowList(cues: [cueA, cueB, cueC])
        list.advancePlayhead() // → cueB
        list.remove(at: 1) // remove cueB
        XCTAssertEqual(list.playheadCue?.id, cueC.id)
        XCTAssertEqual(list.cues.count, 2)
    }

    func testMovePlayheadIgnoresUnknownCueID() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        var list = ShowList(cues: [cueA])
        let originalPlayhead = list.playheadCueID
        list.movePlayhead(to: UUID())
        XCTAssertEqual(list.playheadCueID, originalPlayhead)
    }

    // MARK: - CueRuntime (A4b)

    /// Helper: builds a CueRuntime with a controllable clock and an event log.
    private func makeRuntime(cues: [Cue]) -> (CueRuntime, ManualClock, RuntimeEventLog) {
        let list = ShowList(cues: cues)
        let clock = ManualClock()
        let runtime = CueRuntime(showList: list, clock: { clock.now })
        let log = RuntimeEventLog()
        log.attach(runtime)
        return (runtime, clock, log)
    }

    func testCueRuntimeStartsAllCuesIdle() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, _) = makeRuntime(cues: [cueA, cueB])
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle)
        XCTAssertFalse(runtime.blackout)
        XCTAssertFalse(runtime.panicActive)
    }

    func testGoFiresPlayheadAndAdvances() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA, cueB])

        let fired = runtime.go()
        XCTAssertEqual(fired?.id, cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .running)
        XCTAssertEqual(runtime.showList.playheadCue?.id, cueB.id)
        XCTAssertTrue(log.contains(.cueFired(cueA.id, dueToContinuation: false)))
        XCTAssertTrue(log.contains(.cueStateChanged(cueA.id, .running)))
        XCTAssertTrue(log.contains(.playheadChanged(cueB.id)))
    }

    func testGoOnEmptyListReturnsNoCueAtPlayhead() {
        let (runtime, _, log) = makeRuntime(cues: [])
        XCTAssertNil(runtime.go())
        XCTAssertTrue(log.contains(.goRejected(.noCueAtPlayhead)))
    }

    func testGoDebouncesRapidCalls() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let cueC = Cue(number: "3", title: "C", assetID: asset)
        let (runtime, clock, log) = makeRuntime(cues: [cueA, cueB, cueC])
        runtime.minimumGoInterval = 0.25

        clock.now = 100.0
        XCTAssertNotNil(runtime.go()) // fires A, playhead → B

        clock.now = 100.10 // 100 ms later — within 250 ms debounce
        XCTAssertNil(runtime.go())
        XCTAssertTrue(log.contains(.goRejected(.debounced)))
        XCTAssertEqual(runtime.showList.playheadCue?.id, cueB.id, "Playhead must not advance on debounced GO")
        XCTAssertEqual(runtime.state(of: cueB.id), .idle, "B must not have fired")

        clock.now = 100.30 // 300 ms later — past debounce
        XCTAssertNotNil(runtime.go())
        XCTAssertEqual(runtime.state(of: cueB.id), .running)
    }

    func testGoTargetNumberJumpsAndFires() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "INTRO", title: "B", assetID: asset)
        let cueC = Cue(number: "BUMPER", title: "C", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA, cueB, cueC])

        let fired = runtime.go(targetNumber: "intro") // case-insensitive
        XCTAssertEqual(fired?.id, cueB.id)
        XCTAssertEqual(runtime.state(of: cueB.id), .running)
        XCTAssertEqual(runtime.showList.playheadCue?.id, cueC.id)
        XCTAssertFalse(log.contains(.goRejected(.unknownCueNumber("intro"))))
    }

    func testGoTargetNumberRejectsUnknown() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA])
        XCTAssertNil(runtime.go(targetNumber: "missing"))
        XCTAssertTrue(log.contains(.goRejected(.unknownCueNumber("missing"))))
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
    }

    func testPreviousMovesPlayheadBackWithoutFiring() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA, cueB])
        runtime.go() // playhead → B

        log.clear()
        runtime.previous()
        XCTAssertEqual(runtime.showList.playheadCue?.id, cueA.id)
        XCTAssertFalse(log.events.contains(where: {
            if case .cueFired = $0 { return true } else { return false }
        }))
    }

    func testPanicMovesRunningCuesToTailAndBlocksGo() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let cueC = Cue(number: "3", title: "C", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA, cueB, cueC])
        runtime.go() // A running, playhead → B

        runtime.panic()
        XCTAssertTrue(runtime.panicActive)
        XCTAssertEqual(runtime.state(of: cueA.id), .tail)
        XCTAssertTrue(log.contains(.panicChanged(true)))

        XCTAssertNil(runtime.go(), "GO must be rejected while panic is active")
        XCTAssertTrue(log.contains(.goRejected(.panicInProgress)))
    }

    func testPanicCompletedDrainsTailAndUnlocksGo() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, clock, log) = makeRuntime(cues: [cueA, cueB])
        runtime.go() // A running

        runtime.panic(fade: 0.4)
        XCTAssertEqual(runtime.state(of: cueA.id), .tail)
        runtime.panicCompleted()
        XCTAssertFalse(runtime.panicActive)
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        XCTAssertTrue(log.contains(.cueEnded(cueA.id)))
        XCTAssertTrue(log.contains(.panicChanged(false)))

        clock.now = 1.0 // sufficiently past any prior GO debounce
        XCTAssertNotNil(runtime.go(), "GO must succeed after panicCompleted")
    }

    func testClearForcesAllRunningAndTailCuesToIdle() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA, cueB])
        runtime.go() // A running

        runtime.clear()
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        XCTAssertTrue(log.contains(.cueEnded(cueA.id)))
        XCTAssertTrue(log.contains(.cleared))
        XCTAssertFalse(runtime.panicActive)
    }

    func testToggleBlackoutFlipsAndEmits() {
        let (runtime, _, log) = makeRuntime(cues: [])
        XCTAssertFalse(runtime.blackout)
        runtime.toggleBlackout()
        XCTAssertTrue(runtime.blackout)
        XCTAssertTrue(log.contains(.blackoutChanged(true)))
        runtime.toggleBlackout()
        XCTAssertFalse(runtime.blackout)
    }

    func testSetBlackoutIdempotent() {
        let (runtime, _, log) = makeRuntime(cues: [])
        runtime.setBlackout(false) // no-op, already false
        XCTAssertFalse(log.contains(.blackoutChanged(false)))
        runtime.setBlackout(true)
        XCTAssertTrue(log.contains(.blackoutChanged(true)))
    }

    func testCueDidEndTransitionsRunningToIdleAndEmits() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA])
        runtime.go()
        XCTAssertEqual(runtime.state(of: cueA.id), .running)
        runtime.cueDidEnd(cueID: cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        XCTAssertTrue(log.contains(.cueEnded(cueA.id)))
    }

    func testMarkLoadedAndUnloadIsRoundTripable() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA])
        runtime.markLoaded(cueID: cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .loaded)
        XCTAssertTrue(log.contains(.cueStateChanged(cueA.id, .loaded)))
        runtime.unloadCue(cueID: cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
    }

    func testMarkLoadedNoOpWhenAlreadyLoaded() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let (runtime, _, log) = makeRuntime(cues: [cueA])
        runtime.markLoaded(cueID: cueA.id)
        log.clear()
        runtime.markLoaded(cueID: cueA.id)
        XCTAssertFalse(log.events.contains(where: {
            if case .cueStateChanged = $0 { return true } else { return false }
        }))
    }

    func testMutateShowListDropsStateForRemovedCues() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, _) = makeRuntime(cues: [cueA, cueB])
        runtime.markLoaded(cueID: cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .loaded)

        runtime.mutateShowList { list in
            list.remove(at: 0) // remove A
        }
        XCTAssertEqual(runtime.cueStates[cueA.id], nil)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle)
    }

    func testReplaceShowListPreservesStateForOverlappingCueIDs() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, _) = makeRuntime(cues: [cueA])
        runtime.markLoaded(cueID: cueA.id)
        runtime.replaceShowList(ShowList(cues: [cueA, cueB]))
        XCTAssertEqual(runtime.state(of: cueA.id), .loaded, "Overlapping cue ID retains its state")
        XCTAssertEqual(runtime.state(of: cueB.id), .idle)
    }

    // MARK: - Continuation timing (A4c)

    /// Helper for continuation tests — uses a manual scheduler so auto-follow timing is deterministic.
    private func makeRuntimeWithScheduler(cues: [Cue]) -> (CueRuntime, ManualClock, ManualCueScheduler, RuntimeEventLog) {
        let list = ShowList(cues: cues)
        let clock = ManualClock()
        let scheduler = ManualCueScheduler()
        let runtime = CueRuntime(showList: list, clock: { clock.now }, scheduler: scheduler)
        let log = RuntimeEventLog()
        log.attach(runtime)
        return (runtime, clock, scheduler, log)
    }

    func testAutoContinueChainsImmediatelyToNextCue() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoContinue)
        let cueB = Cue(number: "2", title: "B", assetID: asset, continuation: .hold)
        let cueC = Cue(number: "3", title: "C", assetID: asset)
        let (runtime, _, _, log) = makeRuntimeWithScheduler(cues: [cueA, cueB, cueC])

        runtime.go()
        XCTAssertEqual(runtime.state(of: cueA.id), .running)
        XCTAssertEqual(runtime.state(of: cueB.id), .running, "auto-continue must fire B as well")
        XCTAssertEqual(runtime.state(of: cueC.id), .idle, "B is hold, chain must stop at B")
        XCTAssertEqual(runtime.showList.playheadCue?.id, cueC.id, "Playhead lands on the cue after the last fired")
        XCTAssertTrue(log.contains(.cueFired(cueA.id, dueToContinuation: false)))
        XCTAssertTrue(log.contains(.cueFired(cueB.id, dueToContinuation: true)))
    }

    func testAutoContinueChainStopsAtEndOfList() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoContinue)
        let cueB = Cue(number: "2", title: "B", assetID: asset, continuation: .autoContinue)
        let (runtime, _, _, _) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go()
        XCTAssertEqual(runtime.state(of: cueA.id), .running)
        XCTAssertEqual(runtime.state(of: cueB.id), .running)
        XCTAssertNil(runtime.showList.playheadCue, "Chain runs off the end without error")
    }

    func testAutoFollowSchedulesNextCueAfterPostWaitOnCueDidEnd() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 1.0)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, scheduler, log) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go() // A running, playhead → B
        XCTAssertEqual(runtime.state(of: cueA.id), .running)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle)

        runtime.cueDidEnd(cueID: cueA.id)
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle, "B must NOT fire until postWait elapses")

        scheduler.advance(by: 0.5)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle, "Mid-postWait, B still must not fire")

        scheduler.advance(by: 0.6) // total 1.1s elapsed
        XCTAssertEqual(runtime.state(of: cueB.id), .running, "B fires after postWait expires")
        XCTAssertTrue(log.contains(.cueFired(cueB.id, dueToContinuation: true)))
    }

    func testAutoFollowWithZeroPostWaitFiresImmediatelyOnNextSchedulerTick() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 0)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, scheduler, _) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go()
        runtime.cueDidEnd(cueID: cueA.id)
        scheduler.advance(by: 0)
        XCTAssertEqual(runtime.state(of: cueB.id), .running)
    }

    func testPanicCancelsPendingAutoFollow() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 2.0)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, scheduler, _) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go()
        runtime.cueDidEnd(cueID: cueA.id)
        runtime.panic()

        scheduler.advance(by: 5.0) // well past postWait
        XCTAssertEqual(runtime.state(of: cueB.id), .idle, "Panic must cancel pending auto-follow")
    }

    func testClearCancelsPendingAutoFollow() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 2.0)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, scheduler, _) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go()
        runtime.cueDidEnd(cueID: cueA.id)
        runtime.clear()

        scheduler.advance(by: 5.0)
        XCTAssertEqual(runtime.state(of: cueB.id), .idle, "Clear must cancel pending auto-follow")
    }

    func testRemovingNextCueCancelsPendingAutoFollow() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 1.0)
        let cueB = Cue(number: "2", title: "B", assetID: asset)
        let (runtime, _, scheduler, _) = makeRuntimeWithScheduler(cues: [cueA, cueB])

        runtime.go()
        runtime.cueDidEnd(cueID: cueA.id)
        runtime.mutateShowList { list in
            list.remove(at: 1) // remove B
        }

        scheduler.advance(by: 2.0)
        XCTAssertEqual(runtime.state(of: cueA.id), .idle)
        // No assertion on B because it has been removed. Important: no crash, no fire.
    }

    func testAutoFollowChainsThroughMultipleCues() {
        let asset = UUID()
        let cueA = Cue(number: "1", title: "A", assetID: asset, continuation: .autoFollow, postWait: 0.5)
        let cueB = Cue(number: "2", title: "B", assetID: asset, continuation: .autoFollow, postWait: 0.5)
        let cueC = Cue(number: "3", title: "C", assetID: asset, continuation: .hold)
        let (runtime, _, scheduler, _) = makeRuntimeWithScheduler(cues: [cueA, cueB, cueC])

        runtime.go()
        XCTAssertEqual(runtime.state(of: cueA.id), .running)

        runtime.cueDidEnd(cueID: cueA.id)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(runtime.state(of: cueB.id), .running)

        runtime.cueDidEnd(cueID: cueB.id)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(runtime.state(of: cueC.id), .running)
    }

    func testCancelledScheduledTaskDoesNotFire() {
        let scheduler = ManualCueScheduler()
        var fired = false
        let task = scheduler.schedule(after: 1.0) { fired = true }
        task.cancel()
        scheduler.advance(by: 5.0)
        XCTAssertFalse(fired)
        XCTAssertTrue(task.isCancelled)
    }

    func testCancelOnAlreadyCancelledTaskIsIdempotent() {
        let scheduler = ManualCueScheduler()
        let task = scheduler.schedule(after: 1.0) { }
        task.cancel()
        task.cancel() // must not crash
        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - End-to-end project + show-list integration (A11 / A12)

    func testProjectBundleRoundTripsShowListsThroughFileWrapper() throws {
        let asset = UUID()
        let cueA = Cue(number: "INTRO", title: "Intro", assetID: asset, continuation: .autoFollow, postWait: 0.5)
        let cueB = Cue(number: "Q2", title: "Bumper", assetID: asset, notes: "wait for VO")
        let list = ShowList(name: "Main", cues: [cueA, cueB])

        var project = PlayoutProject(showLists: [list])
        project.markCurrentFormatVersion()

        let data = try JSONEncoder.simplePlayback.encode(project)
        let projectWrapper = FileWrapper(regularFileWithContents: data)
        projectWrapper.preferredFilename = ProjectBundleLayout.projectFilename
        let bundleWrapper = FileWrapper(directoryWithFileWrappers: [
            ProjectBundleLayout.projectFilename: projectWrapper
        ])

        let extracted = try SimplePlaybackProjectDocument.projectData(from: bundleWrapper)
        let decoded = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: extracted)
        XCTAssertEqual(decoded.formatVersion, PlayoutProject.currentFormatVersion)
        XCTAssertEqual(decoded.showLists.count, 1)
        let restoredList = try XCTUnwrap(decoded.showLists.first)
        XCTAssertEqual(restoredList.name, "Main")
        XCTAssertEqual(restoredList.cues.count, 2)
        XCTAssertEqual(restoredList.cues[0].number, "INTRO")
        XCTAssertEqual(restoredList.cues[0].continuation, .autoFollow)
        XCTAssertEqual(restoredList.cues[0].postWait, 0.5, accuracy: 0.001)
        XCTAssertEqual(restoredList.cues[1].notes, "wait for VO")
        XCTAssertEqual(decoded.activeShowListID, list.id)
    }

    // MARK: - Stage / Screen model (B1-B4)

    func testStageDefaultsTo1080p59_94Rec709Limited() {
        let stage = Stage(name: "Program")
        XCTAssertEqual(stage.width, 1920)
        XCTAssertEqual(stage.height, 1080)
        XCTAssertEqual(stage.frameRateNumerator, 60_000)
        XCTAssertEqual(stage.frameRateDenominator, 1001)
        XCTAssertEqual(stage.framesPerSecond, 60_000.0 / 1001.0, accuracy: 0.001)
        XCTAssertEqual(stage.colorSpace, .rec709)
        XCTAssertEqual(stage.range, .limited)
    }

    func testScreenRoleHasAllExpectedCases() {
        XCTAssertEqual(ScreenRole.allCases, [.program, .confidence, .multiviewer, .mirror, .auxiliary, .streamOut])
        XCTAssertEqual(ScreenRole.program.label, "Program")
        XCTAssertEqual(ScreenRole.confidence.label, "Confidence")
    }

    func testCornerPinIdentityIsActuallyIdentity() {
        XCTAssertTrue(CornerPin.identity.isIdentity)
        XCTAssertEqual(CornerPin.identity.topLeft.x, 0)
        XCTAssertEqual(CornerPin.identity.bottomRight.x, 1)
    }

    func testTransportBindingLabelsAreReadable() {
        let dl = TransportBinding.deckLink(deviceID: "deck:0", modeID: "1080p59.94", fillKey: true, audioEmbed: true, tenBit: true)
        XCTAssertTrue(dl.label.contains("DeckLink"))
        XCTAssertTrue(dl.label.contains("fill+key"))
        XCTAssertTrue(dl.label.contains("10-bit"))

        let ndi = TransportBinding.ndi(senderName: "SP-Program")
        XCTAssertEqual(ndi.label, "NDI SP-Program")

        let win = TransportBinding.operatorWindow
        XCTAssertEqual(win.label, "Operator window")
    }

    func testStageScreenRoundTripThroughJSON() throws {
        let stage = Stage(
            name: "Program",
            width: 3840,
            height: 2160,
            frameRateNumerator: 30000,
            frameRateDenominator: 1001,
            colorSpace: .rec709,
            range: .full
        )
        let screen = Screen(role: .confidence, name: "Stage Mon", stageID: stage.id)
        let project = PlayoutProject(stages: [stage], screens: [screen])

        let data = try JSONEncoder.simplePlayback.encode(project)
        let decoded = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
        XCTAssertEqual(decoded.stages.count, 1)
        XCTAssertEqual(decoded.stages[0].width, 3840)
        XCTAssertEqual(decoded.stages[0].framesPerSecond, 30000.0 / 1001.0, accuracy: 0.001)
        XCTAssertEqual(decoded.stages[0].range, .full)
        XCTAssertEqual(decoded.screens.count, 1)
        XCTAssertEqual(decoded.screens[0].role, .confidence)
        XCTAssertEqual(decoded.screens[0].name, "Stage Mon")
        XCTAssertEqual(decoded.screens[0].stageID, stage.id)
    }

    func testScreenBindingRoundTripPreservesTransport() throws {
        let screenID = UUID()
        let binding = ScreenBinding(
            screenID: screenID,
            transport: .deckLink(deviceID: "deck:0", modeID: "1080p59.94", fillKey: true, audioEmbed: true, tenBit: true)
        )
        let profile = OutputBindingProfile(name: "Booth A", bindings: [binding])

        let data = try JSONEncoder.simplePlayback.encode(profile)
        let decoded = try JSONDecoder.simplePlayback.decode(OutputBindingProfile.self, from: data)
        XCTAssertEqual(decoded.bindings.count, 1)
        XCTAssertEqual(decoded.bindings[0].screenID, screenID)
        if case let .deckLink(_, _, fillKey, _, tenBit) = decoded.bindings[0].transport {
            XCTAssertTrue(fillKey)
            XCTAssertTrue(tenBit)
        } else {
            XCTFail("Expected DeckLink transport, got \(decoded.bindings[0].transport)")
        }
        XCTAssertNotNil(decoded.binding(forScreenID: screenID))
    }

    func testMarkCurrentFormatVersionSeedsDefaultStageAndScreen() {
        var project = PlayoutProject()
        XCTAssertTrue(project.stages.isEmpty)
        XCTAssertTrue(project.screens.isEmpty)
        project.markCurrentFormatVersion()
        XCTAssertEqual(project.stages.count, 1)
        XCTAssertEqual(project.stages.first?.name, "Program")
        XCTAssertEqual(project.screens.count, 1)
        XCTAssertEqual(project.screens.first?.role, .program)
        XCTAssertEqual(project.screens.first?.stageID, project.stages.first?.id)
    }

    func testGenerateDefaultShowListThenFireGOAdvancesPlayheadAcrossEntireList() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let slideA = MediaSlide(url: url, mediaKind: .image)
        let slideB = MediaSlide(url: url, mediaKind: .image)
        let slideC = MediaSlide(url: url, mediaKind: .image)
        var project = PlayoutProject(slides: [slideA, slideB, slideC])
        project.generateDefaultShowList()

        let list = project.activeShowList!
        let clock = ManualClock()
        let runtime = CueRuntime(showList: list, clock: { clock.now })
        runtime.minimumGoInterval = 0
        var fired: [String] = []
        runtime.onCueFired = { cue, _ in fired.append(cue.number) }

        for _ in 0..<3 {
            runtime.go()
            clock.now += 0.001
        }

        XCTAssertEqual(fired, ["1", "2", "3"])
        XCTAssertNil(runtime.showList.playheadCue, "Playhead lands off the end after the last GO")
    }

    func testShowListRoundTripsThroughJSON() throws {
        let asset = UUID()
        let cueA = Cue(number: "INTRO", title: "Intro", assetID: asset, continuation: .autoFollow)
        let cueB = Cue(number: "BUMPER", title: "Bumper", assetID: asset, preWait: 1.5)
        var list = ShowList(name: "Main", cues: [cueA, cueB])
        list.movePlayhead(to: cueB.id)

        let data = try JSONEncoder.simplePlayback.encode(list)
        let decoded = try JSONDecoder.simplePlayback.decode(ShowList.self, from: data)
        XCTAssertEqual(decoded.id, list.id)
        XCTAssertEqual(decoded.name, "Main")
        XCTAssertEqual(decoded.cues.count, 2)
        XCTAssertEqual(decoded.cues[0].number, "INTRO")
        XCTAssertEqual(decoded.cues[1].preWait, 1.5, accuracy: 0.001)
        XCTAssertEqual(decoded.playheadCueID, cueB.id)
    }

    // MARK: - Pre-existing tests (rendering, scaling, importing, drivers)

    func testFitScalingCentersLetterboxedMedia() {
        let rect = ScalingGeometry.mediaRect(
            sourceSize: CGSize(width: 1000, height: 1000),
            canvasSize: CGSize(width: 1920, height: 1080),
            mode: .fit
        )

        XCTAssertEqual(rect.width, 1080, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 420, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    }

    func testCrossfadeDurationClampMatchesSupportedRange() {
        XCTAssertEqual(PlayoutTransitionSettings.clampedDuration(0), 0.1, accuracy: 0.001)
        XCTAssertEqual(PlayoutTransitionSettings.clampedDuration(12.5), 12.5, accuracy: 0.001)
        XCTAssertEqual(PlayoutTransitionSettings.clampedDuration(45), 30, accuracy: 0.001)
    }

    func testFrameRendererBlendsBGRAFrames() throws {
        let renderer = FrameRenderer()
        let start = RenderedFrame(
            data: Data([0, 20, 100, 255, 80, 120, 200, 255]),
            width: 2,
            height: 1,
            rowBytes: 8
        )
        let end = RenderedFrame(
            data: Data([100, 220, 200, 255, 180, 20, 0, 255]),
            width: 2,
            height: 1,
            rowBytes: 8
        )

        let frame = try XCTUnwrap(renderer.blend(from: start, to: end, progress: 0.5))

        XCTAssertEqual(Array(frame.data), [50, 120, 150, 255, 130, 70, 100, 255])
    }

    func testFrameRendererFastPathCopiesBGRAFramesWithDeckLinkOrientation() throws {
        var pixelBuffer: CVPixelBuffer?
        let createResult = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        try XCTSkipIf(createResult != kCVReturnSuccess || pixelBuffer == nil, "CVPixelBufferCreate is not available in this environment")
        let unwrappedPixelBuffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(unwrappedPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(unwrappedPixelBuffer) else {
            XCTFail("Expected pixel buffer base address")
            return
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(unwrappedPixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        func writePixel(x: Int, y: Int, blue: UInt8) {
            let offset = y * rowBytes + x * 4
            bytes[offset] = blue
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
            bytes[offset + 3] = 255
        }

        writePixel(x: 0, y: 0, blue: 10)
        writePixel(x: 1, y: 0, blue: 20)
        writePixel(x: 0, y: 1, blue: 30)
        writePixel(x: 1, y: 1, blue: 40)

        let renderer = FrameRenderer()
        let frame = try XCTUnwrap(renderer.renderPixelBuffer(unwrappedPixelBuffer, settings: SlideSettings(), outputSize: CGSize(width: 2, height: 2)))

        XCTAssertEqual(Array(frame.data), [
            30, 0, 0, 255,
            40, 0, 0, 255,
            10, 0, 0, 255,
            20, 0, 0, 255
        ])
    }

    func testFillScalingCropsMedia() {
        let rect = ScalingGeometry.mediaRect(
            sourceSize: CGSize(width: 1000, height: 1000),
            canvasSize: CGSize(width: 1920, height: 1080),
            mode: .fill
        )

        XCTAssertEqual(rect.width, 1920, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1920, accuracy: 0.001)
        XCTAssertEqual(rect.minY, -420, accuracy: 0.001)
    }

    func testCustomScalingUsesFitAsOneHundredPercent() {
        let rect = ScalingGeometry.mediaRect(
            sourceSize: CGSize(width: 1920, height: 1080),
            canvasSize: CGSize(width: 1920, height: 1080),
            mode: .custom,
            customScale: 0.5,
            offset: CGPoint(x: 10, y: -20)
        )

        XCTAssertEqual(rect.width, 960, accuracy: 0.001)
        XCTAssertEqual(rect.height, 540, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 490, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 250, accuracy: 0.001)
    }

    func testMediaKindClassifiesCommonExtensions() throws {
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/still.jpg")), .image)

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try makeSingleFrameMovie(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        XCTAssertEqual(MediaImporter.mediaKind(for: videoURL), .video)

        let emptyMovieURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        FileManager.default.createFile(atPath: emptyMovieURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: emptyMovieURL) }
        XCTAssertNil(MediaImporter.mediaKind(for: emptyMovieURL))

        XCTAssertNil(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/readme.txt")))
    }

    func testPreviewDriverStartsAndAcceptsFrames() throws {
        let driver = PreviewVideoOutputDriver()
        let devices = driver.availableDevices()

        XCTAssertEqual(devices.first?.id, "preview:software")
        try driver.start(deviceID: "preview:software", modeID: "preview-mode:1080p30")
        XCTAssertEqual(driver.status, "Software preview running")
        try driver.submitVideoFrame(Data(count: 1920 * 1080 * 4), width: 1920, height: 1080, rowBytes: 1920 * 4)
        try driver.submitAudioPCM16(Data(count: 480 * 4), sampleFrameCount: 480)
    }

    func testDeckLinkBridgeCanQueryRuntime() {
        let bridge = SPDeckLinkBridge()
        _ = bridge.availableDevices()
        XCTAssertFalse(bridge.runtimeStatus.isEmpty)
    }

    private func makeSingleFrameMovie(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            XCTFail("Expected pixel buffer pool")
            return
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard let pixelBuffer else {
            XCTFail("Expected pixel buffer")
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        while !input.isReadyForMoreMediaData {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        input.markAsFinished()

        let finished = expectation(description: "Movie writer finished")
        writer.finishWriting {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        if let error = writer.error {
            throw error
        }
    }
}

// MARK: - Test helpers

/// Manual clock for deterministic time-based tests.
private final class ManualClock {
    var now: TimeInterval = 0
}

/// Scheduler used by continuation-timing tests. Holds tasks until `advance(by:)` is called,
/// then fires every task whose deadline has elapsed (in deadline order). Repeats until no
/// further tasks become ready, so a chain of auto-follows resolves in one `advance` call.
final class ManualCueScheduler: CueScheduler {
    private struct PendingTask {
        let id: UUID
        let fireAt: TimeInterval
        var cancelled: Bool
        let work: () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var tasks: [PendingTask] = []

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> CueScheduledTask {
        let id = UUID()
        let task = PendingTask(id: id, fireAt: now + max(0, delay), cancelled: false, work: work)
        tasks.append(task)
        return CueScheduledTask { [weak self] in
            guard let self else { return }
            if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                self.tasks[idx].cancelled = true
            }
        }
    }

    /// Advances virtual time by `delta` seconds and fires every task whose deadline has elapsed,
    /// in deadline order. Tasks scheduled by fired tasks are eligible if their new deadline is
    /// also reached, until no further tasks fire.
    func advance(by delta: TimeInterval) {
        now += max(0, delta)
        flushReady()
    }

    /// Sets virtual time to `time` (must be ≥ current `now`).
    func advance(to time: TimeInterval) {
        guard time >= now else { return }
        now = time
        flushReady()
    }

    private func flushReady() {
        var fired = true
        while fired {
            fired = false
            // Pick the earliest non-cancelled task whose fireAt has elapsed.
            let readyIndex = tasks.indices
                .filter { !tasks[$0].cancelled && tasks[$0].fireAt <= now }
                .min(by: { tasks[$0].fireAt < tasks[$1].fireAt })
            guard let idx = readyIndex else { break }
            let task = tasks.remove(at: idx)
            task.work()
            fired = true
        }
        // Drop cancelled tasks so they don't pile up.
        tasks.removeAll(where: { $0.cancelled })
    }
}

/// Captures every CueRuntime callback as an enum event so tests can assert ordering / presence.
private final class RuntimeEventLog {
    enum Event: Equatable {
        case cueFired(UUID, dueToContinuation: Bool)
        case cueEnded(UUID)
        case cueStateChanged(UUID, CueStandbyState)
        case playheadChanged(UUID?)
        case panicChanged(Bool)
        case blackoutChanged(Bool)
        case goRejected(CueRuntimeRejection)
        case cleared
    }

    private(set) var events: [Event] = []

    func clear() { events.removeAll() }

    func contains(_ event: Event) -> Bool { events.contains(event) }

    func attach(_ runtime: CueRuntime) {
        runtime.onCueFired = { [weak self] cue, due in
            self?.events.append(.cueFired(cue.id, dueToContinuation: due))
        }
        runtime.onCueEnded = { [weak self] cue in
            self?.events.append(.cueEnded(cue.id))
        }
        runtime.onCueStateChanged = { [weak self] cue, state in
            self?.events.append(.cueStateChanged(cue.id, state))
        }
        runtime.onPlayheadChanged = { [weak self] cue in
            self?.events.append(.playheadChanged(cue?.id))
        }
        runtime.onPanicChanged = { [weak self] active, _ in
            self?.events.append(.panicChanged(active))
        }
        runtime.onBlackoutChanged = { [weak self] active in
            self?.events.append(.blackoutChanged(active))
        }
        runtime.onGoRejected = { [weak self] reason in
            self?.events.append(.goRejected(reason))
        }
        runtime.onCleared = { [weak self] in
            self?.events.append(.cleared)
        }
    }
}
