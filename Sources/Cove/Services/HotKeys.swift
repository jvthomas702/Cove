import Carbon.HIToolbox

/// System-wide keyboard shortcuts. Carbon hot keys work without Accessibility permission.
///
/// ⌃⌥Space opens or closes the island. While Claude is asking permission:
/// ⌃⌥Y allows, ⌃⌥N denies, ⌃⌥A always allows, ⌃⌥T answers in the terminal.
@MainActor
final class HotKeys {
    enum Action: UInt32 { case toggle = 1, allow, deny, alwaysAllow, terminal }

    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    nonisolated private static let signature: OSType = 0x434F5645 // "COVE"

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeys.signature, let action = Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { hotKeys.onAction?(action) }
            return noErr
        }, 1, &spec, context, &handler)

        register(.toggle, key: kVK_Space)
        register(.allow, key: kVK_ANSI_Y)
        register(.deny, key: kVK_ANSI_N)
        register(.alwaysAllow, key: kVK_ANSI_A)
        register(.terminal, key: kVK_ANSI_T)
    }

    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ action: Action, key: Int) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }
}
