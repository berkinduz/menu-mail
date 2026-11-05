import Carbon
import Foundation
import Observation

enum GlobalShortcutPreset: String, CaseIterable, Identifiable, Sendable {
    case disabled, optionCommandM, controlOptionM

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .optionCommandM: "⌥⌘M"
        case .controlOptionM: "⌃⌥M"
        }
    }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .disabled: nil
        case .optionCommandM: UInt32(optionKey | cmdKey)
        case .controlOptionM: UInt32(controlKey | optionKey)
        }
    }
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject, Sendable {
    func register(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

@MainActor
@Observable
final class GlobalShortcut {
    private let registrar: any GlobalShortcutRegistering
    private(set) var registrationFailed = false

    init(registrar: any GlobalShortcutRegistering = CarbonShortcutRegistration()) {
        self.registrar = registrar
    }

    func register(preset: GlobalShortcutPreset, onToggle: @escaping @MainActor () -> Void) {
        unregister()
        guard let modifiers = preset.modifiers else { return }
        registrationFailed = !registrar.register(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers, onPressed: onToggle)
    }

    func unregister() {
        registrar.unregister()
        registrationFailed = false
    }

    deinit {
        let registrar = registrar
        Task { @MainActor in registrar.unregister() }
    }
}

private let menuMailHotKeySignature: OSType = 0x4D4D6169

@MainActor
private final class CarbonShortcutRegistration: GlobalShortcutRegistering {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    fileprivate var onPressed: (@MainActor () -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.onPressed = onPressed
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), menuMailHotKeyHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard handlerStatus == noErr else {
            unregister()
            return false
        }
        let identifier = EventHotKeyID(signature: menuMailHotKeySignature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        onPressed = nil
    }
}

private func menuMailHotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
    )
    guard status == noErr, identifier.signature == menuMailHotKeySignature, identifier.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    // Application-target Carbon handlers are delivered by the main event loop.
    let registration = Unmanaged<CarbonShortcutRegistration>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated {
        registration.onPressed?()
        return noErr
    }
}
