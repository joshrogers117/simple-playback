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
        return RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes)
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
        guard abs(settings.offsetX) < 0.001,
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
