import AppKit

let args = CommandLine.arguments.dropFirst()

if args.contains("--self-test") {
    SelfTest.run()
    exit(SelfTest.failed ? 1 : 0)
}

if args.contains("--screenshot") {
    Screenshot.run(args: Array(args))
    exit(0)
}

if args.contains("--receive-test") {
    let secs: Int
    if let i = args.firstIndex(of: "--receive-test"), i + 1 < args.count, let n = Int(args[i + 1]) {
        secs = n
    } else {
        secs = 60
    }
    ReceiveTest.run(seconds: secs)
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    QuickShare-Mac — Mac <> Android file transfer (Quick Share)

    Usage:
      QuickShare-Mac              Launch menu-bar app
      QuickShare-Mac --self-test  Run protocol unit tests
      QuickShare-Mac --receive-test [secs]  Advertise and log inbound connections
      QuickShare-Mac --help       This help
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
