import Darwin
import Foundation

enum DeckLinkDiagnostics {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--list-decklink") else { return }

        let bridge = SPDeckLinkBridge()
        let devices = bridge.availableDevices()
        print("DeckLink runtime: \(bridge.runtimeStatus)")

        if devices.isEmpty {
            print("DeckLink devices: none")
        } else {
            print("DeckLink devices: \(devices.count)")
            for device in devices {
                print("- \(device.identifier): \(device.name)")
                for mode in device.modes {
                    let fps = mode.frameDuration > 0 ? Double(mode.timeScale) / Double(mode.frameDuration) : 0
                    print("  - \(mode.identifier): \(mode.name) \(mode.width)x\(mode.height) \(String(format: "%.2f", fps)) fps")
                }
            }
        }

        exit(0)
    }
}
