import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onDeletePairing: ((String) -> Void)?
    var onReconnect: ((String) -> Void)?
    var onNameChanged: (() -> Void)?

    private let tableView = NSTableView()
    private let leftScrollView = NSScrollView()
    private let nameField = NSTextField(string: "")
    private let addressValue = NSTextField(labelWithString: "")
    private let statusValue = NSTextField(labelWithString: "")
    private let mouseScaleField = NSTextField(string: "")
    private let mouseClampField = NSTextField(string: "")
    private let mouseCoalesceField = NSTextField(string: "")
    private let swapCheckbox = NSButton(checkboxWithTitle: "CommandキーとControlキーを入れ替える", target: nil, action: nil)
    private let deleteButton = NSButton(title: "ペアリング削除", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "再接続", target: nil, action: nil)
    private var deviceColumn: NSTableColumn?
    private var devices: [String] = []
    private var connected: Set<String> = []
    private var hidReady: Set<String> = []
    private var detailViews: [NSView] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "shareMK 設定"
        window.minSize = NSSize(width: 780, height: 460)
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
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        if selectedAddress == nil, !devices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSelectionUI()
    }

    private var selectedAddress: String? {
        let row = tableView.selectedRow
        guard devices.indices.contains(row) else { return nil }
        return devices[row]
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

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
        buildRightPane(right)
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

    private func buildRightPane(_ right: NSView) {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        right.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: right.topAnchor, constant: 32)
        ])

        let connectionTitle = sectionTitle("接続")
        stack.addArrangedSubview(connectionTitle)
        detailViews.append(connectionTitle)

        stack.addArrangedSubview(row(label: "表示名", control: nameField))
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameEdited)
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        detailViews.append(nameField)

        stack.addArrangedSubview(row(label: "アドレス", control: addressValue))
        addressValue.textColor = .secondaryLabelColor
        detailViews.append(addressValue)

        stack.addArrangedSubview(row(label: "状態", control: statusValue))
        detailViews.append(statusValue)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(spacer)
        detailViews.append(spacer)

        let keyTitle = sectionTitle("キー設定")
        stack.addArrangedSubview(keyTitle)
        detailViews.append(keyTitle)

        swapCheckbox.state = AppSettings.shared.swapCommandAndControl ? .on : .off
        swapCheckbox.target = self
        swapCheckbox.action = #selector(toggleSwap)
        stack.addArrangedSubview(swapCheckbox)
        detailViews.append(swapCheckbox)

        let help = NSTextField(wrappingLabelWithString: "Windows側でCommand/Ctrlの扱いが合わない場合に切り替えてください。今後のキー割り当て設定もここへ追加します。")
        help.textColor = .secondaryLabelColor
        help.maximumNumberOfLines = 3
        stack.addArrangedSubview(help)
        detailViews.append(help)

        let mouseSpacer = NSView()
        mouseSpacer.translatesAutoresizingMaskIntoConstraints = false
        mouseSpacer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(mouseSpacer)
        detailViews.append(mouseSpacer)

        let mouseTitle = sectionTitle("マウス設定")
        stack.addArrangedSubview(mouseTitle)
        detailViews.append(mouseTitle)

        configureNumberField(mouseScaleField)
        stack.addArrangedSubview(row(label: "移動倍率", control: mouseScaleField))

        configureNumberField(mouseClampField)
        stack.addArrangedSubview(row(label: "上限", control: mouseClampField))

        configureNumberField(mouseCoalesceField)
        stack.addArrangedSubview(row(label: "合成間隔ms", control: mouseCoalesceField))

        let mouseHelp = NSTextField(wrappingLabelWithString: "Windowsで遅延や急な移動が出る場合は、移動倍率を下げる、合成間隔msを小さくする、上限を下げる順で調整してください。")
        mouseHelp.textColor = .secondaryLabelColor
        mouseHelp.maximumNumberOfLines = 3
        stack.addArrangedSubview(mouseHelp)
        detailViews.append(mouseHelp)
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
            labelView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            labelView.widthAnchor.constraint(equalToConstant: 90),
            control.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 20),
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        detailViews.append(row)
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
        let mouse = AppSettings.shared.mouseSettings(for: selectedAddress)
        mouseScaleField.stringValue = formatScale(mouse.scale)
        mouseClampField.integerValue = mouse.clamp
        mouseCoalesceField.integerValue = mouse.coalesceMilliseconds
    }
}
