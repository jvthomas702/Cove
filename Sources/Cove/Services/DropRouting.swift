import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a file dragged onto the island ends up.
enum DropTarget: String, CaseIterable {
    /// Send it with AirDrop.
    case airDrop
    /// Keep it on the shelf.
    case keep
}

/// The pure parts of dropping files on the island, kept apart from SwiftUI so they can be tested.
enum DropRouting {
    /// The island's coordinate space, shared by the drop handler and the target frames.
    static let space = "island.drop"

    /// The files a drop carries: file URLs only (no web links), standardized, each once, in drag order.
    static func acceptedFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let file = url.standardizedFileURL
            return seen.insert(file.path).inserted ? file : nil
        }
    }

    /// The target under the pointer. Anywhere else on the island keeps the file, as before AirDrop existed.
    static func target(at point: CGPoint, in frames: [DropTarget: CGRect], airDropEnabled: Bool) -> DropTarget {
        guard airDropEnabled else { return .keep }
        return DropTarget.allCases.first { frames[$0]?.contains(point) == true } ?? .keep
    }
}

/// The drop targets publish their frames in the island's coordinate space, so the island's single
/// drop handler knows which one is under the pointer (nested `onDrop`s fight over `isTargeted`).
struct DropTargetFramesKey: PreferenceKey {
    static let defaultValue: [DropTarget: CGRect] = [:]
    static func reduce(value: inout [DropTarget: CGRect], nextValue: () -> [DropTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func dropTargetFrame(_ target: DropTarget) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DropTargetFramesKey.self, value: [target: proxy.frame(in: .named(DropRouting.space))])
        })
    }
}

/// Handles every file drag over the island: opening it, highlighting the target under the pointer,
/// and routing the drop to AirDrop or the shelf.
struct IslandDropDelegate: DropDelegate {
    let model: IslandModel

    @MainActor private func target(_ info: DropInfo) -> DropTarget {
        DropRouting.target(at: info.location, in: model.dropFrames, airDropEnabled: model.config.airDropDropZone)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.fileURL]) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            model.setDropTargeted(true)
            model.setDropHover(target(info))
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { model.setDropHover(target(info)) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { model.setDropTargeted(false) }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        MainActor.assumeIsolated {
            model.receiveDrop(providers, target: target(info))
            model.setDropTargeted(false)
        }
        return true
    }
}
