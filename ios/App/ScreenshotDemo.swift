#if DEBUG
import CryptoKit
import Foundation

/// App Store screenshots: launch a debug build with `-ScreenshotDemo` to fill in
/// two example Macs (on relay.example.com, so nothing is ever sent) and some
/// sample Recent items; add `-ScreenshotSettings` to open Settings on launch.
/// Debug builds only; none of this is in the App Store build.
enum ScreenshotDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo") }
    static var showSettings: Bool { ProcessInfo.processInfo.arguments.contains("-ScreenshotSettings") }

    @MainActor static func install(macs: Macs, log: SentLog) {
        func mac(_ name: String, _ inbox: String) -> Destination {
            Destination(name: name, server: URL(string: "https://relay.example.com")!, inbox: inbox,
                        sendToken: "screenshot", pub: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        }
        if macs.list.isEmpty {
            macs.add(mac("MacBook Pro", "screenshotmacbook0001"))
            macs.add(mac("Mac mini", "screenshotmacmini0001"))
        }
        Settings.deviceName = "iPhone"
        log.clear()
        let now = Date()
        let samples: [(String, String, TimeInterval, Bool)] = [
            ("file", "Lake Tahoe.HEIC", 40, true),
            ("text", "https://developer.apple.com/design/human-interface-guidelines", 180, true),
            ("file", "Q4 Budget.xlsx", 900, true),
            ("file", "Boarding Pass.pdf", 3_600, true),
            ("text", "Gate B14, boards at 6:35", 7_200, true),
            ("file", "Site Walkthrough.mov", 86_400, true),
        ]
        for (kind, title, ago, delivered) in samples.reversed() {
            var item = SentItem(kind: kind, title: title, to: "MacBook Pro", inbox: "screenshotmacbook0001")
            item.ts = now.addingTimeInterval(-ago)
            item.delivered = delivered ? item.ts.addingTimeInterval(4) : nil
            log.add(item)
        }
    }
}
#endif
