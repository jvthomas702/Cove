import AppKit
import SwiftUI
import Combine

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// The physical notch, measured from the menu-bar areas on either side of it.
    /// Macs without a notch get a "virtual" one so Cove still works on external displays.
    var notchSize: CGSize {
        guard hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return CGSize(width: 190, height: 28)
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    var acceptsKeyboardInput = false
    override var canBecomeKey: Bool { acceptsKeyboardInput }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The accessory app may have no Edit menu. Route text shortcuts to this panel's
        // field editor instead of the application that remains active behind the notch.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard acceptsKeyboardInput, modifiers.contains(.command),
              !modifiers.contains(.control), !modifiers.contains(.option),
              let editor = firstResponder as? NSTextView else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where !modifiers.contains(.shift): editor.selectAll(self)
        case "c" where !modifiers.contains(.shift): editor.copy(self)
        case "x" where !modifiers.contains(.shift): editor.cut(self)
        case "v" where !modifiers.contains(.shift): editor.paste(self)
        case "z":
            guard let undo = editor.undoManager else { return super.performKeyEquivalent(with: event) }
            if modifiers.contains(.shift) { if undo.canRedo { undo.redo() } }
            else if undo.canUndo { undo.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Hosts the SwiftUI island. Lets clicks land without activating Cove first, and does hover
/// detection with an always-active tracking area (SwiftUI's onHover can miss events in a
/// non-key panel). Hover is measured against the island's real shape, not the shadow padding.
final class IslandHostingView: NSHostingView<IslandRootView> {
    weak var model: IslandModel?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        update(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        update(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Resizing a tracking area can emit an exit even while the pointer remains over the island.
        update(with: event)
    }

    private func update(with event: NSEvent) {
        guard let model, let window else { return }
        let island = model.currentSize
        let bounds = window.frame.size
        // Window coordinates: origin bottom-left, island hugs the top centre.
        let rect = NSRect(
            x: (bounds.width - island.width) / 2,
            y: bounds.height - island.height,
            width: island.width,
            height: island.height + 4
        )
        model.setHovering(rect.contains(window.mouseLocationOutsideOfEventStream))
    }
}

/// Owns the panel and keeps it exactly the size of the island, so the rest of the menu bar stays clickable.
@MainActor
final class NotchWindowController {
    let model: IslandModel
    let panel: NotchPanel
    private var screen: NSScreen?
    private var shrinkWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    /// Extra room around large states so the drop shadow isn't clipped.
    private static let shadowPad = CGSize(width: 48, height: 28)

    init(model: IslandModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        panel.acceptsMouseMovedEvents = true
        let host = IslandHostingView(rootView: IslandRootView(model: model))
        host.model = model
        host.sizingOptions = []
        panel.contentView = host
        // Typing is possible in the open island and in a done banner's reply field.
        panel.acceptsKeyboardInput = model.expanded
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak panel, weak model] _ in
                MainActor.assumeIsolated {
                    guard let panel, let model else { return }
                    let accepts = model.expanded || model.bannerAcceptsReply
                    guard accepts != panel.acceptsKeyboardInput else { return }
                    panel.acceptsKeyboardInput = accepts
                    if !accepts { panel.resignKey() }
                }
            }
            .store(in: &cancellables)

        relocate()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        })

        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setMenuTracking(tracking) }
            })
        }

        // @Published emits before currentSize is stored. Resizing/displaying synchronously can
        // lay out SwiftUI with the old height, clipping new controls below the visible island.
        model.$currentSize
            .removeDuplicates()
            .sink { [weak self] size in
                Task { @MainActor [weak self] in
                    guard let self, self.model.currentSize == size else { return }
                    self.resize(to: size)
                }
            }
            .store(in: &cancellables)

        panel.orderFrontRegardless()
    }

    /// Picks the screen with a notch (or the main screen) and re-measures.
    func relocate() {
        guard let s = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        screen = s
        model.availableIslandWidth = max(300, s.frame.width - 48)
        model.hasHardwareNotch = s.hasNotch
        model.notchSize = s.notchSize
        applyFrame(windowSize(for: model.currentSize))
    }

    private func windowSize(for island: CGSize) -> CGSize {
        let p = model.presentation
        let pad = (p == .expanded || p == .banner || p == .approval) ? Self.shadowPad : .zero
        return CGSize(width: island.width + pad.width, height: island.height + pad.height)
    }

    private func applyFrame(_ size: CGSize) {
        guard let screen else { return }
        let f = screen.frame
        let rect = NSRect(
            x: (f.midX - size.width / 2).rounded(),
            y: f.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(rect, display: true)
    }

    /// Grow immediately; shrink only after the spring animation has finished.
    private func resize(to island: CGSize) {
        shrinkWork?.cancel()
        let target = windowSize(for: island)
        let current = panel.frame.size
        let interim = CGSize(width: max(target.width, current.width), height: max(target.height, current.height))
        applyFrame(interim)
        guard interim != target else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyFrame(target) }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
    }
}
