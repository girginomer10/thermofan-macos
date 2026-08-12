import AppKit
import Darwin
import SwiftUI

@main
struct ThermoFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ThermalStore

    init() {
        CommandLineEntrypoint.runIfNeeded()
        _store = StateObject(wrappedValue: ThermalStore())
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPanelView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum AppWindowBridge {
    static var showSettings: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Honor the persisted Dock-icon preference instead of always hiding.
            if let store = AppStoreBridge.store {
                store.applyActivationPolicy()
            } else {
                NSApp.setActivationPolicy(.accessory)
            }

            AppWindowBridge.showSettings = { [weak self] in
                self?.showSettings()
            }

            if CommandLine.arguments.contains("--open-settings") {
                DispatchQueue.main.async {
                    self.showSettings()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Never leave a fan pinned under manual control with nothing watching
            // temperature once the app is gone.
            AppStoreBridge.store?.restoreAutomaticControlOnQuit()
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppWindowBridge.showSettings = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window === settingsWindowController?.window
        else { return }

        // A hidden NSHostingController keeps observing the rapidly changing
        // sensor store. Release the entire SwiftUI view graph when Settings
        // closes so its tab layout cannot continue consuming CPU off-screen.
        window.contentViewController = nil
        settingsWindowController = nil
    }

    private func showSettings() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store = AppStoreBridge.store else { return }

        let rootView = PreferencesView()
            .environmentObject(store)
            .frame(minWidth: 820, minHeight: 560)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "ThermoFan Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        window.isReleasedWhenClosed = true
        window.delegate = self
        settingsWindowController = NSWindowController(window: window)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
