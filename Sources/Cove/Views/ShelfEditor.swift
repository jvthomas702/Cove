import AppKit
import SwiftUI

struct ShelfStroke { var points: [CGPoint]; var color: NSColor; var width: CGFloat }
struct ShelfText { var text: String; var point: CGPoint; var color: NSColor; var size: CGFloat }

enum ShelfImageRenderer {
    static func png(image: NSImage, strokes: [ShelfStroke], labels: [ShelfText]) throws -> Data {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width * cg.height <= 40_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileReadCorruptFile) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        graphics.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for stroke in strokes where !stroke.points.isEmpty {
            let path = NSBezierPath(); path.lineWidth = max(1, stroke.width * w); path.lineCapStyle = .round; path.lineJoinStyle = .round
            let first = stroke.points[0]
            path.move(to: CGPoint(x: first.x * w, y: (1 - first.y) * h))
            for point in stroke.points.dropFirst() { path.line(to: CGPoint(x: point.x * w, y: (1 - point.y) * h)) }
            if stroke.points.count == 1 { path.line(to: CGPoint(x: first.x * w + 0.1, y: (1 - first.y) * h)) }
            stroke.color.setStroke(); path.stroke()
        }
        for label in labels {
            let font = NSFont.systemFont(ofSize: max(10, label.size * w), weight: .semibold)
            (label.text as NSString).draw(at: CGPoint(x: label.point.x * w, y: (1 - label.point.y) * h - font.pointSize),
                                         withAttributes: [.font: font, .foregroundColor: label.color])
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

@MainActor final class ShelfEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    func show(url: URL, model: IslandModel) {
        window?.close()
        guard let image = NSImage(contentsOf: url) else { NSWorkspace.shared.open(url); return }
        installEditMenu()
        model.setMenuTracking(true)
        onClose = { [weak model] in model?.setMenuTracking(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Cove Image Preview"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ShelfEditorView(url: url, image: image, model: model))
        window.minSize = NSSize(width: 600, height: 420)
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil; window = nil }

    private func installEditMenu() {
        let main = NSApp.mainMenu ?? NSMenu()
        guard main.item(withTitle: "Edit") == nil else { return }
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit; main.addItem(item); NSApp.mainMenu = main
    }
}

private struct ShelfEditorView: View {
    @State var url: URL
    let image: NSImage
    @ObservedObject var model: IslandModel
    @State private var strokes: [ShelfStroke] = []
    @State private var labels: [ShelfText] = []
    @State private var activeStroke: ShelfStroke?
    @State private var text = ""
    @State private var baseName = ""
    @State private var tool = "Preview"
    @State private var color: NSColor = .systemRed
    @State private var message: String?
    @State private var undoMarks: [String] = []
    @State private var revision = 0
    @State private var savedRevision = -1
    @State private var savedURL: URL?
    private var edited: Bool { !strokes.isEmpty || !labels.isEmpty }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Image name", text: $baseName).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("shelf.rename")
                Text(".\(url.pathExtension)").foregroundStyle(.secondary)
                Button("Rename") {
                    do { url = try model.renameShelfItem(url, baseName: baseName); message = "Renamed saved copy" }
                    catch { message = error.localizedDescription }
                }.accessibilityIdentifier("shelf.renameSave")
                Button("Copy") {
                    do {
                        if edited { let saved = try save(); model.copyToPasteboard(saved); message = "Copied annotated image" }
                        else { model.copyToPasteboard(url); message = "Copied image" }
                    } catch { message = error.localizedDescription }
                }
                Button("Save annotated copy") {
                    do { _ = try save(); message = "Annotated copy saved to the shelf" }
                    catch { message = error.localizedDescription }
                }.disabled(!edited).accessibilityIdentifier("shelf.saveAnnotation")
            }
            HStack(spacing: 10) {
                Picker("Annotation tool", selection: $tool) { Text("Preview").tag("Preview"); Text("Pen").tag("Pen"); Text("Text").tag("Text") }
                    .pickerStyle(.segmented).frame(width: 220).accessibilityIdentifier("shelf.annotationTool")
                ForEach(Array([NSColor.systemRed, .systemYellow, .systemBlue, .white, .black].enumerated()), id: \.offset) { index, choice in
                    Button { color = choice } label: { Circle().fill(Color(nsColor: choice)).frame(width: 16, height: 16).overlay(Circle().stroke(color == choice ? Color.primary : Color.clear, lineWidth: 2)) }
                        .buttonStyle(.plain).accessibilityLabel("Annotation color \(index + 1)")
                }
                if tool == "Text" { TextField("Text to place", text: $text).textFieldStyle(.roundedBorder).accessibilityIdentifier("shelf.annotationText") }
                Spacer(minLength: 0)
                Button("Undo mark") {
                    if let mark = undoMarks.popLast() { if mark == "Text" { labels.removeLast() } else { strokes.removeLast() }; revision += 1 }
                }
                    .disabled(!edited)
            }
            GeometryReader { geometry in
                let ratio = min(geometry.size.width / max(image.size.width, 1), geometry.size.height / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                ZStack {
                    Image(nsImage: image).resizable().scaledToFit()
                    Canvas { context, canvas in
                        for stroke in strokes + (activeStroke.map { [$0] } ?? []) {
                            var path = Path()
                            for (index, point) in stroke.points.enumerated() {
                                let p = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
                                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                            }
                            context.stroke(path, with: .color(Color(nsColor: stroke.color)), style: StrokeStyle(lineWidth: stroke.width * canvas.width, lineCap: .round, lineJoin: .round))
                        }
                        for label in labels {
                            context.draw(Text(label.text).font(.system(size: label.size * canvas.width, weight: .semibold)).foregroundColor(Color(nsColor: label.color)),
                                         at: CGPoint(x: label.point.x * canvas.width, y: label.point.y * canvas.height), anchor: .topLeading)
                        }
                    }
                }.frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard tool == "Pen" else { return }
                        let point = normalized(value.location, size: size)
                        if activeStroke == nil { activeStroke = ShelfStroke(points: [point], color: color, width: 3 / max(size.width, 1)) }
                        else { activeStroke?.points.append(point) }
                    }.onEnded { value in
                        if tool == "Pen", let stroke = activeStroke { strokes.append(stroke); undoMarks.append("Pen"); revision += 1; activeStroke = nil }
                        if tool == "Text", !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            labels.append(ShelfText(text: String(text.prefix(200)), point: normalized(value.location, size: size), color: color, size: 16 / max(size.width, 1)))
                            undoMarks.append("Text"); revision += 1
                        }
                    })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Image annotation canvas")
                    .accessibilityIdentifier("shelf.annotationCanvas")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color.black.opacity(0.08))
            HStack {
                Text(message ?? (tool == "Text" ? "Click the image to place text" : tool == "Pen" ? "Drag on the image to draw" : "Annotations save as a new shelf image"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(14).frame(minWidth: 570, minHeight: 360)
            .onAppear { baseName = url.deletingPathExtension().lastPathComponent }
    }
    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(size.width, 1))), y: min(1, max(0, point.y / max(size.height, 1))))
    }
    private func save() throws -> URL {
        if savedRevision == revision, let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        let data = try ShelfImageRenderer.png(image: image, strokes: strokes, labels: labels)
        let saved = try model.saveAnnotatedShelfImage(data, name: url.lastPathComponent)
        savedURL = saved; savedRevision = revision; return saved
    }
}
