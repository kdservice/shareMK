import AppKit
import Foundation

final class NativeUB500Controller: @unchecked Sendable {
    private let log: RuntimeLog
    private let onChange: @MainActor ([String], String) -> Void
    private let setupQueue = DispatchQueue(label: "shareMK.ub500.native.setup")
    private let eventQueue = DispatchQueue(label: "shareMK.ub500.native.event")
    private let aclQueue = DispatchQueue(label: "shareMK.ub500.native.acl")
    private let txQueue = DispatchQueue(label: "shareMK.ub500.native.tx")
    private var context: libusb_context?
    private var handle: libusb_device_handle?
    private var running = false
    private var bdAddress = ""
    private var peerAddress: String?
    private var connectionHandle: UInt16?
    private var nextLocalCID: UInt16 = 0x0040
    private var channelsByLocalCID: [UInt16: L2CAPChannel] = [:]
    private var hidInterruptLocalCID: UInt16?
    private var aclConnectedPeers: Set<String> = []
    private var hidReadyPeers: Set<String> = []
    private var pendingMouseReport: HIDMouseReport?
    private var mouseFlushScheduled = false
    private var hidDropLogCount = 0
    private var pairingMode = false
    private var reconnectTarget: String?
    private var reconnectAttempt = 0
    private var reconnectGeneration = 0
    private var outgoingConnectAddress: String?
    private var outgoingRemoteFeaturesAddress: String?
    private var outgoingAuthenticationAddress: String?
    private var outgoingL2CAPAfterEncryptionAddress: String?
    private var hidInterruptOpenRetryCount = 0
    private lazy var linkKeyStore = LinkKeyStore(log: log)

    init(log: RuntimeLog, onChange: @escaping @MainActor ([String], String) -> Void) {
        self.log = log
        self.onChange = onChange
    }

    @MainActor
    func start() {
        guard !running else { return }
        running = true
        setupQueue.async { [weak self] in
            self?.publishPeers(status: "UB500初期化中")
        }
        setupQueue.async { [weak self] in
            self?.openAndInitialize()
        }
    }

    @MainActor
    func stop() {
        running = false
        setupQueue.async { [weak self] in
            self?.close()
        }
    }

    func releaseInput() {
        sendKeyboard(HIDKeyboardReport())
        sendMouse(HIDMouseReport())
    }

    func activeHIDAddress() -> String? {
        guard let peerAddress, hidReadyPeers.contains(peerAddress) else { return nil }
        return peerAddress
    }

    func sendKeyboard(_ report: HIDKeyboardReport, to address: String) {
        let payload = [0xA1, 0x01] + Array(report.data)
        txQueue.async { [weak self] in
            guard let self, self.peerAddress == address, self.hidReadyPeers.contains(address) else { return }
            _ = self.sendHIDInterrupt(payload)
        }
    }

    func sendMouse(_ report: HIDMouseReport, to address: String, settings: MouseSettings) {
        txQueue.async { [weak self] in
            guard let self, self.peerAddress == address, self.hidReadyPeers.contains(address) else { return }
            if report.x != 0 || report.y != 0 {
                self.enqueueMouse(report, settings: settings)
                return
            }
            _ = self.sendHIDInterrupt([0xA1, 0x02] + Array(report.data))
        }
    }

    func sendMouse(_ report: HIDMouseReport, to address: String) {
        sendMouse(report, to: address, settings: MouseSettings())
    }

    func sendKeyboard(_ report: HIDKeyboardReport) {
        guard let peerAddress else { return }
        sendKeyboard(report, to: peerAddress)
    }

    func sendMouse(_ report: HIDMouseReport) {
        guard let peerAddress else { return }
        sendMouse(report, to: peerAddress)
    }

    func pairedAddresses() -> [String] {
        linkKeyStore.addresses()
    }

    func connectedAddresses() -> [String] {
        Array(hidReadyPeers).sorted()
    }

    func hidReadyAddresses() -> [String] {
        Array(hidReadyPeers).sorted()
    }

