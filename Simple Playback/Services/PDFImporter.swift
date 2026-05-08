import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFImportError: LocalizedError {
    case unreadable(URL)
    case noPages(URL)
    case writeFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            "PDF could not be opened: \(url.lastPathComponent)"
        case .noPages(let url):
            "PDF has no pages: \(url.lastPathComponent)"
        case .writeFailed(let url, let underlying):
            "Failed to write \(url.lastPathComponent): \(underlying.localizedDescription)"
        }
    }
}

/// Rasterizes a PDF into PNG sidecars at import time. Spec §3.10: "PDF — PDFKit
/// rasterize-on-import at output × 2; one page = one slide." The caller decides where the
/// PNGs land (project bundle `Cache/Renders/` when the project has a fileURL, app-support
/// fallback otherwise) and at what pixel target. Each page is scaled-to-fit within
/// `rasterSize` while preserving aspect; the output PNG is the *scaled* page size, not
/// `rasterSize` literal — the downstream compositor still applies `ScaleMode` on top.
enum PDFImporter {
    /// Renders every page of `pdfURL` into PNG files in `destinationDirectory` (created if
    /// missing). Returns the URLs of the written PNGs in page order. Throws on unreadable
    /// PDFs, zero-page PDFs, or write errors. Pages that fail to render individually are
    /// skipped (logged via the returned URLs being shorter than `pageCount`).
    @discardableResult
    static func rasterize(
        pdfURL: URL,
        rasterSize: CGSize,
        destinationDirectory: URL
    ) throws -> [URL] {
        guard let document = PDFDocument(url: pdfURL) else {
            throw PDFImportError.unreadable(pdfURL)
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PDFImportError.noPages(pdfURL)
        }
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let digits = max(3, String(pageCount).count)
        var written: [URL] = []
        written.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            guard pageRect.width > 0, pageRect.height > 0 else { continue }

            let scale = min(
                rasterSize.width / pageRect.width,
                rasterSize.height / pageRect.height
            )
            let pixelWidth = Int(ceil(pageRect.width * scale))
            let pixelHeight = Int(ceil(pageRect.height * scale))
            guard pixelWidth > 0, pixelHeight > 0 else { continue }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                continue
            }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            guard let cgImage = context.makeImage() else { continue }
            let pageName = String(format: "page_%0\(digits)d.png", pageIndex + 1)
            let outURL = destinationDirectory.appendingPathComponent(pageName)
            do {
                try writePNG(cgImage: cgImage, to: outURL)
            } catch {
                throw PDFImportError.writeFailed(outURL, underlying: error)
            }
            written.append(outURL)
        }
        return written
    }

    private static func writePNG(cgImage: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
