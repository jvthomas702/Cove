import AppKit
import SwiftUI

/// Files tab → Browse: places on the left, the folder's files on the right, Spotlight results
/// under them while you search, and a bar for whatever is selected.
struct FileBrowserView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var browser: FileBrowser
    @FocusState private var searchFocused: Bool

    init(model: IslandModel) {
        self.model = model
        self.browser = model.fileBrowser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            toolbar
            HStack(alignment: .top, spacing: Theme.Space.s) {
                places
                list
            }
            .frame(maxHeight: .infinity)
            if !browser.selection.isEmpty { selectionBar.transition(.opacity) }
        }
        .animation(Theme.snappy, value: browser.selection.isEmpty)
        .onAppear { if browser.entries.isEmpty && browser.error == nil { browser.reload() } }
        .onChange(of: searchFocused) { _, active in if active { model.openByClick() } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            FilesModePicker(model: model)
            IconButton(systemImage: "chevron.left", size: 10, hit: 24) { browser.goBack() }
                .disabled(!browser.canGoBack)
                .help("Back").accessibilityLabel("Back").accessibilityIdentifier("files.back")
            IconButton(systemImage: "arrow.up", size: 10, hit: 24) { browser.goUp() }
                .disabled(!browser.canGoUp)
                .help("Enclosing folder").accessibilityLabel("Enclosing folder").accessibilityIdentifier("files.up")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(browser.crumbs.enumerated()), id: \.element) { index, url in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                            }
                            Button { browser.go(to: url) } label: {
                                Text(browser.displayName(url))
                                    .font(index == browser.crumbs.count - 1 ? Theme.Font.headline : Theme.Font.caption)
                                    .foregroundStyle(index == browser.crumbs.count - 1 ? Theme.ink : Theme.inkSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4).frame(height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .id(url)
                        }
                    }
                }
                .onChange(of: browser.folder) { _, folder in proxy.scrollTo(folder.standardizedFileURL, anchor: .trailing) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                TextField("Search files", text: $browser.query)
                    .textFieldStyle(.plain).font(Theme.Font.body)
                    .focused($searchFocused)
                    .onSubmit { if let first = browser.visibleEntries.first?.url ?? browser.searchResults.first { browser.open(first) } }
                    .accessibilityIdentifier("files.search")
                if browser.searching { ArcSpinner(color: Theme.inkSecondary, size: 10) }
                else if !browser.query.isEmpty {
                    Button { browser.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
                    }.buttonStyle(PressableStyle()).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).frame(width: 170, height: 24)
            .background(Capsule().fill(Theme.surface))
            Menu {
                Picker("Sort by", selection: $browser.sort) {
                    ForEach(FileBrowser.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show hidden files", isOn: $browser.showHidden)
                Divider()
                Button("Open in Finder") { NSWorkspace.shared.open(browser.folder) }
                Button("Refresh") { browser.reload() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 24, height: 24)
            .help("View options").accessibilityLabel("View options").accessibilityIdentifier("files.options")
        }
    }

    // MARK: Places

    private var places: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(browser.places) { place in
                let current = browser.folder.standardizedFileURL == place.url.standardizedFileURL
                Button { browser.go(to: place.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: place.symbol).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(current ? Theme.accent : Theme.inkSecondary)
                            .frame(width: 14)
                        Text(place.name).font(Theme.Font.caption).lineLimit(1)
                            .foregroundStyle(current ? Theme.ink : Theme.inkSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                        .fill(current ? Theme.surfaceRaised : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("files.place.\(place.name)")
            }
            Spacer(minLength: 0)
        }
        .frame(width: 112)
        .padding(4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
    }

    // MARK: List

    private var list: some View {
        let entries = browser.visibleEntries
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                if let error = browser.error {
                    note(symbol: "lock", text: error)
                } else if entries.isEmpty && !browser.loading && !browser.isSearching {
                    note(symbol: "folder", text: browser.query.isEmpty ? "This folder is empty" : "Nothing here matches “\(browser.query)”")
                }
                ForEach(entries) { entry in
                    FileRow(url: entry.url, isFolder: entry.isFolder, detail: detail(for: entry), model: model, browser: browser)
                }
                if browser.isSearching {
                    HStack {
                        SectionTitle(title: "On this Mac", count: browser.searchResults.count)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.top, 6)
                    if browser.searchResults.isEmpty && !browser.searching {
                        note(symbol: "magnifyingglass", text: "Spotlight found nothing named “\(browser.query)”")
                    }
                    ForEach(browser.searchResults, id: \.self) { url in
                        FileRow(url: url, isFolder: FileBrowser.isBrowsableFolder(url),
                                detail: FileManager.default.displayName(atPath: url.deletingLastPathComponent().path),
                                model: model, browser: browser)
                    }
                }
            }
            .padding(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
        .accessibilityIdentifier("files.list")
    }

    private func note(symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
    }

    private func detail(for entry: FileEntry) -> String {
        if entry.isFolder { return entry.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "" }
        var parts: [String] = []
        if let size = entry.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified = entry.modified { parts.append(modified.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    // MARK: Selection

    private var selectionBar: some View {
        let urls = browser.selectedURLs()
        return HStack(spacing: 8) {
            Text("\(urls.count) selected").font(Theme.Font.number).foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
            ConvertMenu(model: model, urls: urls)
            ChipButton(title: "Shelf", systemImage: "tray.and.arrow.down") { model.addToShelf(urls) }
                .help("Keep on the shelf").accessibilityIdentifier("files.keep")
            ChipButton(title: "Open", systemImage: "arrow.up.forward.app") { urls.forEach(browser.open) }
                .accessibilityIdentifier("files.open")
            IconButton(systemImage: "xmark", size: 9, hit: 22) { browser.selection = [] }
                .help("Clear selection").accessibilityLabel("Clear selection")
        }
    }
}

/// One file or folder: click selects (⌘ or ⇧ to add), double-click opens, drag it into any app.
private struct FileRow: View {
    let url: URL
    let isFolder: Bool
    let detail: String
    @ObservedObject var model: IslandModel
    @ObservedObject var browser: FileBrowser
    @State private var hovering = false

    var body: some View {
        let selected = browser.selection.contains(url)
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
            Text(url.lastPathComponent)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
            if isFolder {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.18) : (hovering ? Theme.surfaceRaised : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { browser.open(url) }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            browser.toggleSelection(url, extend: flags.contains(.command) || flags.contains(.shift))
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("files.item.\(url.lastPathComponent)")
        .contextMenu {
            let targets = selected ? browser.selectedURLs() : [url]
            Button(isFolder ? "Open" : "Open in default app") { browser.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
            if !isFolder {
                Button("Keep on Shelf") { model.addToShelf(targets) }
                Button("Copy") { model.copyToPasteboard(url) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
            }
            ConvertMenuItems(model: model, urls: targets)
        }
    }
}

/// Shelf | Browse, at the start of the Files tab's top row.
struct FilesModePicker: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Picker("Files", selection: $model.filesMode) {
            ForEach(IslandModel.FilesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 124)
        .accessibilityIdentifier("files.mode")
    }
}

/// "Convert ▾" with what the files can become (Combine into PDF, Convert to JPEG…).
struct ConvertMenu: View {
    @ObservedObject var model: IslandModel
    let urls: [URL]
    var title = "Convert"

    var body: some View {
        let options = FileConverter.conversions(for: urls)
        if !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    Button(option.title(count: urls.count)) { model.convert(urls, to: option) }
                }
            } label: {
                HStack(spacing: 4) {
                    if model.converting { ArcSpinner(color: Theme.accent, size: 10) }
                    else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .bold)) }
                    Text(model.converting ? "Converting…" : title)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(.system(size: 11, weight: .semibold, design: Theme.isTerminal ? .monospaced : .rounded))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
            .disabled(model.converting)
            .accessibilityIdentifier("files.convert")
        }
    }
}

/// The same choices as a "Convert" submenu, for context menus.
struct ConvertMenuItems: View {
    @ObservedObject var model: IslandModel
    let urls: [URL]

    var body: some View {
        let options = FileConverter.conversions(for: urls)
        if !options.isEmpty {
            Divider()
            Menu("Convert") {
                ForEach(options) { option in
                    Button(option.title(count: urls.count)) { model.convert(urls, to: option) }
                }
            }
            .disabled(model.converting)
        }
    }
}
