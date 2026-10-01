import AppKit


@MainActor
final class UB500DiagnosticApp: NSObject, NSApplicationDelegate {
    private let peer: String
    private let log = RuntimeLog()
    private var ub500: NativeUB500Controller!
    private var didStartReconnect = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(peer: String) {
        self.peer = peer.uppercased()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.record("DIAG_LAUNCH peer=\(peer) pid=\(ProcessInfo.processInfo.processIdentifier)")
        ub500 = NativeUB500Controller(log: log) { [weak self] peers, status in
            self?.handleUpdate(peers: peers, status: status)
        }
        ub500.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.startReconnectIfNeeded(reason: "timer")
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log.record("DIAG_TIMEOUT peer=\(self.peer) hid_ready=\(self.ub500.hidReadyAddresses().contains(self.peer))")
            NSApplication.shared.terminate(nil)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 65, execute: timeout)
    }

    private func handleUpdate(peers: [String], status: String) {
        log.record("DIAG_STATUS status=\(status) peers=\(peers.joined(separator: ",")) hid=\(ub500?.hidReadyAddresses().joined(separator: ",") ?? "")")
        if ub500?.hidReadyAddresses().contains(peer) == true {
            log.record("DIAG_SUCCESS peer=\(peer)")
            timeoutWorkItem?.cancel()
            NSApplication.shared.terminate(nil)
            return
        }
        if status.contains("待受") || peers.contains(peer) {
            startReconnectIfNeeded(reason: "status")
        }
    }

    private func startReconnectIfNeeded(reason: String) {
        guard !didStartReconnect else { return }
        didStartReconnect = true
        log.record("DIAG_RECONNECT_START peer=\(peer) reason=\(reason)")
        ub500.reconnect(address: peer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ub500?.stop()
        log.record("DIAG_TERMINATE peer=\(peer)")
    }
}

