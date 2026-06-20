import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct RenderedFrame {
    var data: Data
    var width: Int
    var height: Int
    var rowBytes: Int
}

final class FrameRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func renderImage(_ image: NSImage, settings: SlideSettings, outputSize: CGSize) -> RenderedFrame? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return render(cgImage: cgImage, settings: settings, outputSize: outputSize)
    }

    func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, settings: SlideSettings, outputSize: CGSize) -> RenderedFrame? {
        if let frame = renderPixelBufferFast(pixelBuffer, settings: settings, outputSize: outputSize) {
            return frame
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return render(cgImage: cgImage, settings: settings, outputSize: outputSize)
    }

    func blackFrame(outputSize: CGSize) -> RenderedFrame {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let rowBytes = width * 4
        return RenderedFrame(data: Data(count: rowBytes * height), width: width, height: height, rowBytes: rowBytes)
    }

    func blankFrame(matching frame: RenderedFrame) -> RenderedFrame {
        RenderedFrame(data: Data(count: frame.data.count), width: frame.width, height: frame.height, rowBytes: frame.rowBytes)
    }

    func blend(from startFrame: RenderedFrame, to endFrame: RenderedFrame, progress: Double) -> RenderedFrame? {
        var outputFrame = blankFrame(matching: endFrame)
        guard blend(from: startFrame, to: endFrame, into: &outputFrame, progress: progress) else {
            return nil
        }
        return outputFrame
    }

    func blend(from startFrame: RenderedFrame, to endFrame: RenderedFrame, into outputFrame: inout RenderedFrame, progress: Double) -> Bool {
        guard startFrame.width == endFrame.width,
              startFrame.height == endFrame.height,
              startFrame.rowBytes == endFrame.rowBytes,
              startFrame.data.count == endFrame.data.count,
              outputFrame.width == endFrame.width,
              outputFrame.height == endFrame.height,
              outputFrame.rowBytes == endFrame.rowBytes,
              outputFrame.data.count == endFrame.data.count,
              endFrame.data.count % MemoryLayout<UInt32>.size == 0 else {
            return false
        }

        let clampedProgress = max(0, min(1, progress))
        let alpha = UInt32((clampedProgress * 256).rounded())
        let pixelCount = endFrame.data.count / MemoryLayout<UInt32>.size

        outputFrame.data.withUnsafeMutableBytes { outputBytes in
            startFrame.data.withUnsafeBytes { startBytes in
                endFrame.data.withUnsafeBytes { endBytes in
                    guard let outputBase = outputBytes.baseAddress,
                          let startBase = startBytes.baseAddress,
                          let endBase = endBytes.baseAddress else {
                        return
                    }

                    SPBlendBGRA8888(startBase, endBase, outputBase, pixelCount, alpha)
                }
            }
        }

        return true
    }

    func blendInPlace(from startFrame: RenderedFrame, into outputFrame: inout RenderedFrame, progress: Double) -> Bool {
        guard startFrame.width == outputFrame.width,
              startFrame.height == outputFrame.height,
              startFrame.rowBytes == outputFrame.rowBytes,
              startFrame.data.count == outputFrame.data.count,
              outputFrame.data.count % MemoryLayout<UInt32>.size == 0 else {
            return false
        }

        let clampedProgress = max(0, min(1, progress))
        let alpha = UInt32((clampedProgress * 256).rounded())
        let pixelCount = outputFrame.data.count / MemoryLayout<UInt32>.size

        outputFrame.data.withUnsafeMutableBytes { outputBytes in
            startFrame.data.withUnsafeBytes { startBytes in
                guard let outputBase = outputBytes.baseAddress,
                      let startBase = startBytes.baseAddress else {
                    return
                }

                SPBlendBGRA8888InPlace(startBase, outputBase, pixelCount, alpha)
            }
        }

        return true
    }

    func render(cgImage: CGImage, settings: SlideSettings, outputSize: CGSize) -> RenderedFrame? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let rect = ScalingGeometry.mediaRect(
            sourceSize: sourceSize,
            canvasSize: outputSize,
            mode: settings.scaleMode,
            alignment: settings.alignment,
            customScale: settings.customScale,
            offset: CGPoint(x: settings.offsetX, y: settings.offsetY)
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        let didRender = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: outputSize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: rect)
            return true
        }

        guard didRender else { return nil }

        applyEffects(to: &data, width: width, height: height, rowBytes: rowBytes, settings: settings)

        return RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes)
    }

    static func hasColorOrBlurEffects(_ settings: SlideSettings) -> Bool {
        settings.blurRadius > 0
            || abs(settings.hueShift) > 0.0001
            || abs(settings.saturation - 100) > 0.0001
            || abs(settings.brightness) > 0.0001
            || abs(settings.contrast - 100) > 0.0001
            || abs(settings.temperature) > 0.0001
            || abs(settings.tint) > 0.0001
    }

    // Applies saturation, hue, and blur to the composed BGRA frame in a single
    // CoreImage pass. Saturation/hue leave black letterbox bars untouched; the
    // blur is clamped to the frame extent so the canvas edges don't darken.
    private func applyEffects(to data: inout Data, width: Int, height: Int, rowBytes: Int, settings: SlideSettings) {
        guard FrameRenderer.hasColorOrBlurEffects(settings) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(
            bitmapData: data,
            bytesPerRow: rowBytes,
            size: CGSize(width: width, height: height),
            format: .BGRA8,
            colorSpace: colorSpace
        )

        if abs(settings.temperature) > 0.0001 || abs(settings.tint) > 0.0001 {
            // Shift the target neutral: a lower target temperature warms the
            // image, so +temperature -> warmer. +tint -> magenta, -tint -> green.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - settings.temperature * 30, y: -settings.tint)
            ])
        }
        if abs(settings.saturation - 100) > 0.0001
            || abs(settings.brightness) > 0.0001
            || abs(settings.contrast - 100) > 0.0001 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: settings.saturation / 100.0,
                kCIInputBrightnessKey: settings.brightness / 100.0,
                kCIInputContrastKey: settings.contrast / 100.0
            ])
        }
        if abs(settings.hueShift) > 0.0001 {
            image = image.applyingFilter("CIHueAdjust", parameters: [
                kCIInputAngleKey: settings.hueShift * Double.pi / 180.0
            ])
        }
        if settings.blurRadius > 0 {
            image = image
                .clampedToExtent()
                .applyingGaussianBlur(sigma: settings.blurRadius)
                .cropped(to: bounds)
        }

        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            ciContext.render(
                image,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .BGRA8,
                colorSpace: colorSpace
            )
        }
    }

    private func renderPixelBufferFast(_ pixelBuffer: CVPixelBuffer, settings: SlideSettings, outputSize: CGSize) -> RenderedFrame? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let outputWidth = Int(outputSize.width.rounded())
        let outputHeight = Int(outputSize.height.rounded())
        guard width == outputWidth,
              height == outputHeight,
              usesWholeOutputFrame(settings) else {
            return nil
        }

        let lockFlags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags)
        }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        guard sourceRowBytes >= rowBytes else {
            return nil
        }

        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { outputBytes in
            guard let outputBaseAddress = outputBytes.baseAddress else { return }
            for row in 0..<height {
                let sourceRow = sourceBaseAddress.advanced(by: row * sourceRowBytes)
                let outputRow = outputBaseAddress.advanced(by: (height - 1 - row) * rowBytes)
                memcpy(outputRow, sourceRow, rowBytes)
            }
        }

        return RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes)
    }

    private func usesWholeOutputFrame(_ settings: SlideSettings) -> Bool {
        // Color/blur effects need the CoreImage path, so skip the straight-copy fast path.
        guard !FrameRenderer.hasColorOrBlurEffects(settings),
              abs(settings.offsetX) < 0.001,
              abs(settings.offsetY) < 0.001 else {
            return false
        }

        switch settings.scaleMode {
        case .fit, .fill, .stretch:
            return true
        case .custom:
            return abs(settings.customScale - 1) < 0.001
        }
    }
}
