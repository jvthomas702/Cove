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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
        model?.setHovering(false)
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
        model.setHovering(rect.contains(event.locationInWindow))
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

        relocate()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        })

        // recompute() sets `presentation` before `currentSize`, so the presentation is current here.
        model.$currentSize
            .removeDuplicates()
            .sink { [weak self] size in self?.resize(to: size) }
            .store(in: &cancellables)

        panel.orderFrontRegardless()
    }

    /// Picks the screen with a notch (or the main screen) and re-measures.
    func relocate() {
        guard let s = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        screen = s
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }
}
