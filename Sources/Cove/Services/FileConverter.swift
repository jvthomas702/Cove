import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image format Cove can write.
enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }
    /// Lossy formats are written at this quality.
    var quality: Double? { self == .jpeg || self == .heic ? 0.9 : nil }

    /// The format a file already is, from its extension.
    static func of(_ url: URL) -> ImageFormat? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        return allCases.first { type.conforms(to: $0.type) }
    }
}

/// What a file can be converted from.
enum FileKind: Equatable {
    case image, pdf, other

    static func of(_ url: URL) -> FileKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .other
    }
}

/// One thing Cove can turn files into.
enum FileConversion: Hashable, Identifiable {
    /// Images and PDFs, in order, into one PDF (one page per image).
    case pdf
    /// Each image re-saved in another format.
    case image(ImageFormat)
    /// Each page of each PDF as its own image.
    case pdfPages(ImageFormat)

    var id: String {
        switch self {
        case .pdf: return "pdf"
        case .image(let format): return "image.\(format.rawValue)"
        case .pdfPages(let format): return "pages.\(format.rawValue)"
        }
    }

    /// Menu title: "Combine into PDF", "Convert to JPEG", "Export pages as PNG".
    func title(count: Int) -> String {
        switch self {
        case .pdf: return count > 1 ? "Combine into PDF" : "Convert to PDF"
        case .image(let format): return "Convert to \(format.label)"
        case .pdfPages(let format): return "Export pages as \(format.label)"
        }
    }

    /// Past tense for the banner: "Made a PDF", "Converted to JPEG".
    var done: String {
        switch self {
        case .pdf: return "Made a PDF"
        case .image(let format): return "Converted to \(format.label)"
        case .pdfPages(let format): return "Exported \(format.label) pages"
        }
    }
}

enum ConversionError: LocalizedError, Equatable {
    case unreadable(String)
    case locked(String)
    case nothingToConvert
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn’t read \(name)."
        case .locked(let name): return "\(name) is password protected."
        case .nothingToConvert: return "Pick images or PDFs to convert."
        case .writeFailed(let name): return "Couldn’t save \(name)."
        }
    }
}

/// Converts images and PDFs on your Mac with ImageIO and Core Graphics. Nothing leaves the Mac.
/// Converted files are written next to the originals with a fresh name, so nothing is ever overwritten.
enum FileConverter {
    /// The longest side of a page made from an image, in points (A4's long side). Smaller images keep their size.
    static let pageLongSide: CGFloat = 842
    /// PDF pages are rendered at this many pixels per point (144 dpi).
    static let pageScale: CGFloat = 2

    /// What the selection can be turned into, most useful first. Empty when it holds anything but images and PDFs.
    static func conversions(for urls: [URL]) -> [FileConversion] {
        let kinds = urls.map(FileKind.of)
        guard !urls.isEmpty, !kinds.contains(.other) else { return [] }
        var list: [FileConversion] = []
        // A single PDF is already a PDF; anything else can become one.
        if !(urls.count == 1 && kinds[0] == .pdf) { list.append(.pdf) }
        if kinds.allSatisfy({ $0 == .image }) {
            for format in ImageFormat.allCases where !urls.allSatisfy({ ImageFormat.of($0) == format }) {
                list.append(.image(format))
            }
        }
        if kinds.allSatisfy({ $0 == .pdf }) { list += [.pdfPages(.png), .pdfPages(.jpeg)] }
        return list
    }

