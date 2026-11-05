import Carbon
import Testing
@testable import Envl

@MainActor
private final class ShortcutRegistrationFixture: GlobalShortcutRegistering {
    var combinations: [(UInt32, UInt32)] = []
    var unregisterCalls = 0
    var onPressed: (@MainActor () -> Void)?
    var succeeds = true

    func register(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping @MainActor () -> Void) -> Bool {
        combinations.append((keyCode, modifiers))
        self.onPressed = onPressed
        return succeeds
    }
    func unregister() {
        unregisterCalls += 1
        onPressed = nil
    }
}

@MainActor
struct GlobalShortcutTests {
    @Test func presetsRegisterTheSelectedCombinationAndInvokeToggle() {
        let registration = ShortcutRegistrationFixture()
        let shortcut = GlobalShortcut(registrar: registration)
        var toggles = 0
        shortcut.register(preset: .optionCommandM) { toggles += 1 }
        #expect(registration.combinations.count == 1)
        #expect(registration.combinations[0].0 == UInt32(kVK_ANSI_M))
        #expect(registration.combinations[0].1 == UInt32(optionKey | cmdKey))
        registration.onPressed?()
        #expect(toggles == 1)

        shortcut.register(preset: .controlOptionM) { toggles += 1 }
        #expect(registration.unregisterCalls == 2)
        #expect(registration.combinations[1].1 == UInt32(controlKey | optionKey))
        #expect(!shortcut.registrationFailed)
    }

    @Test func disablingUnregistersAndDoesNotRegisterAnotherShortcut() {
        let registration = ShortcutRegistrationFixture()
        let shortcut = GlobalShortcut(registrar: registration)
        shortcut.register(preset: .optionCommandM) {}
        shortcut.register(preset: .disabled) {}
        #expect(registration.combinations.count == 1)
        #expect(registration.onPressed == nil)
        shortcut.unregister()
        #expect(registration.unregisterCalls == 3)
    }

    @Test func aRegistrationConflictIsReported() {
        let registration = ShortcutRegistrationFixture()
        registration.succeeds = false
        let shortcut = GlobalShortcut(registrar: registration)
        shortcut.register(preset: .controlOptionM) {}
        #expect(shortcut.registrationFailed)
        shortcut.register(preset: .disabled) {}
        #expect(!shortcut.registrationFailed)
    }
}
