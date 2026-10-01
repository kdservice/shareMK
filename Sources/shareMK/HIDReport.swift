import CoreGraphics
import Foundation

struct HIDKeyboardReport {
    var modifier: UInt8 = 0
    var keys: [UInt8] = []

    var data: Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = modifier
        for (index, key) in keys.prefix(6).enumerated() {
            bytes[index + 2] = key
        }
        return Data(bytes)
    }
}

struct HIDMouseReport {
    var buttons: UInt8
    var x: Int8
    var y: Int8
    var wheel: Int8

    init(buttons: UInt8 = 0, x: Int8 = 0, y: Int8 = 0, wheel: Int8 = 0) {
        self.buttons = buttons
        self.x = x
        self.y = y
        self.wheel = wheel
    }

    init(buttons: UInt8, dx: Int64, dy: Int64, wheelDelta: Int64, settings: MouseSettings) {
        self.init(
            buttons: buttons,
            x: Self.clamp(Self.scalePointerDelta(dx, scale: settings.scale), limit: settings.clamp),
            y: Self.clamp(Self.scalePointerDelta(dy, scale: settings.scale), limit: settings.clamp),
            wheel: Self.clamp(wheelDelta, limit: settings.clamp)
        )
    }

    var data: Data {
        Data([buttons, UInt8(bitPattern: x), UInt8(bitPattern: y), UInt8(bitPattern: wheel)])
    }

    var bootData: Data {
        Data([buttons, UInt8(bitPattern: x), UInt8(bitPattern: y)])
    }

    private static func scalePointerDelta(_ value: Int64, scale: Double) -> Int64 {
        guard value != 0 else { return 0 }
        let scaled = Double(value) * scale
        if scaled > 0 { return max(1, Int64(scaled.rounded())) }
        return min(-1, Int64(scaled.rounded()))
    }

    private static func clamp(_ value: Int64, limit: Int) -> Int8 {
        let boundedLimit = max(1, min(127, limit))
        return Int8(max(-boundedLimit, min(boundedLimit, Int(value))))
    }
}

struct HIDInputState {
    private(set) var pressedKeys: Set<UInt8> = []
    private(set) var modifier: UInt8 = 0
    private(set) var mouseButtons: UInt8 = 0

    mutating func reset() {
        pressedKeys.removeAll()
        modifier = 0
        mouseButtons = 0
    }

    mutating func updateFlags(_ flags: CGEventFlags, swapCommandAndControl: Bool) {
        var value: UInt8 = 0
        if flags.contains(.maskControl) { value |= 0x01 }   // Mac Control -> Windows Ctrl
        if flags.contains(.maskShift) { value |= 0x02 }
        if flags.contains(.maskAlternate) { value |= 0x04 } // Mac Option -> Windows Alt
        if flags.contains(.maskCommand) { value |= 0x08 }   // Mac Command -> Windows Win
        modifier = value
    }

    mutating func clearKeyboard() {
        pressedKeys.removeAll()
        modifier = 0
    }

    mutating func keyDown(macKeyCode: Int) {
        guard let hid = Self.keyMap[macKeyCode], pressedKeys.count < 6 else { return }
        pressedKeys.insert(hid)
    }

    mutating func keyUp(macKeyCode: Int) {
        guard let hid = Self.keyMap[macKeyCode] else { return }
        pressedKeys.remove(hid)
    }

    mutating func setMouseButton(_ bit: UInt8, pressed: Bool) {
        if pressed {
            mouseButtons |= bit
        } else {
            mouseButtons &= ~bit
        }
    }

    var keyboardReport: HIDKeyboardReport {
        HIDKeyboardReport(modifier: modifier, keys: Array(pressedKeys).sorted())
    }

    func mouseReport(dx: Int64, dy: Int64, wheel: Int64, settings: MouseSettings = MouseSettings()) -> HIDMouseReport {
        HIDMouseReport(buttons: mouseButtons, dx: dx, dy: dy, wheelDelta: wheel, settings: settings)
    }

    private static let keyMap: [Int: UInt8] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A,
        6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14,
        13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23,
        23: 0x22, 24: 0x2E, 25: 0x26, 26: 0x24, 27: 0x2D,
        28: 0x25, 29: 0x27, 30: 0x30, 31: 0x12, 32: 0x18,
        33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28, 37: 0x0F,
        38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31,
        43: 0x36, 44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37,
        48: 0x2B, 49: 0x2C, 50: 0x35, 51: 0x2A, 53: 0x29,
        65: 0x63, 67: 0x55, 69: 0x57, 71: 0x53, 75: 0x54,
        76: 0x58, 78: 0x56, 81: 0x67, 82: 0x62, 83: 0x59,
        84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E,
        89: 0x5F, 91: 0x60, 92: 0x61, 96: 0x3E, 97: 0x3F,
        98: 0x40, 99: 0x3D, 100: 0x41, 101: 0x42, 103: 0x44,
        109: 0x4D, 111: 0x4A, 113: 0x4B, 117: 0x4C,
        118: 0x3A, 119: 0x4D, 120: 0x3C, 121: 0x4E,
        122: 0x3B, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52
    ]
}
