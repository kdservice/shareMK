import CoreBluetooth
import Foundation

/// Bluetooth HID Service 1.0 / HID over GATT Profile 1.0.
/// Service registration and advertising intentionally use different UUID encodings.
enum HIDProfile {
    static let advertisedName = "shareMK"
    static var advertisedUUID: CBUUID { CBUUID(string: "1812") }

    // macOS rejects registering the reserved 16-bit HID service (CBError 8).
    // The equivalent Bluetooth base UUID is accepted; see Diagnostics/peripheral-probe.log.
    static func serviceUUID(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    enum Attribute: String, CaseIterable {
        case information, reportMap, controlPoint, protocolMode
        case keyboardInput, keyboardOutput, mouseInput
        case bootKeyboardInput, bootKeyboardOutput, bootMouseInput
        case battery, manufacturer, pnpID

        var uuid: CBUUID {
            let assigned: String
            switch self {
            case .information: assigned = "2A4A"
            case .reportMap: assigned = "2A4B"
            case .controlPoint: assigned = "2A4C"
            case .protocolMode: assigned = "2A4E"
            case .keyboardInput, .keyboardOutput, .mouseInput: assigned = "2A4D"
            case .bootKeyboardInput: assigned = "2A22"
            case .bootKeyboardOutput: assigned = "2A32"
            case .bootMouseInput: assigned = "2A33"
            case .battery: assigned = "2A19"
            case .manufacturer: assigned = "2A29"
            case .pnpID: assigned = "2A50"
            }
            return CBUUID(string: assigned)
        }

        var isInput: Bool {
            switch self {
            case .keyboardInput, .mouseInput, .bootKeyboardInput, .bootMouseInput: true
            default: false
            }
        }

        var isWritable: Bool {
            switch self {
            case .keyboardOutput, .bootKeyboardOutput, .protocolMode, .controlPoint: true
            default: false
            }
        }

        var properties: CBCharacteristicProperties {
            switch self {
            case .controlPoint: [.writeWithoutResponse]
            case .protocolMode: [.read, .writeWithoutResponse]
            case .keyboardOutput, .bootKeyboardOutput: [.read, .write, .writeWithoutResponse]
            case .keyboardInput, .mouseInput, .bootKeyboardInput, .bootMouseInput:
                [.read, .notify, .notifyEncryptionRequired]
            default: [.read]
            }
        }

        var reportReference: Data? {
            switch self {
            case .keyboardInput: Data([1, 1])
            case .keyboardOutput: Data([1, 2])
            case .mouseInput: Data([2, 1])
            default: nil
            }
        }

        func makeCharacteristic() -> CBMutableCharacteristic {
            var permissions: CBAttributePermissions = []
            if properties.contains(.read) { permissions.insert(.readEncryptionRequired) }
            if isWritable { permissions.insert(.writeEncryptionRequired) }
            // Dynamic values ensure encryption is enforced and long reads reach our handler.
            let characteristic = CBMutableCharacteristic(type: uuid, properties: properties,
                                                         value: nil, permissions: permissions)
            if let reference = reportReference {
                characteristic.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: reference as NSData)]
            }
            // CoreBluetooth creates the CCCD for notifying characteristics.
            return characteristic
        }
    }

    struct Session {
        var protocolMode: UInt8 = 1 // Report protocol until a host requests Boot protocol.
        var keyboardLEDs: UInt8 = 0
        var suspended = false
    }

    static func value(for attribute: Attribute, session: Session) -> Data? {
        switch attribute {
        case .information: Data([0x11, 0x01, 0x00, 0x02])
        case .reportMap: reportMap
        case .protocolMode: Data([session.protocolMode])
        case .keyboardInput, .bootKeyboardInput: Data(repeating: 0, count: 8)
        case .mouseInput: Data(repeating: 0, count: 4)
        case .bootMouseInput: Data(repeating: 0, count: 3)
        case .keyboardOutput, .bootKeyboardOutput: Data([session.keyboardLEDs])
        case .controlPoint: nil
        case .battery: Data([100]) // Pairing prototype; no battery telemetry yet.
        case .manufacturer: Data("shareMK".utf8)
        // 0xFFFF is a development identifier, not another manufacturer's assigned ID.
        case .pnpID: Data([0x01, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x01])
        }
    }

    static func read(_ attribute: Attribute, session: Session, offset: Int) -> Result<Data, CBATTError> {
        guard let data = value(for: attribute, session: session) else { return .failure(CBATTError(.readNotPermitted)) }
        guard offset >= 0, offset <= data.count else { return .failure(CBATTError(.invalidOffset)) }
        return .success(Data(data.dropFirst(offset)))
    }

    static func write(_ attribute: Attribute, value: Data?, offset: Int, session: inout Session) -> CBATTError.Code {
        guard attribute.isWritable else { return .writeNotPermitted }
        guard offset == 0 else { return .invalidOffset }
        guard let value, value.count == 1, let byte = value.first else { return .invalidAttributeValueLength }
        switch attribute {
        case .protocolMode:
            guard byte <= 1 else { return .requestNotSupported }
            session.protocolMode = byte
        case .controlPoint:
            guard byte <= 1 else { return .requestNotSupported }
            session.suspended = byte == 0
        case .keyboardOutput, .bootKeyboardOutput: session.keyboardLEDs = byte
        default: return .writeNotPermitted
        }
        return .success
    }

    // Report 1: standard six-key keyboard (8 bytes) and LED output (1 byte).
    // Report 2: three-button relative mouse, X/Y/wheel (4 bytes).
    // GATT Report values exclude the report ID; descriptor 0x2908 supplies it.
    static let reportMap = Data([
        0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
        0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01,
        0x75,0x01, 0x95,0x08, 0x81,0x02,
        0x75,0x08, 0x95,0x01, 0x81,0x01,
        0x05,0x08, 0x19,0x01, 0x29,0x05, 0x75,0x01, 0x95,0x05, 0x91,0x02,
        0x75,0x03, 0x95,0x01, 0x91,0x01,
        0x05,0x07, 0x19,0x00, 0x29,0x65, 0x15,0x00, 0x25,0x65,
        0x75,0x08, 0x95,0x06, 0x81,0x00, 0xC0,
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
        0x09,0x01, 0xA1,0x00, 0x05,0x09, 0x19,0x01, 0x29,0x03,
        0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x03, 0x81,0x02,
        0x75,0x05, 0x95,0x01, 0x81,0x01,
        0x05,0x01, 0x09,0x30, 0x09,0x31, 0x09,0x38,
        0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x03, 0x81,0x06, 0xC0,0xC0
    ])
}
