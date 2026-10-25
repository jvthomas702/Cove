import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Cove

final class FileConverterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A solid image; `clear` makes it fully transparent.
    private func image(_ name: String, width: Int, height: Int, type: UTType = .png, clear: Bool = false) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: clear ? 0 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pdfPages(_ url: URL) throws -> [CGRect] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        return (1...document.numberOfPages).compactMap { document.page(at: $0)?.getBoxRect(.mediaBox) }
    }

    func testOffersConversionsThatFitTheSelection() {
        let jpeg = URL(fileURLWithPath: "/tmp/photo.jpeg"), png = URL(fileURLWithPath: "/tmp/shot.png")
        let pdf = URL(fileURLWithPath: "/tmp/notes.pdf"), zip = URL(fileURLWithPath: "/tmp/archive.zip")
        XCTAssertEqual(FileConverter.conversions(for: [jpeg]), [.pdf, .image(.png), .image(.heic), .image(.tiff)])
        XCTAssertEqual(FileConverter.conversions(for: [jpeg, png]).first, .pdf)
        XCTAssertTrue(FileConverter.conversions(for: [jpeg, png]).contains(.image(.jpeg)))
        XCTAssertEqual(FileConverter.conversions(for: [pdf]), [.pdfPages(.png), .pdfPages(.jpeg)])
        XCTAssertEqual(FileConverter.conversions(for: [pdf, jpeg]), [.pdf])
        XCTAssertEqual(FileConverter.conversions(for: [jpeg, zip]), [])
        XCTAssertEqual(FileConverter.conversions(for: []), [])
        XCTAssertEqual(FileConversion.pdf.title(count: 1), "Convert to PDF")
        XCTAssertEqual(FileConversion.pdf.title(count: 3), "Combine into PDF")
    }

    func testJPEGBecomesAOnePagePDFBesideIt() throws {
        let photo = try image("Photo.jpg", width: 400, height: 300, type: .jpeg)
        let outputs = try FileConverter.convert([photo], to: .pdf, into: root)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Photo.pdf"])
        let pages = try pdfPages(outputs[0])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].width, 400, accuracy: 0.5)
        XCTAssertEqual(pages[0].height, 300, accuracy: 0.5)
    }

    func testLargeImagesFitAnA4SizedPage() throws {
        let photo = try image("Big.png", width: 2000, height: 1000)
        let page = try XCTUnwrap(pdfPages(try FileConverter.convert([photo], to: .pdf, into: root)[0]).first)
        XCTAssertEqual(page.width, FileConverter.pageLongSide, accuracy: 0.5)
        XCTAssertEqual(page.height, FileConverter.pageLongSide / 2, accuracy: 0.5)
    }

    func testCombinesImagesAndPDFsInOrderWithoutOverwriting() throws {
        let first = try image("Scan.png", width: 100, height: 200)
        let second = try image("Back.jpg", width: 300, height: 100, type: .jpeg)
        let existing = try FileConverter.convert([second], to: .pdf, into: root)[0]
        let combined = try FileConverter.convert([first, second, existing], to: .pdf, into: root)
        XCTAssertEqual(combined.map(\.lastPathComponent), ["Scan and 2 more.pdf"])
        let pages = try pdfPages(combined[0])
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].width, 100, accuracy: 0.5)
        XCTAssertEqual(pages[1].width, 300, accuracy: 0.5)
        XCTAssertEqual(pages[2].width, 300, accuracy: 0.5)

        let again = try FileConverter.convert([second], to: .pdf, into: root)
        XCTAssertEqual(again.map(\.lastPathComponent), ["Back 2.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testImageFormatsAndTransparentPNGToJPEGOnWhite() throws {
        let clear = try image("Logo.png", width: 20, height: 20, clear: true)
        let jpeg = try XCTUnwrap(FileConverter.convert([clear], to: .image(.jpeg), into: root).first)
        XCTAssertEqual(jpeg.pathExtension, "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertGreaterThan(pixel[1], 240, "see-through pixels should land on white, not black")

        let tiff = try XCTUnwrap(FileConverter.convert([clear], to: .image(.tiff), into: root).first)
        XCTAssertEqual(tiff.lastPathComponent, "Logo.tiff")
    }

    func testPDFPagesExportAsNumberedImages() throws {
        let a = try image("A.png", width: 100, height: 50), b = try image("B.png", width: 100, height: 50)
        let pdf = try FileConverter.convert([a, b], to: .pdf, into: root)[0]
        let pages = try FileConverter.convert([pdf], to: .pdfPages(.png), into: root)
        XCTAssertEqual(pages.map(\.lastPathComponent), ["A and 1 more 1.png", "A and 1 more 2.png"])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(pages[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 200)
    }

    func testUnreadableFilesFailWithoutLeavingHalfAFile() throws {
        let broken = root.appendingPathComponent("Broken.png")
        try Data("not an image".utf8).write(to: broken)
        XCTAssertThrowsError(try FileConverter.convert([broken], to: .pdf, into: root)) { error in
            XCTAssertEqual(error as? ConversionError, .unreadable("Broken.png"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Broken.pdf").path))
    }

    func testOutputGoesToDownloadsForFilesInsideLibrary() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let retained = home.appendingPathComponent("Library/Application Support/Cove/Shelf/shot.png")
        XCTAssertEqual(FileConverter.outputFolder(for: retained),
                       FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        XCTAssertEqual(FileConverter.outputFolder(for: root.appendingPathComponent("x.png")).standardizedFileURL,
                       root.standardizedFileURL)
    }
}
