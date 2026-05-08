import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Mirror of the Android com.nj.voxsynth/paths MethodChannel — see
    // lib/core/native_paths.dart. Keeps the Dart side on a single
    // platform-independent code path that doesn't depend on path_provider.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.nj.voxsynth/paths",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "getApplicationDocumentsPath":
          let path = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
          ).first ?? ""
          result(path)
        case "getApplicationSupportPath":
          let path = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
          ).first ?? ""
          result(path)
        case "getTemporaryPath":
          result(NSTemporaryDirectory())
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let runtimeChannel = FlutterMethodChannel(
        name: "com.nj.voxsynth/runtime",
        binaryMessenger: controller.binaryMessenger
      )
      runtimeChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "isIosSimulator":
          #if targetEnvironment(simulator)
          result(true)
          #else
          result(false)
          #endif
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
