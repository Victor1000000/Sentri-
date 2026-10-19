import AppIntents
import Flutter
import UIKit

/// iOS does not let apps see the power or volume buttons, run a background shake detector, or show
/// a floating button. What it does offer is an App Intent, which the user can bind to the Action
/// Button (iPhone 15 Pro and later), Back Tap, a Lock Screen / Control Center control, Siri, or a
/// Shortcuts widget. Running the intent opens Sentri straight to the cancel countdown.

/// Holds a trigger until Dart is ready to take it.
final class SentriTrigger {
    static let shared = SentriTrigger()
    var pending: String?
    var onTrigger: ((String) -> Void)?

    func fire(_ type: String) {
        if let handler = onTrigger {
            handler(type)
        } else {
            pending = type
        }
    }
}

@available(iOS 16.0, *)
struct SendSentriAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Sentri alert"
    static var description = IntentDescription("Starts a Sentri emergency alert with a 5-second cancel window.")
    // Opening the app is what shows the cancel screen.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SentriTrigger.shared.fire("widget")
        return .result()
    }
}

@available(iOS 16.4, *)
struct SentriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendSentriAlertIntent(),
            phrases: ["Send an alert with \(.applicationName)", "\(.applicationName) emergency"],
            shortTitle: "Send alert",
            systemImageName: "exclamationmark.shield.fill"
        )
    }
}

/// Call once from AppDelegate after the Flutter engine exists:
///     registerSentriChannel(messenger: engineBridge or controller.binaryMessenger)
func registerSentriChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ng.sentri/native", binaryMessenger: messenger)
    SentriTrigger.shared.onTrigger = nil

    channel.setMethodCallHandler { call, result in
        switch call.method {
        case "takePendingTrigger":
            // Dart is up: from now on deliver triggers directly.
            SentriTrigger.shared.onTrigger = { type in channel.invokeMethod("onTrigger", arguments: type) }
            let p = SentriTrigger.shared.pending
            SentriTrigger.shared.pending = nil
            result(p)
        case "startProtection", "stopProtection":
            result(nil) // nothing to run in the background on iOS
        case "permissions":
            result(["overlay": false, "accessibility": false, "battery": true])
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