    func deletePairing(address: String) {
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.linkKeyStore.remove(address: address)
            if self.peerAddress == address {
                self.connectionHandle = nil
                self.peerAddress = nil
                self.hidInterruptLocalCID = nil
                self.aclConnectedPeers.remove(address)
                self.hidReadyPeers.remove(address)
            }
            self.publishPeers(status: "ペアリング削除")
            self.record("PAIRING_DELETE address=\(address)")
        }
    }

    func startPairingMode() {
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.pairingMode = true
            self.reconnectTarget = nil
            self.outgoingConnectAddress = nil
            self.outgoingRemoteFeaturesAddress = nil
            self.outgoingAuthenticationAddress = nil
            self.outgoingL2CAPAfterEncryptionAddress = nil
            self.reconnectGeneration &+= 1
            if let active = self.peerAddress {
                self.record("UB500_PAIRING_MODE_DROP_ACTIVE peer=\(active)")
                self.disconnectCurrentACL(reason: 0x13)
                self.dropCurrentConnectionState(address: active)
            }
            self.record("UB500_PAIRING_MODE_START")
            self.enableHIDConnectableMode(scanEnable: 0x03, status: "ペアリングモード")
        }
    }

    func stopPairingMode() {
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.pairingMode = false
            self.record("UB500_PAIRING_MODE_STOP")
            self.enableHIDConnectableMode(scanEnable: 0x02, status: "HID再接続待受")
        }
    }

    @MainActor
    func isPairingModeEnabled() -> Bool { pairingMode }

    func reconnect(address: String) {
        prepareSwitch(to: address)
    }

    func cancelReconnect() {
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.reconnectTarget = nil
            self.outgoingConnectAddress = nil
            self.outgoingRemoteFeaturesAddress = nil
            self.outgoingAuthenticationAddress = nil
            self.outgoingL2CAPAfterEncryptionAddress = nil
            self.reconnectGeneration &+= 1
            self.reconnectAttempt = 0
            if let peerAddress = self.peerAddress, self.hidInterruptLocalCID == nil {
                self.record("UB500_RECONNECT_CANCEL_DROP_INCOMPLETE peer=\(peerAddress)")
                self.disconnectCurrentACL(reason: 0x13)
                self.dropCurrentConnectionState(address: peerAddress)
            }
            self.record("UB500_RECONNECT_CANCEL")
        }
    }

    func prepareSwitch(to address: String) {
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.reconnectTarget = address
            self.reconnectAttempt = 0
            self.reconnectGeneration &+= 1
            self.outgoingConnectAddress = nil
            self.outgoingRemoteFeaturesAddress = nil
            self.outgoingAuthenticationAddress = nil
            self.outgoingL2CAPAfterEncryptionAddress = nil
            self.record("UB500_PREPARE_SWITCH target=\(address) active=\(self.peerAddress ?? "none")")
            if let active = self.peerAddress, active != address {
                self.record("UB500_SWITCH_DISCONNECT active=\(active) target=\(address)")
                self.disconnectCurrentACL(reason: 0x13)
                self.dropCurrentConnectionState(address: active)
                self.publishPeers(status: "HID切替待受")
                return
            }
            if self.peerAddress == address, self.hidInterruptLocalCID != nil {
                self.record("UB500_RECONNECT_ALREADY_READY address=\(address)")
                self.publishPeers(status: "UB500 HID送信可能")
                return
            }
            if self.peerAddress == address, self.connectionHandle != nil, self.hidInterruptLocalCID == nil {
                self.record("UB500_RECONNECT_DROP_STALE_ACL address=\(address)")
                self.disconnectCurrentACL(reason: 0x13)
                self.dropCurrentConnectionState(address: address)
                return
            }
            self.startOutgoingReconnect(address: address, generation: self.reconnectGeneration)
        }
    }

    private func dropCurrentConnectionState(address: String?) {
        if let address {
            aclConnectedPeers.remove(address)
            hidReadyPeers.remove(address)
        }
        connectionHandle = nil
        peerAddress = nil
        channelsByLocalCID.removeAll()
        hidInterruptLocalCID = nil
        pendingMouseReport = nil
        mouseFlushScheduled = false
        hidInterruptOpenRetryCount = 0
        outgoingRemoteFeaturesAddress = nil
        outgoingAuthenticationAddress = nil
        outgoingL2CAPAfterEncryptionAddress = nil
    }

    private func startOutgoingReconnect(address: String, generation: Int) {
        guard reconnectTarget == address, reconnectGeneration == generation else { return }
        if peerAddress == address, hidInterruptLocalCID != nil {
            publishPeers(status: "UB500 HID送信可能")
            return
        }
        if outgoingConnectAddress == address {
            record("UB500_RECONNECT_SKIP_IN_FLIGHT address=\(address)")
            return
        }
        guard reconnectAttempt < 5 else {
            record("UB500_RECONNECT_GIVE_UP address=\(address)")
            reconnectTarget = nil
            outgoingConnectAddress = nil
            enableHIDConnectableMode(scanEnable: pairingMode ? 0x03 : 0x02, status: "HID再接続失敗")
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        outgoingConnectAddress = address
        record("UB500_RECONNECT_ATTEMPT address=\(address) attempt=\(attempt)")
        publishPeers(status: "HID再接続試行 \(attempt)")
        createACLConnection(to: address)
        scheduleReconnectRetry(address: address, generation: generation, delayMilliseconds: 18000, attempt: attempt)
    }

    private func scheduleReconnectRetry(address: String, generation: Int, delayMilliseconds: Int, attempt: Int? = nil) {
        setupQueue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard self.reconnectTarget == address, self.reconnectGeneration == generation else { return }
            if let attempt, self.reconnectAttempt != attempt { return }
            if self.peerAddress == address, self.hidInterruptLocalCID != nil { return }
            if let active = self.peerAddress {
                if attempt == nil {
                    self.record("UB500_RECONNECT_RETRY_SKIP_ACTIVE active=\(active) target=\(address)")
                    return
                }
                self.record("UB500_RECONNECT_TIMEOUT_DROP active=\(active) target=\(address)")
                self.disconnectCurrentACL(reason: 0x13)
                self.dropCurrentConnectionState(address: active)
            }
            self.outgoingConnectAddress = nil
            self.startOutgoingReconnect(address: address, generation: generation)
        }
    }


    private func scheduleHIDOpenTimeout(address: String, handle: UInt16, generation: Int, delayMilliseconds: Int) {
        setupQueue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard self.reconnectTarget == address, self.reconnectGeneration == generation else { return }
            guard self.peerAddress == address, self.connectionHandle == handle else { return }
            guard self.hidInterruptLocalCID == nil else { return }
            self.record("UB500_HID_OPEN_TIMEOUT_DROP peer=\(address) handle=0x\(String(format: "%04X", handle))")
            self.disconnectCurrentACL(reason: 0x13)
        }
    }

    private func createACLConnection(to address: String) {
        guard let addressBytes = bluetoothAddressLittleEndian(from: address) else {
            record("UB500_CREATE_CONNECTION_BAD_ADDRESS address=\(address)")
            return
        }
        var params = addressBytes
        params.append(contentsOf: [0x18, 0xCC])
        params.append(0x02)
        params.append(0x00)
        params.append(contentsOf: [0x00, 0x00])
        params.append(0x01)
        record("UB500_CREATE_CONNECTION address=\(address)")
        sendHCICommandNoWait(opcode: 0x0405, parameters: params)
    }


    private func enableHIDConnectableMode(scanEnable: UInt8, status: String) {
        sendHCICommandNoWait(opcode: 0x0C13, parameters: paddedName("shareMK USB HID"))
        sendHCICommandNoWait(opcode: 0x0C24, parameters: [0xC0,0x25,0x00])
        sendHCICommandNoWait(opcode: 0x0C52, parameters: eirData(name: "shareMK USB HID"))
        sendHCICommandNoWait(opcode: 0x0C56, parameters: [0x01])
        sendHCICommandNoWait(opcode: 0x0C47, parameters: [0x01])
        sendHCICommandNoWait(opcode: 0x0C43, parameters: [0x01])
        sendHCICommandNoWait(opcode: 0x0C1A, parameters: [scanEnable])
        record("UB500_SCAN_ENABLE value=0x\(String(format: "%02X", scanEnable)) status=\(status)")
        publishPeers(status: status)
    }

    private func disconnectCurrentACL(reason: UInt8) {
        guard let connectionHandle else { return }
        disconnectACL(handle: connectionHandle, reason: reason)
    }

    private func disconnectACL(handle: UInt16, reason: UInt8) {
        sendHCICommandNoWait(opcode: 0x0406, parameters: [UInt8(handle & 0xFF), UInt8((handle >> 8) & 0xFF), reason])
    }

    private func requestEncryption(handle: UInt16) {
        sendHCICommandNoWait(opcode: 0x0413, parameters: [UInt8(handle & 0xFF), UInt8((handle >> 8) & 0xFF), 0x01])
    }

    private func readRemoteSupportedFeatures(handle: UInt16) {
        sendHCICommandNoWait(opcode: 0x041B, parameters: [UInt8(handle & 0xFF), UInt8((handle >> 8) & 0xFF)])
    }

    private func requestAuthentication(handle: UInt16) {
        sendHCICommandNoWait(opcode: 0x0411, parameters: [UInt8(handle & 0xFF), UInt8((handle >> 8) & 0xFF)])
    }

    private func replyUserPasskey(addressBytes: [UInt8], passkey: UInt32) {
        sendHCICommandNoWait(opcode: 0x042E, parameters: addressBytes + [
            UInt8(passkey & 0xFF),
            UInt8((passkey >> 8) & 0xFF),
            UInt8((passkey >> 16) & 0xFF),
            UInt8((passkey >> 24) & 0xFF)
        ])
    }

    private func rejectUserPasskey(addressBytes: [UInt8]) {
        sendHCICommandNoWait(opcode: 0x042F, parameters: addressBytes)
    }

    private func replyPinCode(addressBytes: [UInt8], pin: String) {
        let bytes = Array(pin.utf8.prefix(16))
        var padded = bytes
        while padded.count < 16 { padded.append(0) }
        sendHCICommandNoWait(opcode: 0x040D, parameters: addressBytes + [UInt8(bytes.count)] + padded)
    }

    private func requestPairingCodeFromUser(address: String, title: String) -> String? {
        if Thread.isMainThread {
            return showPairingCodePrompt(address: address, title: title)
        }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        DispatchQueue.main.async {
            box.value = self.showPairingCodePrompt(address: address, title: title)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return box.value
    }

    private func showPairingCodePrompt(address: String, title: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Windowsに表示されたPINを入力してください。\n接続先: \(address)"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "PIN"
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func rejectConnectionRequest(addressBytes: [UInt8], reason: UInt8 = 0x0D) {
        sendHCICommandNoWait(opcode: 0x040A, parameters: addressBytes + [reason])
    }

    private func openAndInitialize() {
        var ctx: libusb_context?
        var result = libusb_init(&ctx)
        guard result == 0 else {
            publishPeers(status: "libusb初期化失敗")
            record("UB500_LIBUSB_INIT_FAILED error=\(libusbError(result))")
            return
        }
        context = ctx

        guard let initial = waitForUB500Device(context: ctx, timeoutSeconds: 6.0) else {
            publishPeers(status: "UB500が見つかりません")
            record("UB500_OPEN_FAILED vid=2357 pid=0604")
            close()
            return
        }

        let resetResult = libusb_reset_device(initial)
        record("UB500_USB_RESET result=\(resetResult == 0 ? "ok" : libusbError(resetResult))")
        libusb_close(initial)
        Thread.sleep(forTimeInterval: 0.8)
        guard let opened = waitForUB500Device(context: ctx, timeoutSeconds: 8.0) else {
            publishPeers(status: "UB500 reset後の再オープン失敗")
            record("UB500_REOPEN_AFTER_RESET_FAILED vid=2357 pid=0604")
            close()
            return
        }
        handle = opened

        _ = libusb_set_auto_detach_kernel_driver(opened, 1)
        var configuration: Int32 = 0
        result = libusb_get_configuration(opened, &configuration)
        if result == 0, configuration != 1 {
            let setConfig = libusb_set_configuration(opened, 1)
            if setConfig != 0 {
                record("UB500_SET_CONFIGURATION_FAILED error=\(libusbError(setConfig))")
            }
        }
        let active = libusb_kernel_driver_active(opened, 0)
        if active == 1 {
            let detached = libusb_detach_kernel_driver(opened, 0)
            if detached != 0 {
                record("UB500_DETACH_FAILED error=\(libusbError(detached))")
            }
        }
        result = libusb_claim_interface(opened, 0)
        guard result == 0 else {
            publishPeers(status: "UB500 interface取得失敗")
            record("UB500_CLAIM_FAILED error=\(libusbError(result))")
            close()
            return
        }

        do {
            _ = try hciCommand(opcode: 0x0C03, parameters: [])
            try loadRealtekFirmwareIfNeeded()
            _ = try hciCommand(opcode: 0x0C03, parameters: [])
            _ = try hciCommand(opcode: 0x0C01, parameters: [0xFF,0x9F,0xFF,0xBF,0x07,0xF8,0xBF,0x3D])
            _ = try hciCommand(opcode: 0x2001, parameters: [0xFF,0xFF,0xF7,0xFF,0x0F,0xED,0x7B,0x00])
            _ = try hciCommand(opcode: 0x1005, parameters: [])
            _ = try hciCommand(opcode: 0x2002, parameters: [])
            _ = try hciCommand(opcode: 0x2023, parameters: [])
            _ = try hciCommand(opcode: 0x2024, parameters: [0xFB,0x00,0x48,0x08])
            record("UB500_BUMBLE_HOST_INIT event_mask=ff9fffbf07f8bf3d le_event_mask=fffff7ff0fed7b00")
            _ = try hciCommand(opcode: 0x0C13, parameters: paddedName("shareMK USB HID"))
            _ = try hciCommand(opcode: 0x0C24, parameters: [0xC0,0x25,0x00])
            _ = try hciCommand(opcode: 0x0C6D, parameters: [0x00, 0x00])
            _ = try hciCommand(opcode: 0x0C56, parameters: [0x01])
            _ = try hciCommand(opcode: 0x0C7A, parameters: [0x01])
            record("UB500_DEFAULT_LINK_POLICY_SKIPPED match=bumble")
            _ = try hciCommand(opcode: 0x0C47, parameters: [0x01])
            _ = try hciCommand(opcode: 0x0C1A, parameters: [0x03])
            _ = try hciCommand(opcode: 0x0C52, parameters: eirData(name: "shareMK USB HID"))
            _ = try hciCommand(opcode: 0x0C1A, parameters: [0x03])
            _ = try hciCommand(opcode: 0x0C43, parameters: [0x01])
            _ = try hciCommand(opcode: 0x0C52, parameters: eirData(name: "shareMK USB HID"))
            _ = try hciCommand(opcode: 0x0C1A, parameters: [0x03])
            record("UB500_BUMBLE_INIT_COMPAT le_host=0 page_scan=interlaced inquiry_scan=interlaced")
            record("UB500_AUTH_ENABLE_SKIPPED match=bumble")
            record("UB500_LINK_KEYS_APP_STORE count=\(linkKeyStore.addresses().count)")
            _ = try hciCommand(opcode: 0x0C1A, parameters: [0x03])
            let addressReturn = try hciCommand(opcode: 0x1009, parameters: [])
            if addressReturn.count >= 7 {
                bdAddress = addressReturn.dropFirst().prefix(6).reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            startReceiveLoops()
            publishPeers(status: "UB500 HID再接続待受 \(bdAddress)")
            record("UB500_HCI_READY address=\(bdAddress)")
        } catch {
            publishPeers(status: "UB500 HCI初期化失敗")
            record("UB500_HCI_FAILED error=\(error)")
        }
    }

    private func waitForUB500Device(context: OpaquePointer?, timeoutSeconds: TimeInterval) -> libusb_device_handle? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            if let opened = libusb_open_device_with_vid_pid(context, 0x2357, 0x0604) {
                if attempt > 1 {
                    record("UB500_OPEN_RETRY_SUCCESS attempt=\(attempt)")
                }
                return opened
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private func loadRealtekFirmwareIfNeeded() throws {
        let rom = try hciCommand(opcode: 0xFC6D, parameters: [])
        guard rom.count >= 2 else { throw NativeUB500Error.shortEvent }
        let romVersion = UInt16(rom[1])
        let urls = firmwareURLs()
        let fwURL = urls.firmware
        let configURL = urls.config
        let firmware = try RealtekFirmware(data: Data(contentsOf: fwURL))
        let config = (try? Data(contentsOf: configURL)) ?? Data()
        var payload = try firmware.patchPayload(forChipID: romVersion + 1)
        payload.append(config)
        let fragmentLength = 252
        let fragmentCount = Int(ceil(Double(payload.count) / Double(fragmentLength)))
        for index in 0..<fragmentCount {
            var downloadIndex = UInt8(index & 0x7F)
            if index == fragmentCount - 1 { downloadIndex |= 0x80 }
            let start = index * fragmentLength
            let end = min(payload.count, start + fragmentLength)
            var parameters = [downloadIndex]
            parameters.append(contentsOf: payload[start..<end])
            _ = try hciCommand(opcode: 0xFC20, parameters: parameters)
        }
        record("UB500_RTK_FIRMWARE_LOADED version=0x\(String(format: "%08X", firmware.version)) fragments=\(fragmentCount)")
    }

    private func hciCommand(opcode: UInt16, parameters: [UInt8]) throws -> [UInt8] {
        guard let handle else { throw NativeUB500Error.notOpen }
        var payload = [UInt8(opcode & 0xFF), UInt8(opcode >> 8), UInt8(parameters.count)] + parameters
        let payloadLength = payload.count
        let sent = payload.withUnsafeMutableBufferPointer { buffer in
            libusb_control_transfer(handle, 0x20, 0, 0, 0, buffer.baseAddress, UInt16(payloadLength), 3000)
        }
        guard sent == payloadLength else {
            throw NativeUB500Error.usb("control opcode=0x\(String(format: "%04X", opcode)) result=\(libusbError(sent))")
        }
        let event = try waitCommandComplete(opcode: opcode)
        guard event.count >= 6 else { throw NativeUB500Error.shortEvent }
        let status = event[5]
        guard status == 0 else {
            throw NativeUB500Error.hciStatus(opcode: opcode, status: status)
        }
        return Array(event.dropFirst(5))
    }

    private func sendHCICommandNoWait(opcode: UInt16, parameters: [UInt8]) {
        guard let handle else { return }
        var payload = [UInt8(opcode & 0xFF), UInt8(opcode >> 8), UInt8(parameters.count)] + parameters
        let payloadLength = payload.count
        let sent = payload.withUnsafeMutableBufferPointer { buffer in
            libusb_control_transfer(handle, 0x20, 0, 0, 0, buffer.baseAddress, UInt16(payloadLength), 3000)
        }
        if sent != payloadLength {
            record("UB500_HCI_SEND_FAILED opcode=0x\(String(format: "%04X", opcode)) error=\(libusbError(sent))")
        }
    }

    private func startReceiveLoops() {
        eventQueue.async { [weak self] in self?.eventLoop() }
        aclQueue.async { [weak self] in self?.aclLoop() }
    }

    private func eventLoop() {
        while running, handle != nil {
            var buffer = [UInt8](repeating: 0, count: 260)
            let length = buffer.count
            var actual: Int32 = 0
            let result = buffer.withUnsafeMutableBufferPointer { ptr in
                libusb_interrupt_transfer(handle, 0x81, ptr.baseAddress, Int32(length), &actual, 500)
            }
            if result == -7 { continue }
            guard result == 0, actual > 0 else { continue }
            handleHCIEvent(Array(buffer.prefix(Int(actual))))
        }
    }

    private func aclLoop() {
        while running, handle != nil {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let length = buffer.count
            var actual: Int32 = 0
            let result = buffer.withUnsafeMutableBufferPointer { ptr in
                libusb_bulk_transfer(handle, 0x82, ptr.baseAddress, Int32(length), &actual, 500)
            }
            if result == -7 { continue }
            guard result == 0, actual > 0 else { continue }
            handleACLData(Array(buffer.prefix(Int(actual))))
        }
    }

    private func shouldAcceptConnectionRequest(from address: String) -> Bool {
        if pairingMode { return true }
        if let target = reconnectTarget { return target == address }
        if let active = peerAddress { return active == address }
        if outgoingConnectAddress != nil { return false }
        return linkKeyStore.key(for: address) != nil
    }

    private func handleHCIEvent(_ event: [UInt8]) {
        guard event.count >= 2 else { return }
        let code = event[0]
        switch code {
        case 0x03:
            guard event.count >= 13 else { return }
            let status = event[2]
            let handle = UInt16(event[3]) | (UInt16(event[4]) << 8)
            let addressBytes = Array(event[5..<11])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            record("UB500_CONNECTION_COMPLETE status=0x\(String(format: "%02X", status)) handle=0x\(String(format: "%04X", handle)) peer=\(address)")
            if status == 0 {
                let normalizedHandle = handle & 0x0FFF
                if let current = peerAddress, current != address {
                    if pairingMode {
                        record("UB500_CONNECTION_COMPLETE_PAIRING_REPLACE_ACTIVE active=\(current) peer=\(address) handle=0x\(String(format: "%04X", normalizedHandle))")
                        disconnectCurrentACL(reason: 0x13)
                        dropCurrentConnectionState(address: current)
                    } else {
                        record("UB500_CONNECTION_COMPLETE_REJECT_EXTRA active=\(current) peer=\(address) handle=0x\(String(format: "%04X", normalizedHandle))")
                        disconnectACL(handle: normalizedHandle, reason: 0x13)
                        return
                    }
                }
                if let target = reconnectTarget, target != address, outgoingConnectAddress != address {
                    record("UB500_CONNECTION_COMPLETE_REJECT_NOT_TARGET target=\(target) peer=\(address) handle=0x\(String(format: "%04X", normalizedHandle))")
                    disconnectACL(handle: normalizedHandle, reason: 0x13)
                    return
                }
                connectionHandle = normalizedHandle
                peerAddress = address
                aclConnectedPeers.removeAll()
                hidReadyPeers.removeAll()
                aclConnectedPeers.insert(address)
                publishPeers(status: "ACL接続")
                if outgoingConnectAddress == address || reconnectTarget == address {
                    outgoingConnectAddress = nil
                    outgoingRemoteFeaturesAddress = nil
                    outgoingAuthenticationAddress = address
                    requestAuthentication(handle: normalizedHandle)
                    record("UB500_OUTGOING_ACL_CONNECTED peer=\(address) authenticate_now=1")
                    record("UB500_OUTGOING_AUTHENTICATION_REQUEST peer=\(address)")
                } else {
                    requestAuthentication(handle: normalizedHandle)
                    record("UB500_INCOMING_AUTHENTICATION_REQUEST peer=\(address)")
                }
            } else if outgoingConnectAddress == address {
                record("UB500_OUTGOING_ACL_FAILED peer=\(address) status=0x\(String(format: "%02X", status))")
                outgoingConnectAddress = nil
                if let target = reconnectTarget, target == address {
                    scheduleReconnectRetry(address: target, generation: reconnectGeneration, delayMilliseconds: 300)
                }
            }
        case 0x04:
            guard event.count >= 12 else { return }
            let addressBytes = Array(event[2..<8])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            record("UB500_CONNECTION_REQUEST peer=\(address)")
            if shouldAcceptConnectionRequest(from: address) {
                sendHCICommandNoWait(opcode: 0x0409, parameters: addressBytes + [0x01])
            } else {
                record("UB500_CONNECTION_REQUEST_REJECT peer=\(address) active=\(peerAddress ?? "none") target=\(reconnectTarget ?? "none")")
                rejectConnectionRequest(addressBytes: addressBytes)
            }
        case 0x0E:
            if event.count >= 6 {
                let opcode = UInt16(event[3]) | (UInt16(event[4]) << 8)
                let status = event[5]
                record("UB500_COMMAND_COMPLETE opcode=0x\(String(format: "%04X", opcode)) status=0x\(String(format: "%02X", status))")
                if opcode == 0x040B, event.count >= 12 {
                    let address = bluetoothAddress(fromLittleEndian: Array(event[6..<12]))
                    record("UB500_LINK_KEY_REPLY_COMPLETE peer=\(address) status=0x\(String(format: "%02X", status))")
                    if status == 0, address == peerAddress, outgoingAuthenticationAddress == address {
                        record("UB500_OUTGOING_LINK_KEY_ACCEPTED peer=\(address) wait_authentication_complete=1")
                        let expectedHandle = connectionHandle
                        setupQueue.asyncAfter(deadline: .now() + .milliseconds(700)) { [weak self] in
                            guard let self else { return }
                            guard self.outgoingAuthenticationAddress == address,
                                  self.peerAddress == address,
                                  self.connectionHandle == expectedHandle,
                                  let handle = expectedHandle else { return }
                            self.record("UB500_AUTH_FALLBACK_ENCRYPTION_REQUEST peer=\(address)")
                            self.outgoingAuthenticationAddress = nil
                            self.outgoingL2CAPAfterEncryptionAddress = address
                            self.requestEncryption(handle: handle)
                        }
                    }
                }
            }
        case 0x0F:
            if event.count >= 6 {
                let status = event[2]
                let opcode = UInt16(event[4]) | (UInt16(event[5]) << 8)
                record("UB500_COMMAND_STATUS opcode=0x\(String(format: "%04X", opcode)) status=0x\(String(format: "%02X", status))")
                if opcode == 0x0405, status != 0, let address = outgoingConnectAddress {
                    record("UB500_CREATE_CONNECTION_REJECTED address=\(address) status=0x\(String(format: "%02X", status))")
                    outgoingConnectAddress = nil
                    if reconnectTarget == address {
                        scheduleReconnectRetry(address: address, generation: reconnectGeneration, delayMilliseconds: 1000)
                    }
                }
            }
        case 0x06:
            if event.count >= 6 {
                let status = event[2]
                let handle = (UInt16(event[3]) | (UInt16(event[4]) << 8)) & 0x0FFF
                record("UB500_AUTHENTICATION_COMPLETE status=0x\(String(format: "%02X", status)) handle=0x\(String(format: "%04X", handle))")
                if status == 0, handle == connectionHandle, let address = outgoingAuthenticationAddress, address == peerAddress {
                    outgoingAuthenticationAddress = nil
                    outgoingL2CAPAfterEncryptionAddress = address
                    requestEncryption(handle: handle)
                    record("UB500_OUTGOING_AUTHENTICATED peer=\(address)")
                    record("UB500_OUTGOING_ENCRYPTION_REQUEST peer=\(address)")
                }
            }
        case 0x0B:
            if event.count >= 13 {
                let status = event[2]
                let handle = (UInt16(event[3]) | (UInt16(event[4]) << 8)) & 0x0FFF
                let features = event[5..<13].map { String(format: "%02X", $0) }.joined()
                record("UB500_REMOTE_SUPPORTED_FEATURES status=0x\(String(format: "%02X", status)) handle=0x\(String(format: "%04X", handle)) features=\(features)")
                if status == 0, handle == connectionHandle, let address = outgoingRemoteFeaturesAddress, address == peerAddress {
                    outgoingRemoteFeaturesAddress = nil
                    outgoingAuthenticationAddress = address
                    requestAuthentication(handle: handle)
                    record("UB500_OUTGOING_AUTHENTICATION_REQUEST peer=\(address)")
                }
            }
        case 0x12:
            if event.count >= 10 {
                let status = event[2]
                let address = bluetoothAddress(fromLittleEndian: Array(event[3..<9]))
                let role = event[9]
                record("UB500_ROLE_CHANGE status=0x\(String(format: "%02X", status)) peer=\(address) role=0x\(String(format: "%02X", role))")
            }
        case 0x05:
            var disconnectedHandle: UInt16?
            if event.count >= 6 {
                let status = event[2]
                let handle = (UInt16(event[3]) | (UInt16(event[4]) << 8)) & 0x0FFF
                disconnectedHandle = handle
                let reason = event[5]
                record("UB500_DISCONNECTION_COMPLETE status=0x\(String(format: "%02X", status)) handle=0x\(String(format: "%04X", handle)) reason=0x\(String(format: "%02X", reason))")
            } else {
                record("UB500_DISCONNECTION_COMPLETE")
            }
            if let disconnectedHandle, let currentHandle = connectionHandle, disconnectedHandle != currentHandle {
                record("UB500_DISCONNECTION_IGNORE_NON_ACTIVE handle=0x\(String(format: "%04X", disconnectedHandle)) active=0x\(String(format: "%04X", currentHandle))")
                return
            }
            let disconnectedAddress = peerAddress
            if let peerAddress {
                aclConnectedPeers.remove(peerAddress)
                hidReadyPeers.remove(peerAddress)
            }
            connectionHandle = nil
            peerAddress = nil
            channelsByLocalCID.removeAll()
            hidInterruptLocalCID = nil
            outgoingRemoteFeaturesAddress = nil
            outgoingAuthenticationAddress = nil
            outgoingL2CAPAfterEncryptionAddress = nil
            if let target = reconnectTarget {
                publishPeers(status: "UB500 HID再接続待受 \(bdAddress)")
                if disconnectedAddress == nil || disconnectedAddress == target {
                    scheduleReconnectRetry(address: target, generation: reconnectGeneration, delayMilliseconds: 500)
                }
            } else {
                enableHIDConnectableMode(scanEnable: pairingMode ? 0x03 : 0x02, status: "UB500 HID再接続待受 \(bdAddress)")
            }
        case 0x08:
            guard event.count >= 6 else { return }
            let status = event[2]
            let enabled = event[5]
            record("UB500_ENCRYPTION_CHANGE status=0x\(String(format: "%02X", status)) enabled=\(enabled)")
            if status == 0, enabled != 0, let address = outgoingL2CAPAfterEncryptionAddress, address == peerAddress {
                outgoingL2CAPAfterEncryptionAddress = nil
                record("UB500_OUTGOING_ENCRYPTED peer=\(address)")
                openOutgoingL2CAP(psm: 0x0011)
                if let connectionHandle {
                    scheduleHIDOpenTimeout(address: address, handle: connectionHandle, generation: reconnectGeneration, delayMilliseconds: 15000)
                }
            }
        case 0x16:
            guard event.count >= 8 else { return }
            let addressBytes = Array(event[2..<8])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            record("UB500_PIN_CODE_REQUEST peer=\(address)")
            if let pin = requestPairingCodeFromUser(address: address, title: "Bluetooth PIN入力") {
                record("UB500_PIN_CODE_REPLY peer=\(address) pin_digits=\(pin.count)")
                replyPinCode(addressBytes: addressBytes, pin: pin)
            } else {
                record("UB500_PIN_CODE_REJECT peer=\(address)")
                sendHCICommandNoWait(opcode: 0x040E, parameters: addressBytes)
            }
        case 0x17:
            guard event.count >= 8 else { return }
            let addressBytes = Array(event[2..<8])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            if let key = linkKeyStore.key(for: address) {
                record("UB500_LINK_KEY_REQUEST peer=\(address) result=stored key_bytes=\(key.count) key_head=\(key.prefix(4).map { String(format: "%02X", $0) }.joined()) key_tail=\(key.suffix(4).map { String(format: "%02X", $0) }.joined())")
                sendHCICommandNoWait(opcode: 0x040B, parameters: addressBytes + key)
            } else {
                record("UB500_LINK_KEY_REQUEST peer=\(address) result=missing")
                sendHCICommandNoWait(opcode: 0x040C, parameters: addressBytes)
            }
        case 0x18:
            guard event.count >= 24 else { return }
            let addressBytes = Array(event[2..<8])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            let key = Array(event[8..<24])
            let keyType = event.count > 24 ? event[24] : 0xFF
            linkKeyStore.setKey(key, for: address)
            record("UB500_LINK_KEY_NOTIFICATION peer=\(address) type=0x\(String(format: "%02X", keyType)) key_bytes=\(key.count) saved=yes")
            if pairingMode {
                pairingMode = false
                enableHIDConnectableMode(scanEnable: 0x02, status: "ペアリング完了")
            }
        case 0x31:
            guard event.count >= 8 else { return }
            let addressBytes = Array(event[2..<8])
            record("UB500_IO_CAPABILITY_REQUEST peer=\(bluetoothAddress(fromLittleEndian: addressBytes)) io=keyboard_only auth=mitm_general_bonding")
            sendHCICommandNoWait(opcode: 0x042B, parameters: addressBytes + [0x02, 0x00, 0x05])
        case 0x33:
            guard event.count >= 12 else { return }
            let addressBytes = Array(event[2..<8])
            record("UB500_USER_CONFIRMATION_REQUEST peer=\(bluetoothAddress(fromLittleEndian: addressBytes))")
            sendHCICommandNoWait(opcode: 0x042C, parameters: addressBytes)
        case 0x34:
            guard event.count >= 8 else { return }
            let addressBytes = Array(event[2..<8])
            let address = bluetoothAddress(fromLittleEndian: addressBytes)
            record("UB500_USER_PASSKEY_REQUEST peer=\(address)")
            if let text = requestPairingCodeFromUser(address: address, title: "Bluetooth Passkey入力"),
               let passkey = UInt32(text), passkey <= 999_999 {
                record("UB500_USER_PASSKEY_REPLY peer=\(address) digits=\(text.count)")
                replyUserPasskey(addressBytes: addressBytes, passkey: passkey)
            } else {
                record("UB500_USER_PASSKEY_REJECT peer=\(address)")
                rejectUserPasskey(addressBytes: addressBytes)
            }
        case 0x36:
            guard event.count >= 4 else { return }
            record("UB500_SIMPLE_PAIRING_COMPLETE status=0x\(String(format: "%02X", event[2]))")
            if event[2] == 0, pairingMode {
                pairingMode = false
                enableHIDConnectableMode(scanEnable: 0x02, status: "ペアリング完了")
            }
        default:
            if peerAddress != nil || outgoingAuthenticationAddress != nil {
                let hex = event.prefix(32).map { String(format: "%02X", $0) }.joined()
                record("UB500_HCI_EVENT_UNHANDLED code=0x\(String(format: "%02X", code)) bytes=\(event.count) data=\(hex)")
            }
        }
    }

    private func handleACLData(_ data: [UInt8]) {
        guard data.count >= 8 else { return }
        let packetHandle = UInt16(data[0]) | (UInt16(data[1] & 0x0F) << 8)
        let aclLength = Int(UInt16(data[2]) | (UInt16(data[3]) << 8))
        guard data.count >= 4 + aclLength else { return }
        guard connectionHandle == packetHandle else {
            record("UB500_ACL_RX_IGNORE_NON_ACTIVE handle=0x\(String(format: "%04X", packetHandle)) active=0x\(String(format: "%04X", connectionHandle ?? 0))")
            return
        }
        let l2cap = Array(data[4..<(4 + aclLength)])
        guard l2cap.count >= 4 else { return }
        let l2capLength = Int(UInt16(l2cap[0]) | (UInt16(l2cap[1]) << 8))
        let cid = UInt16(l2cap[2]) | (UInt16(l2cap[3]) << 8)
        guard l2cap.count >= 4 + l2capLength else { return }
        let payload = Array(l2cap[4..<(4 + l2capLength)])
        record("UB500_ACL_RX handle=0x\(String(format: "%04X", packetHandle)) cid=0x\(String(format: "%04X", cid)) bytes=\(payload.count)")
        if cid == 0x0001 {
            handleL2CAPSignal(payload)
        } else if let channel = channelsByLocalCID[cid] {
            handleChannelPayload(payload, channel: channel)
        } else {
            record("UB500_L2CAP_UNKNOWN_CID cid=0x\(String(format: "%04X", cid)) bytes=\(payload.count)")
        }
    }

    private func handleL2CAPSignal(_ payload: [UInt8]) {
        var offset = 0
        while offset + 4 <= payload.count {
            let code = payload[offset]
            let identifier = payload[offset + 1]
            let length = Int(UInt16(payload[offset + 2]) | (UInt16(payload[offset + 3]) << 8))
            guard offset + 4 + length <= payload.count else { return }
            let data = Array(payload[(offset + 4)..<(offset + 4 + length)])
            switch code {
            case 0x02:
                handleL2CAPConnectionRequest(identifier: identifier, data: data)
            case 0x03:
                handleL2CAPConnectionResponse(data: data)
            case 0x04:
                handleL2CAPConfigureRequest(identifier: identifier, data: data)
            case 0x05:
                handleL2CAPConfigureResponse(data: data)
            case 0x06:
                handleL2CAPDisconnectionRequest(identifier: identifier, data: data)
            case 0x0A:
                sendL2CAPCommand(code: 0x0B, identifier: identifier, data: data)
            default:
                record("UB500_L2CAP_SIGNAL code=0x\(String(format: "%02X", code)) bytes=\(length)")
            }
            offset += 4 + length
        }
    }

    private func handleL2CAPConnectionRequest(identifier: UInt8, data: [UInt8]) {
        guard data.count >= 4 else { return }
        let psm = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let remoteCID = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let localCID = nextCID()
        var channel = L2CAPChannel(localCID: localCID, remoteCID: remoteCID, psm: psm)
        channelsByLocalCID[localCID] = channel
        var response = [UInt8]()
        response.appendUInt16LE(localCID)
        response.appendUInt16LE(remoteCID)
        response.appendUInt16LE(0x0000)
        response.appendUInt16LE(0x0000)
        sendL2CAPCommand(code: 0x03, identifier: identifier, data: response)
        var config = [UInt8]()
        config.appendUInt16LE(remoteCID)
        config.appendUInt16LE(0x0000)
        sendL2CAPCommand(code: 0x04, identifier: nextIdentifier(), data: config)
        channel.sentConfigure = true
        channelsByLocalCID[localCID] = channel
        record("UB500_L2CAP_CONNECT psm=0x\(String(format: "%04X", psm)) local=0x\(String(format: "%04X", localCID)) remote=0x\(String(format: "%04X", remoteCID))")
    }

    private func handleL2CAPConnectionResponse(data: [UInt8]) {
        guard data.count >= 8 else { return }
        let destinationCID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let sourceCID = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let result = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let status = UInt16(data[6]) | (UInt16(data[7]) << 8)
        guard var channel = channelsByLocalCID[sourceCID] else {
            record("UB500_L2CAP_CONNECT_RESPONSE_UNKNOWN source=0x\(String(format: "%04X", sourceCID)) result=0x\(String(format: "%04X", result))")
            return
        }
        record("UB500_L2CAP_CONNECT_RESPONSE psm=0x\(String(format: "%04X", channel.psm)) local=0x\(String(format: "%04X", sourceCID)) remote=0x\(String(format: "%04X", destinationCID)) result=0x\(String(format: "%04X", result)) status=0x\(String(format: "%04X", status))")
        if result == 0x0001 {
            channelsByLocalCID[sourceCID] = channel
            record("UB500_L2CAP_CONNECT_PENDING psm=0x\(String(format: "%04X", channel.psm)) local=0x\(String(format: "%04X", sourceCID))")
            return
        }
        guard result == 0 else {
            channelsByLocalCID.removeValue(forKey: sourceCID)
            if let target = reconnectTarget, peerAddress == target {
                disconnectCurrentACL(reason: 0x13)
                dropCurrentConnectionState(address: target)
                scheduleReconnectRetry(address: target, generation: reconnectGeneration, delayMilliseconds: 500)
            }
            return
        }
        channel.remoteCID = destinationCID
        channel.sentConfigure = true
        channelsByLocalCID[sourceCID] = channel
        sendL2CAPConfigureRequest(destinationCID: destinationCID)
        if channel.psm == 0x0013 {
            scheduleInterruptOpenRetry(localCID: sourceCID, handle: connectionHandle, generation: reconnectGeneration, delayMilliseconds: 2500)
        }
    }

    private func scheduleInterruptOpenRetry(localCID: UInt16, handle: UInt16?, generation: Int, delayMilliseconds: Int) {
        setupQueue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard self.reconnectGeneration == generation else { return }
            guard self.connectionHandle == handle else { return }
            guard self.hidInterruptLocalCID == nil else { return }
            guard let channel = self.channelsByLocalCID[localCID], channel.psm == 0x0013 else { return }
            guard self.hidInterruptOpenRetryCount < 2 else { return }
            self.hidInterruptOpenRetryCount += 1
            self.channelsByLocalCID.removeValue(forKey: localCID)
            self.record("UB500_HID_INTERRUPT_REOPEN local=0x\(String(format: "%04X", localCID)) retry=\(self.hidInterruptOpenRetryCount)")
            self.openOutgoingL2CAP(psm: 0x0013)
        }
    }

    private func sendL2CAPConfigureRequest(destinationCID: UInt16) {
        var config = [UInt8]()
        config.appendUInt16LE(destinationCID)
        config.appendUInt16LE(0x0000)
        config.append(contentsOf: [0x01, 0x02, 0x00, 0x08])
        sendL2CAPCommand(code: 0x04, identifier: nextIdentifier(), data: config)
    }

    private func handleL2CAPConfigureRequest(identifier: UInt8, data: [UInt8]) {
        guard data.count >= 4 else { return }
        let destinationCID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let options = Array(data.dropFirst(4))
        if var channel = channelsByLocalCID[destinationCID] {
            channel.receivedConfigure = true
            channelsByLocalCID[destinationCID] = channel
            var response = [UInt8]()
            response.appendUInt16LE(channel.remoteCID)
            response.appendUInt16LE(0x0000)
            response.appendUInt16LE(0x0000)
            response.append(contentsOf: options)
            sendL2CAPCommand(code: 0x05, identifier: identifier, data: response)
            finishChannelIfReady(channel.localCID)
        }
    }

    private func handleL2CAPConfigureResponse(data: [UInt8]) {
        guard data.count >= 6 else { return }
        let sourceCID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        if var channel = channelsByLocalCID[sourceCID] {
            channel.remoteAcceptedConfigure = true
            channelsByLocalCID[sourceCID] = channel
            finishChannelIfReady(channel.localCID)
        }
    }

    private func handleL2CAPDisconnectionRequest(identifier: UInt8, data: [UInt8]) {
        guard data.count >= 4 else { return }
        let destinationCID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let sourceCID = UInt16(data[2]) | (UInt16(data[3]) << 8)
        var response = [UInt8]()
        response.appendUInt16LE(destinationCID)
        response.appendUInt16LE(sourceCID)
        sendL2CAPCommand(code: 0x07, identifier: identifier, data: response)
        let removed = channelsByLocalCID.removeValue(forKey: destinationCID)
        if hidInterruptLocalCID == destinationCID {
            hidInterruptLocalCID = nil
            if removed?.psm == 0x0013, let address = peerAddress {
                hidReadyPeers.remove(address)
                publishPeers(status: "HID割り込み切断")
            }
        }
    }

    private func finishChannelIfReady(_ localCID: UInt16) {
        guard let channel = channelsByLocalCID[localCID], channel.receivedConfigure, channel.remoteAcceptedConfigure else { return }
        switch channel.psm {
        case 0x0001:
            record("UB500_SDP_READY")
        case 0x0011:
            record("UB500_HID_CONTROL_READY")
            if reconnectTarget == peerAddress, !channelsByLocalCID.values.contains(where: { $0.psm == 0x0013 }) {
                openOutgoingL2CAP(psm: 0x0013)
            }
        case 0x0013:
            hidInterruptOpenRetryCount = 0
            hidInterruptLocalCID = localCID
            let address = peerAddress ?? "接続先"
            aclConnectedPeers.removeAll()
            hidReadyPeers.removeAll()
            aclConnectedPeers.insert(address)
            hidReadyPeers.insert(address)
            publishPeers(status: "UB500 HID送信可能")
            record("UB500_HID_INTERRUPT_READY peer=\(address)")
        default:
            break
        }
    }

    private func handleChannelPayload(_ payload: [UInt8], channel: L2CAPChannel) {
        switch channel.psm {
        case 0x0001:
            handleSDP(payload, channel: channel)
        case 0x0011:
            handleHIDControl(payload, channel: channel)
        case 0x0013:
            record("UB500_HID_INTERRUPT_RX bytes=\(payload.count)")
        default:
            record("UB500_L2CAP_RX psm=0x\(String(format: "%04X", channel.psm)) bytes=\(payload.count)")
        }
    }

    private func handleSDP(_ payload: [UInt8], channel: L2CAPChannel) {
        guard payload.count >= 5 else { return }
        let pdu = payload[0]
        let transaction = UInt16(payload[1]) << 8 | UInt16(payload[2])
        let length = Int(UInt16(payload[3]) << 8 | UInt16(payload[4]))
        guard payload.count >= 5 + length else { return }
        switch pdu {
        case 0x02:
            var body = [UInt8]()
            body.appendUInt16BE(4)
            body.appendUInt16BE(1)
            body.appendUInt32BE(0x00010001)
            body.append(0)
            sendSDP(pdu: 0x03, transaction: transaction, body: body, channel: channel)
        case 0x04:
            let attributes = SDPRecord.hidAttributeList()
            var body = [UInt8]()
            body.appendUInt16BE(UInt16(attributes.count))
            body.append(contentsOf: attributes)
            body.append(0)
            sendSDP(pdu: 0x05, transaction: transaction, body: body, channel: channel)
        case 0x06:
            let attributes = SDPRecord.hidServiceSearchAttributeList()
            var body = [UInt8]()
            body.appendUInt16BE(UInt16(attributes.count))
            body.append(contentsOf: attributes)
            body.append(0)
            sendSDP(pdu: 0x07, transaction: transaction, body: body, channel: channel)
        default:
            record("UB500_SDP_PDU pdu=0x\(String(format: "%02X", pdu)) bytes=\(length)")
        }
    }

    private func handleHIDControl(_ payload: [UInt8], channel: L2CAPChannel) {
        guard let first = payload.first else { return }
        let type = first & 0xF0
        switch type {
        case 0x70:
            sendL2CAPPayload([0x00], cid: channel.remoteCID)
        case 0x90:
            sendL2CAPPayload([0x00], cid: channel.remoteCID)
        case 0xA0:
            break
        default:
            record("UB500_HID_CONTROL_RX first=0x\(String(format: "%02X", first)) bytes=\(payload.count)")
        }
    }

    private func enqueueMouse(_ report: HIDMouseReport, settings: MouseSettings) {
        if let pending = pendingMouseReport {
            pendingMouseReport = HIDMouseReport(
                buttons: report.buttons,
                x: clampMouseDelta(Int(pending.x) + Int(report.x), limit: settings.clamp),
                y: clampMouseDelta(Int(pending.y) + Int(report.y), limit: settings.clamp),
                wheel: clampMouseDelta(Int(pending.wheel) + Int(report.wheel), limit: settings.clamp)
            )
        } else {
            pendingMouseReport = report
        }
        guard !mouseFlushScheduled else { return }
        mouseFlushScheduled = true
        let delay = max(0, min(30, settings.coalesceMilliseconds))
        txQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.flushMouse()
        }
    }

    private func flushMouse() {
        mouseFlushScheduled = false
        guard let report = pendingMouseReport else { return }
        pendingMouseReport = nil
        sendHIDInterrupt([0xA1, 0x02] + Array(report.data))
    }

    private func clampMouseDelta(_ value: Int, limit: Int) -> Int8 {
        let boundedLimit = max(1, min(127, limit))
        return Int8(max(-boundedLimit, min(boundedLimit, value)))
    }

    @discardableResult
    private func sendHIDInterrupt(_ payload: [UInt8]) -> Bool {
        guard let localCID = hidInterruptLocalCID, let channel = channelsByLocalCID[localCID] else {
            if hidDropLogCount < 10 {
                hidDropLogCount += 1
                record("UB500_HID_TX_DROPPED no_interrupt_channel bytes=\(payload.count)")
            }
            return false
        }
        sendL2CAPPayload(payload, cid: channel.remoteCID)
        return true
    }

    private var l2capIdentifier: UInt8 = 1
    private func nextIdentifier() -> UInt8 {
        l2capIdentifier &+= 1
        if l2capIdentifier == 0 { l2capIdentifier = 1 }
        return l2capIdentifier
    }

    private func nextCID() -> UInt16 {
        let cid = nextLocalCID
        nextLocalCID += 1
        if nextLocalCID < 0x0040 { nextLocalCID = 0x0040 }
        return cid
    }

    private func openOutgoingL2CAP(psm: UInt16) {
        guard connectionHandle != nil else {
            record("UB500_L2CAP_OUTGOING_NO_ACL psm=0x\(String(format: "%04X", psm))")
            return
        }
        if channelsByLocalCID.values.contains(where: { $0.psm == psm }) {
            record("UB500_L2CAP_OUTGOING_SKIP_EXISTS psm=0x\(String(format: "%04X", psm))")
            return
        }
        let localCID = nextCID()
        channelsByLocalCID[localCID] = L2CAPChannel(localCID: localCID, remoteCID: 0, psm: psm)
        var data = [UInt8]()
        data.appendUInt16LE(psm)
        data.appendUInt16LE(localCID)
        record("UB500_L2CAP_OUTGOING_CONNECT psm=0x\(String(format: "%04X", psm)) local=0x\(String(format: "%04X", localCID))")
        sendL2CAPCommand(code: 0x02, identifier: nextIdentifier(), data: data)
    }

    private func sendL2CAPCommand(code: UInt8, identifier: UInt8, data: [UInt8]) {
        var payload = [code, identifier]
        payload.appendUInt16LE(UInt16(data.count))
        payload.append(contentsOf: data)
        sendL2CAPPayload(payload, cid: 0x0001)
    }

    private func sendSDP(pdu: UInt8, transaction: UInt16, body: [UInt8], channel: L2CAPChannel) {
        var payload = [pdu]
        payload.appendUInt16BE(transaction)
        payload.appendUInt16BE(UInt16(body.count))
        payload.append(contentsOf: body)
        sendL2CAPPayload(payload, cid: channel.remoteCID)
    }

    private func sendL2CAPPayload(_ payload: [UInt8], cid: UInt16) {
        guard let handle, let connectionHandle else { return }
        var l2cap = [UInt8]()
        l2cap.appendUInt16LE(UInt16(payload.count))
        l2cap.appendUInt16LE(cid)
        l2cap.append(contentsOf: payload)
        var packet = [UInt8]()
        packet.appendUInt16LE(connectionHandle | 0x2000)
        packet.appendUInt16LE(UInt16(l2cap.count))
        packet.append(contentsOf: l2cap)
        var mutable = packet
        let mutableCount = mutable.count
        var actual: Int32 = 0
        let result = mutable.withUnsafeMutableBufferPointer { ptr in
            libusb_bulk_transfer(handle, 0x02, ptr.baseAddress, Int32(mutableCount), &actual, 1000)
        }
        if result != 0 || actual != mutableCount {
            record("UB500_ACL_TX_FAILED cid=0x\(String(format: "%04X", cid)) result=\(libusbError(result)) actual=\(actual) expected=\(mutableCount)")
        }
    }


    private func restoreStoredLinkKeysToController() throws {
        let entries = linkKeyStore.allKeys()
        guard !entries.isEmpty else {
            record("UB500_LINK_KEYS_RESTORE count=0")
            return
        }
        for chunk in entries.chunked(maxCount: 11) {
            var parameters = [UInt8(chunk.count)]
            for entry in chunk {
                guard let address = bluetoothAddressLittleEndian(from: entry.address) else { continue }
                parameters.append(contentsOf: address)
                parameters.append(contentsOf: entry.key)
            }
            _ = try hciCommand(opcode: 0x0C11, parameters: parameters)
        }
        record("UB500_LINK_KEYS_RESTORE count=\(entries.count)")
    }

    private func bluetoothAddressLittleEndian(from address: String) -> [UInt8]? {
        let parts = address.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return bytes.reversed()
    }

    private func bluetoothAddress(fromLittleEndian bytes: [UInt8]) -> String {
        bytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func paddedName(_ name: String) -> [UInt8] {
        var bytes = Array(name.utf8.prefix(247))
        bytes.append(0)
        while bytes.count < 248 { bytes.append(0) }
        return bytes
    }

    private func eirData(name: String) -> [UInt8] {
        var eir = [UInt8](repeating: 0, count: 1)
        let nameBytes = Array(name.utf8.prefix(240))
        eir.append(UInt8(nameBytes.count + 1))
        eir.append(0x09)
        eir.append(contentsOf: nameBytes)
        eir.append(3)
        eir.append(0x03)
        eir.append(0x24)
        eir.append(0x11)
        while eir.count < 241 { eir.append(0) }
        return eir
    }

    private func waitCommandComplete(opcode: UInt16) throws -> [UInt8] {
        guard let handle else { throw NativeUB500Error.notOpen }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 260)
            let bufferLength = buffer.count
            var actual: Int32 = 0
            let result = buffer.withUnsafeMutableBufferPointer { ptr in
                libusb_interrupt_transfer(handle, 0x81, ptr.baseAddress, Int32(bufferLength), &actual, 500)
            }
            if result == -7 { continue }
            guard result == 0 else { throw NativeUB500Error.usb("interrupt result=\(libusbError(result))") }
            let event = Array(buffer.prefix(Int(actual)))
            guard event.count >= 5 else { continue }
            if event[0] == 0x0E {
                let eventOpcode = UInt16(event[3]) | (UInt16(event[4]) << 8)
                if eventOpcode == opcode { return event }
            }
        }
        throw NativeUB500Error.timeout(opcode: opcode)
    }

    private func close() {
        if let handle {
            _ = libusb_release_interface(handle, 0)
            libusb_close(handle)
        }
        if let context {
            libusb_exit(context)
        }
        handle = nil
        context = nil
        connectionHandle = nil
        channelsByLocalCID.removeAll()
        hidInterruptLocalCID = nil
        aclConnectedPeers.removeAll()
        hidReadyPeers.removeAll()
    }

    private func firmwareURLs() -> (firmware: URL, config: URL) {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("ub500-firmware")
            let firmware = bundled.appendingPathComponent("rtl8761bu_fw.bin")
            if FileManager.default.fileExists(atPath: firmware.path) {
                return (firmware, bundled.appendingPathComponent("rtl8761bu_config.bin"))
            }
        }
        let root = projectRoot()
        let firmwareDir = root.appendingPathComponent(".build/ub500-firmware")
        return (firmwareDir.appendingPathComponent("rtl8761bu_fw.bin"), firmwareDir.appendingPathComponent("rtl8761bu_config.bin"))
    }

    private func projectRoot() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.path.hasSuffix(".app") {
            return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func publishPeers(status: String) {
        let addresses = Array(Set(linkKeyStore.addresses()).union(aclConnectedPeers).union(hidReadyPeers)).sorted()
        publish(addresses, status)
    }

    private func publish(_ peers: [String], _ status: String) {
        let onChange = onChange
        Task { @MainActor in
            onChange(peers, status)
        }
    }

    private func record(_ line: String) {
        let log = log
        Task { @MainActor in
            log.record(line)
        }
    }
}


