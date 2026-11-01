import Foundation

struct QSPreferences: Codable {
    var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    var autoOffMinutes: Int = 15
    var deviceName: String = Host.current().localizedName ?? "Mac"
    var autoAcceptKnown: Bool = false

    enum CodingKeys: String, CodingKey {
        case destinationBookmark, autoOffMinutes, deviceName, autoAcceptKnown
    }

    init() {}
    init(destination: URL, autoOffMinutes: Int, deviceName: String, autoAcceptKnown: Bool) {
        self.destination = destination
        self.autoOffMinutes = autoOffMinutes
        self.deviceName = deviceName
        self.autoAcceptKnown = autoAcceptKnown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoOffMinutes = (try? c.decode(Int.self, forKey: .autoOffMinutes)) ?? 15
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? (Host.current().localizedName ?? "Mac")
        autoAcceptKnown = (try? c.decode(Bool.self, forKey: .autoAcceptKnown)) ?? false
        if let bookmark = try? c.decode(Data.self, forKey: .destinationBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                destination = url
            } else {
                destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            }
        } else {
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoOffMinutes, forKey: .autoOffMinutes)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(autoAcceptKnown, forKey: .autoAcceptKnown)
        if let bookmark = try? destination.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try c.encode(bookmark, forKey: .destinationBookmark)
        }
    }

    private static let key = "QSPreferences.v1"

    static func load() -> QSPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(QSPreferences.self, from: data) else {
            return QSPreferences()
        }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: QSPreferences.key)
        }
    }
}
