import AppKit
import Carbon.HIToolbox
import SwiftUI
import QuotaCore

/// A system-wide shortcut that toggles the menu panel, after openusage.
/// Carbon's hot-key API: no accessibility permission, and the key is not
/// passed on to the frontmost app.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: Hotkey?

    func apply(_ hotkey: Hotkey?) {
        guard hotkey != registered else { return }
        unregister()
        registered = hotkey
        guard let hotkey else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x5142_4152), id: 1)  // "QBAR"
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.shared.action?() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    // MARK: Conversion

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    static func display(_ event: NSEvent) -> String {
        let flags = event.modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        text += special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        return text
    }
}

/// Click, press a combination with ⌘, ⌥ or ⌃; Esc cancels, ⌫ clears.
struct HotkeyRecorder: View {
    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: Design.space2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L10n.t("Press a shortcut…", "请按下快捷键…") : (hotkey?.display ?? L10n.t("Record shortcut", "录制快捷键")))
                    .font(.system(size: 12, weight: .medium, design: hotkey == nil || recording ? .default : .monospaced))
                    .frame(minWidth: 140)
            }
            .glassAction(prominent: recording)
            if hotkey != nil, !recording {
                Button(L10n.t("Clear", "清除")) { onChange(nil) }
                    .glassAction()
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                onChange(nil); stop(); return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            onChange(Hotkey(keyCode: UInt32(event.keyCode), modifiers: GlobalHotkey.carbonModifiers(flags), display: GlobalHotkey.display(event)))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
