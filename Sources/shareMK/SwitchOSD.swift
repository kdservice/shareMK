import AppKit

@MainActor
final class SwitchOSD {
    private let window: NSWindow
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let size = NSSize(width: 280, height: 118)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 24
        effect.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 112, y: 62, width: 56, height: 40))
        icon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 38, weight: .regular)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(icon)

        label = NSTextField(labelWithString: "Mac")
        label.frame = NSRect(x: 18, y: 22, width: size.width - 36, height: 26)
        label.alignment = .center
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        effect.addSubview(label)

        window.contentView = effect
        center()
    }

    func show(_ text: String, persistent: Bool) {
        hideWorkItem?.cancel()
        label.stringValue = text
        center()
        window.alphaValue = 1
        window.orderFrontRegardless()
        guard !persistent else { return }
        let item = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: item)
    }

    private func center() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }
}
