import Foundation

@MainActor
final class RuntimeLog {
    let url: URL
    private let file: FileHandle?

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/shareMK", isDirectory: true)
        url = directory.appendingPathComponent("runtime.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }

    func record(_ text: String) {
        let line = "\(Date().ISO8601Format()) \(text)\n"
        try? file?.write(contentsOf: Data(line.utf8))
        print(line, terminator: "")
    }
}
