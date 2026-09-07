import AppKit
import Carbon

struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let stop = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘R")
}

/// Carbon hotkeys do not require Accessibility or Input Monitoring permissions.
final class GlobalHotKey {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let eventID: EventHotKeyID
    private let callback: @MainActor () -> Void
    private(set) var registrationStatus: OSStatus = noErr
    var isRegistered: Bool { key != nil && registrationStatus == noErr }

    init(shortcut: HotKeyShortcut = .stop, id: UInt32 = 1,
         callback: @escaping @MainActor () -> Void) {
        self.callback = callback
        eventID = EventHotKeyID(signature: 0x5241494E, id: id)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        registrationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            var received = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard result == noErr, received.signature == hotKey.eventID.signature,
                  received.id == hotKey.eventID.id else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in hotKey.callback() }
            return noErr
        }, 1, &event, context, &handler)
        guard registrationStatus == noErr else { return }
        registrationStatus = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            eventID, GetApplicationEventTarget(), 0, &key)
        if registrationStatus != noErr {
            NSLog("Rainy Screen: hotkey unavailable (%d)", registrationStatus)
        }
    }
    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Receives keys only while this control is focused in the settings dialog.
final class ShortcutRecorder: NSTextField {
    var shortcut: HotKeyShortcut?
    var onChange: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if event.keyCode == UInt16(kVK_Escape) { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            stringValue = L10n.text("Control・Option・Commandのいずれかを含めてください", "Include Control, Option, or Command")
            shortcut = nil; onChange?(); return
        }
        var modifiers: UInt32 = 0
        var label = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"),
                                       (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { modifiers |= UInt32(carbon); label += symbol }
        }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
            117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20"]
        label += special[event.keyCode] ?? characters.uppercased()
        shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        stringValue = label; onChange?()
    }
}
