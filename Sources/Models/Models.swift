import Foundation

struct QSPreferences {
    var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    var autoOffMinutes: Int = 15
}
