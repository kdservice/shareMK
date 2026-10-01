import Foundation

struct MouseSettings: Codable {
    var scale: Double = 0.5
    var clamp: Int = 63
    var coalesceMilliseconds: Int = 6
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

    func removeDevice(address: String) {
        let key = address.uppercased()
        values.displayNames.removeValue(forKey: key)
        values.mouseSettings.removeValue(forKey: key)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private struct Values: Codable {
        var swapCommandAndControl = false
        var displayNames: [String: String] = [:]
        var mouseSettings: [String: MouseSettings] = [:]
    }
}