@MainActor
final class StatusBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var ub500: NativeUB500Controller!
    private var inputCapture: InputCapture!
    private let osd = SwitchOSD()
    private let log = RuntimeLog()
    private lazy var settingsWindow = SettingsWindowController()
    private var peers: [String] = []
    private var connectedPeers: Set<String> = []
    private var hidReadyPeers: Set<String> = []
    private var selectedPeer: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.sharemk.shareMK")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            log.record("DUPLICATE_INSTANCE exit")
            NSApplication.shared.terminate(nil)
            return
        }
        log.record("LAUNCH bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "shareMK")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        if icon == nil { statusItem.button?.title = "⌨" }
        updateMenu(peers: [], status: "UB500初期化中")
        ub500 = NativeUB500Controller(log: log) { [weak self] peers, status in
            self?.updateMenu(peers: peers, status: status)
        }
        settingsWindow.onReconnect = { [weak self] address in
            self?.ub500.reconnect(address: address)
        }
        settingsWindow.onDeletePairing = { [weak self] address in
            AppSettings.shared.removeDevice(address: address)
            self?.ub500.deletePairing(address: address)
            self?.updateMenu(peers: self?.peers ?? [], status: "ペアリング削除")
        }
        settingsWindow.onNameChanged = { [weak self] in
            self?.updateMenu(peers: self?.peers ?? [], status: "設定更新")
        }
        inputCapture = InputCapture()
        inputCapture.onSwitch = { [weak self] slot in self?.switchToSlot(slot) }
        inputCapture.onKeyboard = { [weak self] report in
            guard let self, let selectedPeer else { return }
            self.ub500.sendKeyboard(report, to: selectedPeer)
        }
        inputCapture.onMouse = { [weak self] buttons, dx, dy, wheel in
            guard let self, let selectedPeer else { return }
            let settings = AppSettings.shared.mouseSettings(for: selectedPeer)
            let report = HIDMouseReport(buttons: buttons, dx: dx, dy: dy, wheelDelta: wheel, settings: settings)
            self.ub500.sendMouse(report, to: selectedPeer, settings: settings)
        }
        inputCapture.onMouseButton = { [weak self] report in
            guard let self, let selectedPeer else { return }
            let settings = AppSettings.shared.mouseSettings(for: selectedPeer)
            self.ub500.sendMouse(report, to: selectedPeer, settings: settings)
        }
        inputCapture.onDiagnostic = { [weak self] message in
            self?.log.record(message)
        }
        ub500.start()
        inputCapture.start()
    }

    private func updateMenu(peers: [String], status: String) {
        self.peers = peers.sorted()
        connectedPeers = Set(ub500?.connectedAddresses() ?? [])
        hidReadyPeers = Set(ub500?.hidReadyAddresses() ?? [])
        if let selectedPeer, !self.peers.contains(selectedPeer) {
            switchToMac(label: "Mac")
        }
        settingsWindow.update(devices: self.peers, connected: Array(connectedPeers), hidReady: Array(hidReadyPeers))
        statusItem.button?.toolTip = "shareMK — \(status)"
        let menu = NSMenu()
        let macItem = NSMenuItem(title: selectedPeer == nil ? "送信先: Mac" : "Macへ戻す（⌃⌥⌘1）",
                                 action: #selector(selectMac), keyEquivalent: "")
        macItem.target = self
        menu.addItem(macItem)
        if !self.peers.isEmpty { menu.addItem(.separator()) }
        for (index, peer) in self.peers.enumerated() {
            let connected = connectedPeers.contains(peer)
            let display = "\(AppSettings.shared.displayName(for: peer)) (\(peer))"
            let active = ub500?.activeHIDAddress() == peer
            let prefix = selectedPeer == peer ? (active ? "送信中" : "選択中") : (connected ? "子機\(index + 2)" : "未接続")
            let item = NSMenuItem(title: "\(prefix): \(display)（⌃⌥⌘\(index + 2)）",
                                  action: #selector(selectPeerFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = peer
            item.attributedTitle = menuTitle(item.title, enabled: connected)
            menu.addItem(item)
        }
        if !self.peers.isEmpty { menu.addItem(.separator()) }
        let pairingTitle = (ub500?.isPairingModeEnabled() ?? false) ? "ペアリングモード終了" : "ペアリングモード開始"
        let pairing = NSMenuItem(title: pairingTitle, action: #selector(togglePairingMode), keyEquivalent: "")
        pairing.target = self
        menu.addItem(pairing)
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func switchToSlot(_ slot: Int) {
        if slot == 1 {
            switchToMac(label: "Mac")
            return
        }
        let childIndex = slot - 2
        guard peers.indices.contains(childIndex) else {
            switchToMac(label: "子機なし")
            return
        }
        let label = peers[childIndex]
        switchToAddress(label, slot: slot)
    }

    private func switchToAddress(_ address: String, slot: Int? = nil) {
        releaseCurrentInput()
        ub500.prepareSwitch(to: address)
        selectedPeer = address
        inputCapture.setChildMode(true)
        osd.show(AppSettings.shared.displayName(for: address), persistent: true)
        let resolvedSlot = slot ?? ((peers.firstIndex(of: address) ?? 0) + 2)
        log.record("TARGET_SWITCH slot=\(resolvedSlot) peer=\(address)")
        updateMenu(peers: peers, status: "UB500 HID接続中")
    }

    private func switchToMac(label: String) {
        releaseCurrentInput()
        selectedPeer = nil
        ub500.cancelReconnect()
        inputCapture.setChildMode(false)
        osd.show(label, persistent: false)
        log.record("TARGET_SWITCH slot=1 peer=Mac")
        updateMenu(peers: peers, status: peers.isEmpty ? "UB500 HID接続待機中" : "UB500 HID接続中")
    }

    private func releaseCurrentInput() {
        guard let selectedPeer else { return }
        _ = selectedPeer
        ub500.releaseInput()
    }

    private func menuTitle(_ text: String, enabled: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: enabled ? NSColor.labelColor : NSColor.secondaryLabelColor])
    }

    @objc private func selectMac() { switchToSlot(1) }

    @objc private func selectPeerFromMenu(_ sender: NSMenuItem) {
        guard let peer = sender.representedObject as? String,
              let index = peers.firstIndex(of: peer) else { return }
        switchToSlot(index + 2)
    }

    @objc private func openSettings() { settingsWindow.showWindow(nil) }

    @objc private func togglePairingMode() {
        if ub500.isPairingModeEnabled() {
            ub500.stopPairingMode()
        } else {
            ub500.startPairingMode()
        }
        updateMenu(peers: peers, status: "ペアリングモード切替")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        inputCapture?.stop()
        ub500?.stop()
    }
}

let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--ub500-diagnostic"),
   CommandLine.arguments.indices.contains(index + 1) {
    let delegate = UB500DiagnosticApp(peer: CommandLine.arguments[index + 1])
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
} else {
    let delegate = StatusBarApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
