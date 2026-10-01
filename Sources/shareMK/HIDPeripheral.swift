import CoreBluetooth
import Foundation

@MainActor
final class HIDPeripheral: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    typealias Attribute = HIDProfile.Attribute
    private let log: RuntimeLog
    private let onChange: ([UUID], String) -> Void
    private var manager: CBPeripheralManager?
    private var services: [CBMutableService] = []
    private var attributes: [ObjectIdentifier: Attribute] = [:]
    private var characteristics: [Attribute: CBMutableCharacteristic] = [:]
    private var sessions: [UUID: HIDProfile.Session] = [:]
    private var centrals: [UUID: CBCentral] = [:]
    private var subscriptions: [UUID: Set<Attribute>] = [:]
    private var pendingNeutralReports: [(CBCentral, Attribute)] = []
    private var serviceIndex = 0
    private var running = false
    private var status = "Bluetooth初期化中"

    init(log: RuntimeLog, onChange: @escaping ([UUID], String) -> Void) {
        self.log = log
        self.onChange = onChange
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        log.record("START version=0.2.0 authorization=\(CBPeripheralManager.authorization.rawValue)")
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        running = false
        if manager?.state == .poweredOn {
            manager?.stopAdvertising()
            manager?.removeAllServices()
        }
        manager?.delegate = nil
        manager = nil
        clearConnections()
        log.record("STOP")
    }

    private func publishStatus(_ value: String) {
        status = value
        let peers = connectedPeers
        onChange(peers, status)
    }

    var connectedPeers: [UUID] {
        subscriptions.filter { $0.value.contains(where: \.isInput) }.map(\.key)
    }

    private func clearConnections() {
        sessions.removeAll()
        centrals.removeAll()
        subscriptions.removeAll()
        pendingNeutralReports.removeAll()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard running else { return }
        log.record("STATE value=\(peripheral.state.rawValue) authorization=\(CBPeripheralManager.authorization.rawValue)")
        clearConnections()
        switch peripheral.state {
        case .poweredOn: registerProfile(peripheral)
        case .poweredOff: publishStatus("Bluetoothがオフです")
        case .unauthorized: publishStatus("Bluetoothの使用許可が必要です")
        case .unsupported: publishStatus("Bluetooth LE Peripheralに対応していません")
        case .resetting: publishStatus("Bluetooth再接続待ち")
        case .unknown: publishStatus("Bluetooth初期化中")
        @unknown default: publishStatus("Bluetoothの状態を確認できません")
        }
    }

    private func registerProfile(_ peripheral: CBPeripheralManager) {
        peripheral.stopAdvertising()
        peripheral.removeAllServices()
        attributes.removeAll()
        characteristics.removeAll()
        func service(_ uuid: String, _ keys: [Attribute]) -> CBMutableService {
            let result = CBMutableService(type: HIDProfile.serviceUUID(uuid), primary: true)
            result.characteristics = keys.map { key in
                let characteristic = key.makeCharacteristic()
                attributes[ObjectIdentifier(characteristic)] = key
                characteristics[key] = characteristic
                return characteristic
            }
            return result
        }
        services = [
            service("180A", [.manufacturer, .pnpID]),
            service("180F", [.battery]),
            service("1812", [.information, .reportMap, .protocolMode, .controlPoint,
                             .keyboardInput, .keyboardOutput, .mouseInput,
                             .bootKeyboardInput, .bootKeyboardOutput, .bootMouseInput])
        ]
        serviceIndex = 0
        publishStatus("HIDサービス登録中")
        peripheral.add(services[serviceIndex])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard running, serviceIndex < services.count, service === services[serviceIndex] else { return }
        if let error {
            log.record("SERVICE_FAILED uuid=\(service.uuid) error=\(error)")
            peripheral.removeAllServices()
            publishStatus("HIDサービス登録失敗（ログを確認）")
            return
        }
        log.record("SERVICE_READY uuid=\(service.uuid) characteristics=\(service.characteristics?.count ?? 0)")
        serviceIndex += 1
        if serviceIndex < services.count { peripheral.add(services[serviceIndex]); return }
        log.record("ADVERTISE_REQUEST service=1812 uuidBytes=\(HIDProfile.advertisedUUID.data.count) name=\(HIDProfile.advertisedName)")
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [HIDProfile.advertisedUUID],
            CBAdvertisementDataLocalNameKey: HIDProfile.advertisedName
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard running else { return }
        if let error {
            log.record("ADVERTISE_FAILED error=\(error)")
            publishStatus("HID広告開始失敗（ログを確認）")
        } else {
            log.record("ADVERTISE_READY active=\(peripheral.isAdvertising)")
            publishStatus("HIDペアリング待機中")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let attribute = attributes[ObjectIdentifier(request.characteristic)] else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let session = sessions[request.central.identifier, default: HIDProfile.Session()]
        let result = HIDProfile.read(attribute, session: session, offset: request.offset)
        switch result {
        case .success(let data):
            request.value = data
            peripheral.respond(to: request, withResult: .success)
            log.record("READ peer=\(request.central.identifier) attribute=\(attribute) offset=\(request.offset) bytes=\(data.count) result=success")
        case .failure(let error):
            peripheral.respond(to: request, withResult: error.code)
            log.record("READ_FAILED peer=\(request.central.identifier) attribute=\(attribute) offset=\(request.offset) error=\(error.code.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // CoreBluetooth delivers a transaction: validate everything before committing,
        // then respond exactly once using the first request.
        var nextSessions = sessions
        for request in requests {
            guard let attribute = attributes[ObjectIdentifier(request.characteristic)] else {
                peripheral.respond(to: first, withResult: .attributeNotFound)
                return
            }
            var session = nextSessions[request.central.identifier, default: HIDProfile.Session()]
            let result = HIDProfile.write(attribute, value: request.value, offset: request.offset, session: &session)
            guard result == .success else {
                log.record("WRITE_FAILED peer=\(request.central.identifier) attribute=\(attribute) error=\(result.rawValue)")
                peripheral.respond(to: first, withResult: result)
                return
            }
            nextSessions[request.central.identifier] = session
        }
        sessions = nextSessions
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            if let attribute = attributes[ObjectIdentifier(request.characteristic)] {
                log.record("WRITE peer=\(request.central.identifier) attribute=\(attribute) bytes=\(request.value?.count ?? 0) result=success")
            }
        }
        flushNeutralReports(peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard let attribute = attributes[ObjectIdentifier(characteristic)] else { return }
        centrals[central.identifier] = central
        subscriptions[central.identifier, default: []].insert(attribute)
        log.record("HID_SUBSCRIBED peer=\(central.identifier) attribute=\(attribute) mtu=\(central.maximumUpdateValueLength)")
        publishStatus("HID接続中")
        if attribute.isInput {
            pendingNeutralReports.append((central, attribute))
            flushNeutralReports(peripheral)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let attribute = attributes[ObjectIdentifier(characteristic)] else { return }
        subscriptions[central.identifier]?.remove(attribute)
        pendingNeutralReports.removeAll { $0.0.identifier == central.identifier && $0.1 == attribute }
        if subscriptions[central.identifier]?.isEmpty == true {
            subscriptions.removeValue(forKey: central.identifier)
            sessions.removeValue(forKey: central.identifier)
            centrals.removeValue(forKey: central.identifier)
        }
        log.record("HID_UNSUBSCRIBED peer=\(central.identifier) attribute=\(attribute)")
        publishStatus(subscriptions.isEmpty ? "HIDペアリング待機中" : "HID接続中")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushNeutralReports(peripheral)
    }

    private func flushNeutralReports(_ peripheral: CBPeripheralManager) {
        while let (central, attribute) = pendingNeutralReports.first {
            let session = sessions[central.identifier, default: HIDProfile.Session()]
            let boot = attribute == .bootKeyboardInput || attribute == .bootMouseInput
            guard !session.suspended, boot == (session.protocolMode == 0),
                  subscriptions[central.identifier]?.contains(attribute) == true,
                  let characteristic = characteristics[attribute],
                  let data = HIDProfile.value(for: attribute, session: session) else {
                pendingNeutralReports.removeFirst()
                continue
            }
            // Only neutral reports: this milestone does not capture or send user input.
            guard peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) else { return }
            pendingNeutralReports.removeFirst()
            log.record("HID_NEUTRAL_SENT peer=\(central.identifier) attribute=\(attribute) bytes=\(data.count)")
        }
    }

    @discardableResult
    func sendKeyboard(_ report: HIDKeyboardReport, to peer: UUID?) -> Bool {
        sendInput(report.data, bootData: report.data, reportAttribute: .keyboardInput,
                  bootAttribute: .bootKeyboardInput, to: peer)
    }

    @discardableResult
    func sendMouse(_ report: HIDMouseReport, to peer: UUID?) -> Bool {
        sendInput(report.data, bootData: report.bootData, reportAttribute: .mouseInput,
                  bootAttribute: .bootMouseInput, to: peer)
    }

    @discardableResult
    private func sendInput(_ reportData: Data, bootData: Data,
                           reportAttribute: Attribute, bootAttribute: Attribute,
                           to peer: UUID?) -> Bool {
        guard let peripheral = manager else { return false }
        let peerIDs = peer.map { [$0] } ?? connectedPeers
        var sent = false
        for id in peerIDs {
            guard let central = centrals[id],
                  let subscribed = subscriptions[id] else { continue }
            let session = sessions[id, default: HIDProfile.Session()]
            let attribute = session.protocolMode == 0 ? bootAttribute : reportAttribute
            let data = session.protocolMode == 0 ? bootData : reportData
            guard !session.suspended,
                  subscribed.contains(attribute),
                  let characteristic = characteristics[attribute] else { continue }
            if peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) {
                sent = true
                log.record("HID_INPUT_SENT peer=\(id) attribute=\(attribute) bytes=\(data.count)")
            }
        }
        return sent
    }
}