private final class LinkKeyStore: @unchecked Sendable {
    private let url: URL
    private let log: RuntimeLog
    private var keys: [String: [UInt8]] = [:]

    init(log: RuntimeLog) {
        self.log = log
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/shareMK", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("classic-link-keys.json")
        load()
    }

    func key(for address: String) -> [UInt8]? {
        keys[address.uppercased()]
    }

    func allKeys() -> [(address: String, key: [UInt8])] {
        keys.map { (address: $0.key, key: $0.value) }
    }

    func addresses() -> [String] {
        keys.keys.sorted()
    }

    func remove(address: String) {
        keys.removeValue(forKey: address.uppercased())
        save()
    }

    func setKey(_ key: [UInt8], for address: String) {
        guard key.count == 16 else { return }
        keys[address.uppercased()] = key
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        var loaded: [String: [UInt8]] = [:]
        for (address, hex) in raw {
            let bytes = Self.decodeHex(hex)
            if bytes.count == 16 { loaded[address.uppercased()] = bytes }
        }
        keys = loaded
    }

    private func save() {
        let raw = keys.mapValues { Self.encodeHex($0) }
        do {
            let data = try JSONEncoder().encode(raw)
            try data.write(to: url, options: [.atomic])
        } catch {
            Task { @MainActor in
                self.log.record("LINK_KEY_SAVE_FAILED error=\(error)")
            }
        }
    }

