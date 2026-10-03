import AppKit
import ApplicationServices

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onDeletePairing: ((String) -> Void)?
    var onReconnect: ((String) -> Void)?
    var onNameChanged: (() -> Void)?
    var onAppSettingsChanged: (() -> Void)?

    private let tableView = NSTableView()
    private let leftScrollView = NSScrollView()
    private let nameField = NSTextField(string: "")
    private let addressValue = NSTextField(labelWithString: "")
    private let statusValue = NSTextField(labelWithString: "")
    private let outputModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mouseScaleField = NSTextField(string: "")
    private let mouseClampField = NSTextField(string: "")
    private let mouseCoalesceField = NSTextField(string: "")
    private let swapCheckbox = NSButton(checkboxWithTitle: "CommandキーとControlキーを入れ替える", target: nil, action: nil)
    private let hotKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let permissionStateValue = NSTextField(labelWithString: "")
    private let requestAccessibilityButton = NSButton(title: "アクセシビリティを再認証", target: nil, action: nil)
    private let requestInputMonitoringButton = NSButton(title: "入力監視を再認証", target: nil, action: nil)
    private let openPrivacyButton = NSButton(title: "システム設定を開く", target: nil, action: nil)
    private let deleteButton = NSButton(title: "ペアリング削除", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "再接続", target: nil, action: nil)
    private var deviceColumn: NSTableColumn?
    private var devices: [String] = []
    private var connected: Set<String> = []
    private var hidReady: Set<String> = []
    private var detailViews: [NSView] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "shareMK 設定"
        window.minSize = NSSize(width: 820, height: 500)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func update(devices: [String], connected: [String], hidReady: [String]) {
        let previousSelection = selectedAddress
        self.devices = devices.sorted()
        self.connected = Set(connected)
        self.hidReady = Set(hidReady)
        tableView.reloadData()
        deviceColumn?.width = max(0, leftScrollView.contentSize.width)

        if let previousSelection, let index = self.devices.firstIndex(of: previousSelection) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !self.devices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateSelectionUI()
        updateAppSettingsUI()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        if selectedAddress == nil, !devices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSelectionUI()
        updateAppSettingsUI()
    }

    private var selectedAddress: String? {
        let row = tableView.selectedRow
        guard devices.indices.contains(row) else { return nil }
        return devices[row]
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: content.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let devicesView = NSView()
        let appView = NSView()
        let devicesTab = NSTabViewItem(identifier: "devices")
        devicesTab.label = "接続先"
        devicesTab.view = devicesView
        let appTab = NSTabViewItem(identifier: "app")
        appTab.label = "アプリ設定"
        appTab.view = appView
        tabs.addTabViewItem(devicesTab)
        tabs.addTabViewItem(appTab)

        buildDevicesTab(devicesView)
        buildAppTab(appView)
    }

    private func buildDevicesTab(_ content: NSView) {
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let left = NSView()
        let right = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(equalToConstant: 320).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        buildLeftPane(left)
        buildDeviceDetail(right)
        split.setPosition(320, ofDividerAt: 0)
    }

    private func buildLeftPane(_ left: NSView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        column.title = "ペアリング"
        column.width = 320
        deviceColumn = column
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(selectionChanged)

        leftScrollView.translatesAutoresizingMaskIntoConstraints = false
        leftScrollView.documentView = tableView
        leftScrollView.hasVerticalScroller = true
        leftScrollView.borderType = .noBorder
        left.addSubview(leftScrollView)

        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(buttonBar)

        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectSelected)
        buttonBar.addSubview(reconnectButton)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        buttonBar.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            leftScrollView.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftScrollView.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftScrollView.topAnchor.constraint(equalTo: left.topAnchor),
            leftScrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),

            buttonBar.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 52),

            reconnectButton.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 12),
            reconnectButton.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            reconnectButton.widthAnchor.constraint(equalToConstant: 132),

            deleteButton.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 152)
        ])
    }

    private func buildDeviceDetail(_ right: NSView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        right.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: right.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: right.bottomAnchor)
        ])

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -28)
        ])

        addDetail(stack, sectionTitle("接続"))
        addDetail(stack, row(label: "表示名", control: nameField))
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameEdited)
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        addDetail(stack, row(label: "アドレス", control: addressValue))
        addressValue.textColor = .secondaryLabelColor
        addDetail(stack, row(label: "状態", control: statusValue))

        outputModePopup.addItems(withTitles: OutputMode.allCases.map(\.title))
        outputModePopup.target = self
        outputModePopup.action = #selector(outputModeChanged)
        addDetail(stack, row(label: "出力対象", control: outputModePopup))

        addDetail(stack, spacer(height: 12))
        addDetail(stack, sectionTitle("キー設定"))
        swapCheckbox.state = AppSettings.shared.swapCommandAndControl ? .on : .off
        swapCheckbox.target = self
        swapCheckbox.action = #selector(toggleSwap)
        addDetail(stack, swapCheckbox)
        addDetail(stack, helpLabel("この設定は選択中の接続先にキーボードを送る場合だけ効きます。"))

        addDetail(stack, spacer(height: 12))
        addDetail(stack, sectionTitle("マウス設定"))
        configureNumberField(mouseScaleField)
        addDetail(stack, row(label: "移動倍率", control: mouseScaleField))
        configureNumberField(mouseClampField)
        addDetail(stack, row(label: "上限", control: mouseClampField))
        configureNumberField(mouseCoalesceField)
        addDetail(stack, row(label: "合成間隔ms", control: mouseCoalesceField))
        addDetail(stack, helpLabel("Windowsで遅延や急な移動が出る場合は、移動倍率を下げる、合成間隔msを小さくする、上限を下げる順で調整してください。"))
    }

    private func buildAppTab(_ content: NSView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -28)
        ])

        stack.addArrangedSubview(sectionTitle("切替ホットキー"))
        hotKeyPopup.addItems(withTitles: HotKeyMode.allCases.map(\.title))
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyModeChanged)
        stack.addArrangedSubview(row(label: "方式", control: hotKeyPopup))
        stack.addArrangedSubview(helpLabel("1番がMac、2番以降がメニュー順の接続先です。ホットキー方式を変えると即時に再登録します。"))

        stack.addArrangedSubview(spacer(height: 12))
        stack.addArrangedSubview(sectionTitle("権限"))
        stack.addArrangedSubview(row(label: "状態", control: permissionStateValue))
        requestAccessibilityButton.target = self
        requestAccessibilityButton.action = #selector(requestAccessibilityPermission)
        requestInputMonitoringButton.target = self
        requestInputMonitoringButton.action = #selector(requestInputMonitoringPermission)
        openPrivacyButton.target = self
        openPrivacyButton.action = #selector(openPrivacySettings)
        stack.addArrangedSubview(buttonRow([requestAccessibilityButton, requestInputMonitoringButton, openPrivacyButton]))
        stack.addArrangedSubview(helpLabel("macOSの制約により、許可済みの項目で確認ダイアログが再表示されない場合があります。"))
    }

    private func addDetail(_ stack: NSStackView, _ view: NSView) {
        stack.addArrangedSubview(view)
        detailViews.append(view)
    }

    private func configureNumberField(_ field: NSTextField) {
        field.delegate = self
        field.target = self
        field.action = #selector(mouseSettingsEdited)
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 16, weight: .semibold)
        return field
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func helpLabel(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 4
        field.preferredMaxLayoutWidth = 480
        return field
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func row(label: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let labelView = NSTextField(labelWithString: label)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labelView)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            labelView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            labelView.widthAnchor.constraint(equalToConstant: 110),
            control.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 20),
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = id
        let address = devices[row]
        let name = AppSettings.shared.displayName(for: address)
        let state = connected.contains(address) ? "接続済み" : "未接続"
        field.stringValue = "\(connected.contains(address) ? "●" : "○") \(name) (\(address))（\(state)）"
        field.textColor = connected.contains(address) ? .labelColor : .secondaryLabelColor
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === nameField {
            saveName()
        } else {
            saveMouseSettings()
        }
    }

    @objc private func selectionChanged() { updateSelectionUI() }

    @objc private func toggleSwap() {
        AppSettings.shared.swapCommandAndControl = swapCheckbox.state == .on
    }

    @objc private func outputModeChanged() {
        guard let selectedAddress else { return }
        let index = outputModePopup.indexOfSelectedItem
        guard OutputMode.allCases.indices.contains(index) else { return }
        AppSettings.shared.setOutputMode(OutputMode.allCases[index], for: selectedAddress)
        onAppSettingsChanged?()
    }

    @objc private func hotKeyModeChanged() {
        let index = hotKeyPopup.indexOfSelectedItem
        guard HotKeyMode.allCases.indices.contains(index) else { return }
        AppSettings.shared.hotKeyMode = HotKeyMode.allCases[index]
        onAppSettingsChanged?()
    }

    @objc private func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updateAppSettingsUI()
    }

    @objc private func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        updateAppSettingsUI()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func nameEdited() { saveName() }

    @objc private func mouseSettingsEdited() { saveMouseSettings() }

    @objc private func reconnectSelected() {
        guard let selectedAddress else { return }
        onReconnect?(selectedAddress)
    }

    @objc private func deleteSelected() {
        guard let selectedAddress else { return }
        AppSettings.shared.removeDevice(address: selectedAddress)
        onDeletePairing?(selectedAddress)
        onNameChanged?()
    }

    private func saveName() {
        guard let selectedAddress else { return }
        AppSettings.shared.setDisplayName(nameField.stringValue, for: selectedAddress)
        tableView.reloadData()
        onNameChanged?()
    }

    private func saveMouseSettings() {
        guard let selectedAddress else { return }
        let scale = clampDouble(mouseScaleField.doubleValue, min: 0.1, max: 3.0, fallback: 0.5)
        let clamp = clampInt(mouseClampField.integerValue, min: 1, max: 127, fallback: 63)
        let coalesce = clampInt(mouseCoalesceField.integerValue, min: 0, max: 30, fallback: 6)
        let settings = MouseSettings(scale: scale, clamp: clamp, coalesceMilliseconds: coalesce)
        AppSettings.shared.setMouseSettings(settings, for: selectedAddress)
        mouseScaleField.stringValue = formatScale(scale)
        mouseClampField.integerValue = clamp
        mouseCoalesceField.integerValue = coalesce
    }

    private func clampDouble(_ value: Double, min: Double, max: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return Swift.max(min, Swift.min(max, value))
    }

    private func clampInt(_ value: Int, min: Int, max: Int, fallback: Int) -> Int {
        guard value > 0 || min == 0 else { return fallback }
        return Swift.max(min, Swift.min(max, value))
    }

    private func formatScale(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func updateSelectionUI() {
        if selectedAddress == nil, !devices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        let hasSelection = selectedAddress != nil
        deleteButton.isEnabled = hasSelection
        reconnectButton.isEnabled = hasSelection
        detailViews.forEach { $0.isHidden = !hasSelection }

        guard let selectedAddress else {
            nameField.stringValue = ""
            addressValue.stringValue = ""
            statusValue.stringValue = ""
            mouseScaleField.stringValue = ""
            mouseClampField.stringValue = ""
            mouseCoalesceField.stringValue = ""
            return
        }
        nameField.stringValue = AppSettings.shared.displayName(for: selectedAddress)
        addressValue.stringValue = selectedAddress
        statusValue.stringValue = connected.contains(selectedAddress) ? "接続済み" : "未接続"
        statusValue.textColor = connected.contains(selectedAddress) ? .labelColor : .secondaryLabelColor
        let outputMode = AppSettings.shared.outputMode(for: selectedAddress)
        outputModePopup.selectItem(at: OutputMode.allCases.firstIndex(of: outputMode) ?? 0)
        let mouse = AppSettings.shared.mouseSettings(for: selectedAddress)
        mouseScaleField.stringValue = formatScale(mouse.scale)
        mouseClampField.integerValue = mouse.clamp
        mouseCoalesceField.integerValue = mouse.coalesceMilliseconds
    }

    private func updateAppSettingsUI() {
        let hotKeyMode = AppSettings.shared.hotKeyMode
        hotKeyPopup.selectItem(at: HotKeyMode.allCases.firstIndex(of: hotKeyMode) ?? 0)
        let accessibility = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        permissionStateValue.stringValue = "アクセシビリティ: \(accessibility ? "許可済み" : "未許可") / 入力監視: \(listen ? "許可済み" : "未許可")"
        permissionStateValue.textColor = (accessibility && listen) ? .labelColor : .systemRed
    }
}
