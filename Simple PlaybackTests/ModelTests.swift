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
