import Foundation

enum ReceiveTest {
    static func run(seconds: Int) {
        NearbyConnectionManager.shared.becomeVisible()
        print("receiving: advertising _FC9F5ED42C8A._tcp")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: TimeInterval(seconds)))
        NearbyConnectionManager.shared.stopVisible()
        print("receive test done")
    }
}
