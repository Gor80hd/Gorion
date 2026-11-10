import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The same binary doubles as the root privileged helper (launchd daemon).
  /// In that mode it must never show UI: no Dock icon, no window, and no
  /// terminate-on-last-window-close (there is no window at all).
  private var isPrivilegedHelper: Bool {
    ProcessInfo.processInfo.arguments.contains("--gorion-privileged-helper")
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    if isPrivilegedHelper {
      NSApp.setActivationPolicy(.accessory)
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if isPrivilegedHelper {
      for window in NSApp.windows {
        window.setIsVisible(false)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !isPrivilegedHelper
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
