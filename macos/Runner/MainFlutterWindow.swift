import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Mirror of the Android com.nj.voxsynth/paths MethodChannel — see
    // lib/core/native_paths.dart. macOS app sandbox returns container
    // paths here so writes go to the app's private storage.
    let channel = FlutterMethodChannel(
      name: "com.nj.voxsynth/paths",
      binaryMessenger: flutterViewController.engine.binaryMessenger
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

    super.awakeFromNib()
  }
}
