import Foundation

struct MouseSettings: Codable {
    var scale: Double = 0.5
    var clamp: Int = 63
    var coalesceMilliseconds: Int = 6
}

enum OutputMode: String, Codable, CaseIterable {
    case both
    case keyboardOnly
    case mouseOnly
    case none

    var sendsKeyboard: Bool { self == .both || self == .keyboardOnly }
    var sendsMouse: Bool { self == .both || self == .mouseOnly }

    var title: String {
        switch self {
        case .both: "キーボードとマウス"
        case .keyboardOnly: "キーボードのみ"
        case .mouseOnly: "マウスのみ"
        case .none: "出力しない"
        }
    }
}

enum HotKeyMode: String, Codable, CaseIterable {
    case controlOptionCommandNumber
    case controlCommandFunction

    var title: String {
        switch self {
        case .controlOptionCommandNumber: "Ctrl + Option + Command + 数字"
        case .controlCommandFunction: "Ctrl + Command + F1〜F12"
        }
    }

    var menuHintPrefix: String {
        switch self {
        case .controlOptionCommandNumber: "⌃⌥⌘"
        case .controlCommandFunction: "⌃⌘F"
        }
    }
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let url: URL
    private var values: Values

    var swapCommandAndControl: Bool {
        get { values.swapCommandAndControl }
        set {
            values.swapCommandAndControl = newValue
            save()
        }
    }

    var hotKeyMode: HotKeyMode {
        get { values.hotKeyMode }
        set {
            values.hotKeyMode = newValue
            save()
        }
    }

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/shareMK", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
        }
    }

    func displayName(for address: String) -> String {
        let key = address.uppercased()
        return values.displayNames[key]?.isEmpty == false ? values.displayNames[key]! : "PC"
    }

    func setDisplayName(_ name: String, for address: String) {
        let key = address.uppercased()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.displayNames.removeValue(forKey: key)
        } else {
            values.displayNames[key] = trimmed
        }
        save()
    }

    func mouseSettings(for address: String) -> MouseSettings {
        values.mouseSettings[address.uppercased()] ?? MouseSettings()
    }

    func setMouseSettings(_ settings: MouseSettings, for address: String) {
        values.mouseSettings[address.uppercased()] = settings
        save()
    }

    func outputMode(for address: String) -> OutputMode {
        values.outputModes[address.uppercased()] ?? .both
    }

    func setOutputMode(_ mode: OutputMode, for address: String) {
        values.outputModes[address.uppercased()] = mode
        save()
    }

    func removeDevice(address: String) {
        let key = address.uppercased()
        values.displayNames.removeValue(forKey: key)
        values.mouseSettings.removeValue(forKey: key)
        values.outputModes.removeValue(forKey: key)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private struct Values: Codable {
        var swapCommandAndControl = false
        var hotKeyMode: HotKeyMode = .controlOptionCommandNumber
        var displayNames: [String: String] = [:]
        var mouseSettings: [String: MouseSettings] = [:]
        var outputModes: [String: OutputMode] = [:]
    }
}
