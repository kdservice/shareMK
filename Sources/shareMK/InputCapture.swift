import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
final class InputCapture {
    var onSwitch: ((Int) -> Void)?
    var onKeyboard: ((HIDKeyboardReport) -> Void)?
    var onMouse: ((UInt8, Int64, Int64, Int64) -> Void)?
    var onMouseButton: ((HIDMouseReport) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var inputState = HIDInputState()
    private var retryTimer: Timer?
    private var permissionPromptRequested = false
    private var childMode = false
    private var outputMode: OutputMode = .both
    private var suppressModifiersUntilReleased = false

    func start() {
        installHotKeys()
        guard eventTap == nil else { return }
        requestInputPermissionsIfNeeded(prompt: !permissionPromptRequested)
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { value, type in
            value | CGEventMask(1 << type.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
                return capture.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        )
        guard let eventTap else {
            onDiagnostic?("INPUT_EVENT_TAP_FAILED")
            scheduleRetry()
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        onDiagnostic?("INPUT_EVENT_TAP_READY")
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        uninstallHotKeys()
    }
    private func requestInputPermissionsIfNeeded(prompt: Bool) {
        let accessibilityAllowed = AXIsProcessTrusted()
        let listenAllowed = CGPreflightListenEventAccess()
        onDiagnostic?("INPUT_PERMISSION_STATE accessibility=\(accessibilityAllowed) listen=\(listenAllowed)")
        guard prompt else { return }
        permissionPromptRequested = true
        if !accessibilityAllowed {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            onDiagnostic?("INPUT_ACCESSIBILITY_PERMISSION_REQUESTED")
        }
        if !listenAllowed {
            _ = CGRequestListenEventAccess()
            onDiagnostic?("INPUT_MONITORING_PERMISSION_REQUESTED")
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.eventTap == nil { self.start() }
            }
        }
    }

    func reloadHotKeys() {
        uninstallHotKeys()
        installHotKeys()
    }

    private func installHotKeys() {
        guard hotKeyRefs.isEmpty else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let capture = Unmanaged<InputCapture>.fromOpaque(userData).takeUnretainedValue()
            let slot = Int(hotKeyID.id)
            Task { @MainActor in
                capture.onSwitch?(slot)
            }
            return noErr
        }, 1, &eventType, refcon, &hotKeyHandler)

        let bindings = hotKeyBindings()
        for binding in bindings {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x534D4B48), id: UInt32(binding.slot))
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                onDiagnostic?("HOTKEY_REGISTER_FAILED slot=\(binding.slot) status=\(status)")
            }
        }
        onDiagnostic?("HOTKEY_REGISTERED mode=\(AppSettings.shared.hotKeyMode.rawValue) count=\(hotKeyRefs.count)")
    }

    private func uninstallHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
        hotKeyHandler = nil
    }

    func setChildMode(_ enabled: Bool, outputMode: OutputMode = .both) {
        childMode = enabled
        self.outputMode = outputMode
        suppressModifiersUntilReleased = enabled && outputMode.sendsKeyboard
        inputState.reset()
        onKeyboard?(HIDKeyboardReport())
        onMouseButton?(HIDMouseReport())
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let slot = switchSlot(for: keyCode), isSwitchHotkey(event: event) {
                inputState.reset()
                onKeyboard?(HIDKeyboardReport())
                onMouseButton?(HIDMouseReport())
                onSwitch?(slot)
                return nil
            }
        }

        guard childMode else { return Unmanaged.passUnretained(event) }

        if suppressModifiersUntilReleased {
            if hasSwitchModifiers(event.flags) {
                inputState.clearKeyboard()
                onKeyboard?(HIDKeyboardReport())
                return nil
            }
            suppressModifiersUntilReleased = false
        }

        switch type {
        case .keyDown:
            guard outputMode.sendsKeyboard else { return Unmanaged.passUnretained(event) }
            inputState.updateFlags(event.flags, swapCommandAndControl: AppSettings.shared.swapCommandAndControl)
            inputState.keyDown(macKeyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)))
            onKeyboard?(inputState.keyboardReport)
            return nil
        case .keyUp:
            guard outputMode.sendsKeyboard else { return Unmanaged.passUnretained(event) }
            inputState.updateFlags(event.flags, swapCommandAndControl: AppSettings.shared.swapCommandAndControl)
            inputState.keyUp(macKeyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)))
            onKeyboard?(inputState.keyboardReport)
            return nil
        case .flagsChanged:
            guard outputMode.sendsKeyboard else { return Unmanaged.passUnretained(event) }
            inputState.updateFlags(event.flags, swapCommandAndControl: AppSettings.shared.swapCommandAndControl)
            onKeyboard?(inputState.keyboardReport)
            return nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            onMouse?(inputState.mouseButtons, event.getIntegerValueField(.mouseEventDeltaX), event.getIntegerValueField(.mouseEventDeltaY), 0)
            return nil
        case .leftMouseDown:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x01, pressed: true)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .leftMouseUp:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x01, pressed: false)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .rightMouseDown:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x02, pressed: true)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .rightMouseUp:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x02, pressed: false)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .otherMouseDown:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x04, pressed: true)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .otherMouseUp:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            inputState.setMouseButton(0x04, pressed: false)
            onMouseButton?(inputState.mouseReport(dx: 0, dy: 0, wheel: 0))
            return nil
        case .scrollWheel:
            guard outputMode.sendsMouse else { return Unmanaged.passUnretained(event) }
            onMouse?(inputState.mouseButtons, 0, 0, event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func hotKeyBindings() -> [(slot: Int, keyCode: UInt32, modifiers: UInt32)] {
        switch AppSettings.shared.hotKeyMode {
        case .controlOptionCommandNumber:
            return [18, 19, 20, 21, 23, 22, 26, 28, 25, 29].enumerated().map {
                (slot: $0.offset + 1, keyCode: UInt32($0.element), modifiers: UInt32(controlKey | optionKey | cmdKey))
            }
        case .controlCommandFunction:
            return [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].enumerated().map {
                (slot: $0.offset + 1, keyCode: UInt32($0.element), modifiers: UInt32(controlKey | cmdKey))
            }
        }
    }

    private func isSwitchHotkey(event: CGEvent) -> Bool {
        switch AppSettings.shared.hotKeyMode {
        case .controlOptionCommandNumber:
            event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate) && event.flags.contains(.maskCommand)
        case .controlCommandFunction:
            event.flags.contains(.maskControl) && event.flags.contains(.maskCommand) && !event.flags.contains(.maskAlternate)
        }
    }

    private func hasSwitchModifiers(_ flags: CGEventFlags) -> Bool {
        switch AppSettings.shared.hotKeyMode {
        case .controlOptionCommandNumber:
            flags.contains(.maskControl) || flags.contains(.maskAlternate) || flags.contains(.maskCommand)
        case .controlCommandFunction:
            flags.contains(.maskControl) || flags.contains(.maskCommand)
        }
    }

    private func switchSlot(for keyCode: Int) -> Int? {
        switch AppSettings.shared.hotKeyMode {
        case .controlOptionCommandNumber:
            switch keyCode {
            case 18: return 1
            case 19: return 2
            case 20: return 3
            case 21: return 4
            case 23: return 5
            case 22: return 6
            case 26: return 7
            case 28: return 8
            case 25: return 9
            case 29: return 10
            default: return nil
            }
        case .controlCommandFunction:
            switch keyCode {
            case kVK_F1: return 1
            case kVK_F2: return 2
            case kVK_F3: return 3
            case kVK_F4: return 4
            case kVK_F5: return 5
            case kVK_F6: return 6
            case kVK_F7: return 7
            case kVK_F8: return 8
            case kVK_F9: return 9
            case kVK_F10: return 10
            case kVK_F11: return 11
            case kVK_F12: return 12
            default: return nil
            }
        }
    }
}