    private static func encodeHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func decodeHex(_ text: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            guard next <= text.endIndex else { break }
            let part = text[index..<next]
            if let value = UInt8(part, radix: 16) { result.append(value) }
            index = next
        }
        return result
    }
}

private struct L2CAPChannel {
    let localCID: UInt16
    var remoteCID: UInt16
    let psm: UInt16
    var sentConfigure = false
    var receivedConfigure = false
    var remoteAcceptedConfigure = false
}

private enum SDPRecord {
    static func hidServiceSearchAttributeList() -> [UInt8] {
        sequence([hidAttributeList()])
    }

    static func hidAttributeList() -> [UInt8] {
        var elements = [UInt8]()
        func attr(_ id: UInt16, _ value: [UInt8]) {
            elements.append(contentsOf: uint16(id))
            elements.append(contentsOf: value)
        }
        attr(0x0000, uint32(0x00010001))
        attr(0x0001, sequence([uuid16(0x1124)]))
        attr(0x0004, sequence([
            sequence([uuid16(0x0100), uint16(0x0011)]),
            sequence([uuid16(0x0011)])
        ]))
        attr(0x0005, sequence([uuid16(0x1002)]))
        attr(0x0006, sequence([uint16(0x656E), uint16(0x006A), uint16(0x0100)]))
        attr(0x0009, sequence([sequence([uuid16(0x1124), uint16(0x0101)])]))
        attr(0x000D, sequence([sequence([
            sequence([uuid16(0x0100), uint16(0x0013)]),
            sequence([uuid16(0x0011)])
        ])]))
        attr(0x0100, text("shareMK USB HID"))
        attr(0x0200, uint16(0x0111))
        attr(0x0201, uint16(0x0111))
        attr(0x0202, uint8(0xC0))
        attr(0x0203, uint8(0x00))
        attr(0x0204, bool(true))
        attr(0x0205, bool(true))
        attr(0x0206, sequence([sequence([uint8(0x22), textBytes(hidDescriptor())])]))
        attr(0x0207, sequence([sequence([uint16(0x0409), uint16(0x0100)])]))
        attr(0x0208, bool(false))
        attr(0x0209, bool(false))
        attr(0x020A, bool(true))
        attr(0x020B, uint16(0x0101))
        attr(0x020C, uint16(0x0C80))
        attr(0x020D, bool(true))
        attr(0x020E, bool(true))
        return sequence([elements])
    }

