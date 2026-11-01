import Foundation

struct TransferHistoryEntry: Codable {
    enum Direction: String, Codable { case sent, received }
    let date: Date
    let direction: Direction
    let deviceName: String
    let fileCount: Int
    let bytes: Int64
    let success: Bool
}

final class HistoryStore {
    static let shared = HistoryStore()
    private let lock = NSLock()
    private(set) var entries: [TransferHistoryEntry] = []
    private static let maxEntries = 200

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("QuickShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    init() {
        load()
    }

    func record(direction: TransferHistoryEntry.Direction, deviceName: String?, fileCount: Int, bytes: Int64, success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries.insert(TransferHistoryEntry(date: Date(), direction: direction, deviceName: deviceName ?? "Android device", fileCount: fileCount, bytes: bytes, success: success), at: 0)
        if entries.count > HistoryStore.maxEntries {
            entries = Array(entries.prefix(HistoryStore.maxEntries))
        }
        let latest = entries[0]
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let line = try? JSONEncoder().encode(latest) else { return }
            var data = line
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func load() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return }
        var loaded: [TransferHistoryEntry] = []
        for line in data.split(separator: 0x0A).suffix(HistoryStore.maxEntries) {
            if let entry = try? JSONDecoder().decode(TransferHistoryEntry.self, from: Data(line)) {
                loaded.append(entry)
            }
        }
        entries = loaded.reversed()
    }
}