    /// Runs `conversion` and returns the files it wrote. `folder` defaults to `outputFolder(for:)` of the first file.
    static func convert(_ urls: [URL], to conversion: FileConversion, into folder: URL? = nil) throws -> [URL] {
        guard let first = urls.first else { throw ConversionError.nothingToConvert }
        let destination = folder ?? outputFolder(for: first)
        switch conversion {
        case .pdf:
            let base = urls.count > 1 ? first.deletingPathExtension().lastPathComponent + " and \(urls.count - 1) more"
                                      : first.deletingPathExtension().lastPathComponent
            let output = uniqueURL(in: destination, base: base, ext: "pdf")
            try makePDF(from: urls, to: output)
            return [output]
        case .image(let format):
            return try urls.map { url in
                let output = uniqueURL(in: destination, base: url.deletingPathExtension().lastPathComponent, ext: format.fileExtension)
                try convertImage(url, to: format, output: output)
                return output
            }
        case .pdfPages(let format):
            return try urls.flatMap { try exportPages(of: $0, as: format, into: destination) }
        }
    }

    /// Next to the original when Cove can write there, else Downloads. Files kept inside Cove's own
    /// storage (screenshots retained by the shelf) also go to Downloads so you can find the result.
    static func outputFolder(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
        if FileManager.default.isWritableFile(atPath: folder.path), !folder.path.hasPrefix(library) { return folder }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? folder
    }

    /// "Scan.pdf", then "Scan 2.pdf", "Scan 3.pdf"…: never an existing file.
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let name = base.isEmpty ? "Converted" : base
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: - Writers

    private static func makePDF(from urls: [URL], to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
        var finished = false
        defer { if !finished { context.closePDF(); try? FileManager.default.removeItem(at: output) } }
        for url in urls {
            switch FileKind.of(url) {
            case .image:
                let image = try uprightImage(url)
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let scale = min(1, pageLongSide / max(width, height, 1))
                var box = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
                context.beginPage(mediaBox: &box)
                context.interpolationQuality = .high
                context.draw(image, in: box)
                context.endPage()
            case .pdf:
                let document = try openPDF(url)
                for index in 1...max(document.numberOfPages, 1) {
                    guard let page = document.page(at: index) else { continue }
                    var box = uprightBox(of: page)
                    context.beginPage(mediaBox: &box)
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                    context.endPage()
                }
            case .other:
                throw ConversionError.unreadable(url.lastPathComponent)
            }
        }
        context.closePDF()
        finished = true
    }

    private static func convertImage(_ url: URL, to format: ImageFormat, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        // JPEG has no transparency: put see-through pixels on white rather than black.
        if format == .jpeg, hasAlpha(image), let flat = flatten(image) { image = flat }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if let quality = format.quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        try write(image, as: format, to: output, properties: properties)
    }

    private static func exportPages(of url: URL, as format: ImageFormat, into folder: URL) throws -> [URL] {
        let document = try openPDF(url)
        let base = url.deletingPathExtension().lastPathComponent
        let count = document.numberOfPages
        var written: [URL] = []
        for index in 1...max(count, 1) {
            guard let page = document.page(at: index) else { continue }
            let box = uprightBox(of: page)
            let width = Int((box.width * pageScale).rounded()), height = Int((box.height * pageScale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ConversionError.unreadable(url.lastPathComponent)
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: pageScale, y: pageScale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw ConversionError.unreadable(url.lastPathComponent) }
            let output = uniqueURL(in: folder, base: count == 1 ? base : "\(base) \(index)", ext: format.fileExtension)
            var properties: [CFString: Any] = [:]
            if let quality = format.quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            try write(image, as: format, to: output, properties: properties)
            written.append(output)
        }
        return written
    }

    // MARK: - Helpers

    private static func write(_ image: CGImage, as format: ImageFormat, to output: URL, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.writeFailed(output.lastPathComponent)
        }
    }

    /// The image at full size with its EXIF orientation applied, so phone photos aren't sideways in a PDF.
    private static func uprightImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return image
    }

    private static func openPDF(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw ConversionError.locked(url.lastPathComponent)
        }
        guard document.numberOfPages > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }
        return document
    }

    /// The page's crop box at the origin, turned the way the page is meant to be read.
    private static func uprightBox(of page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        let sideways = abs(page.rotationAngle) % 180 == 90
        return CGRect(x: 0, y: 0, width: sideways ? crop.height : crop.width, height: sideways ? crop.width : crop.height)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