    private static func hidDescriptor() -> [UInt8] {
        [
            0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
            0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00,
            0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
            0x95,0x01, 0x75,0x08, 0x81,0x01, 0x95,0x05,
            0x75,0x01, 0x05,0x08, 0x19,0x01, 0x29,0x05,
            0x91,0x02, 0x95,0x01, 0x75,0x03, 0x91,0x01,
            0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65,
            0x05,0x07, 0x19,0x00, 0x29,0x65, 0x81,0x00,
            0xC0,
            0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
            0x09,0x01, 0xA1,0x00, 0x05,0x09, 0x19,0x01,
            0x29,0x03, 0x15,0x00, 0x25,0x01, 0x95,0x03,
            0x75,0x01, 0x81,0x02, 0x95,0x01, 0x75,0x05,
            0x81,0x01, 0x05,0x01, 0x09,0x30, 0x09,0x31,
            0x09,0x38, 0x15,0x81, 0x25,0x7F, 0x75,0x08,
            0x95,0x03, 0x81,0x06, 0xC0,0xC0
        ]
    }

    private static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        let body = elements.flatMap { $0 }
        return dataElement(type: 0x30, payload: body)
    }

    private static func uint8(_ value: UInt8) -> [UInt8] { [0x08, value] }
    private static func uint16(_ value: UInt16) -> [UInt8] { [0x09, UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func uint32(_ value: UInt32) -> [UInt8] { [0x0A, UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    private static func uuid16(_ value: UInt16) -> [UInt8] { [0x19, UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func bool(_ value: Bool) -> [UInt8] { [0x28, value ? 1 : 0] }
    private static func text(_ value: String) -> [UInt8] { textBytes(Array(value.utf8)) }
    private static func textBytes(_ value: [UInt8]) -> [UInt8] { dataElement(type: 0x20, payload: value) }

    private static func dataElement(type: UInt8, payload: [UInt8]) -> [UInt8] {
        if payload.count <= 0xFF {
            return [type | 5, UInt8(payload.count)] + payload
        }
        return [type | 6, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }
}

struct RealtekFirmware {
    let version: UInt32
    private let patches: [(chipID: UInt16, payload: Data)]

    init(data: Data) throws {
        let signature = Data("Realtech".utf8)
        guard data.starts(with: signature), data.suffix(4) == Data([0x51, 0x04, 0xFD, 0x77]),
              data.count >= 14 else {
            throw NativeUB500Error.firmware("invalid Realtek firmware")
        }
        version = data.readUInt32LE(at: 8)
        let count = Int(data.readUInt16LE(at: 12))
        let chipTable = 14
        let lengthTable = chipTable + 2 * count
        let offsetTable = chipTable + 4 * count
        guard offsetTable + 4 * count <= data.count else {
            throw NativeUB500Error.firmware("truncated patch table")
        }
        var result: [(UInt16, Data)] = []
        for index in 0..<count {
            let chipID = data.readUInt16LE(at: chipTable + 2 * index)
            let length = Int(data.readUInt16LE(at: lengthTable + 2 * index))
            let offset = Int(data.readUInt32LE(at: offsetTable + 4 * index))
            guard offset + length <= data.count, length >= 4 else {
                throw NativeUB500Error.firmware("invalid patch bounds")
            }
            var payload = data.subdata(in: offset..<(offset + length - 4))
            payload.append(contentsOf: [
                UInt8(version & 0xFF),
                UInt8((version >> 8) & 0xFF),
                UInt8((version >> 16) & 0xFF),
                UInt8((version >> 24) & 0xFF)
            ])
            result.append((chipID, payload))
        }
        patches = result
    }

    func patchPayload(forChipID chipID: UInt16) throws -> Data {
        guard let patch = patches.first(where: { $0.chipID == chipID }) else {
            throw NativeUB500Error.firmware("patch not found chipID=\(chipID)")
        }
        return patch.payload
    }
}

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
        | (UInt32(self[offset + 1]) << 8)
        | (UInt32(self[offset + 2]) << 16)
        | (UInt32(self[offset + 3]) << 24)
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: maxCount, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}

private extension Array where Element == UInt8 {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

enum NativeUB500Error: Error, CustomStringConvertible {
    case notOpen
    case shortEvent
    case timeout(opcode: UInt16)
    case hciStatus(opcode: UInt16, status: UInt8)
    case usb(String)
    case firmware(String)

    var description: String {
        switch self {
        case .notOpen: "UB500 not open"
        case .shortEvent: "short HCI event"
        case .timeout(let opcode): "HCI timeout opcode=0x\(String(format: "%04X", opcode))"
        case .hciStatus(let opcode, let status): "HCI status opcode=0x\(String(format: "%04X", opcode)) status=0x\(String(format: "%02X", status))"
        case .usb(let message): message
        case .firmware(let message): message
        }
    }
}
