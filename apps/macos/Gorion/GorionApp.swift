import AppKit
import GorionDesign
import GorionKit
import SwiftUI

@main
struct GorionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var ui = UIState()

    init() {
        // Ядро подключения — свой движок в Resources/gorion-engine.
        let engine = Bundle.main.url(forResource: "gorion-engine", withExtension: nil)
            ?? Bundle.main.bundleURL.appending(path: "Contents/Resources/gorion-engine")
        // GORION_DATA_DIR — отдельный каталог данных для проверок и скриншотов,
        // чтобы не трогать настоящие подписки.
        let dataDirectory = ProcessInfo.processInfo.environment["GORION_DATA_DIR"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? AppModel.defaultDataDirectory
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/gorion-helper")
        let model = AppModel(dataDirectory: dataDirectory, engineURL: engine, helperURL: helper)
        _model = State(initialValue: model)
        AppDelegate.model = model
        #if DEBUG
            // Снимок окна изнутри не рисует системное стекло (DebugSnapshot).
            if DebugSnapshot.path != nil { IslandRendering.forceSolid = true }
        #endif
    }

    var body: some Scene {
        Window("Gorion", id: "main") {
            RootView()
                .environment(model)
                .environment(ui)
                .tint(GColor.brandAccent.color)
                .preferredColorScheme(Self.forcedColorScheme)
                .frame(minWidth: GLayout.windowMinWidth, minHeight: GLayout.windowMinHeight)
                .onAppear {
                    model.start()
                    #if DEBUG
                        DebugSnapshot.scheduleIfRequested(model: model)
                    #endif
                }
        }
        .defaultSize(width: GLayout.windowDefaultWidth, height: GLayout.windowDefaultHeight)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { GorionCommands(model: model, ui: ui) }

        MenuBarExtra {
            StatusMenu().environment(model)
        } label: {
            Image(systemName: model.isConnected ? "shield.lefthalf.filled" : "shield")
                .accessibilityLabel("Gorion: \(Copy.stage(model.snapshot.stage))")
        }
    }
}

extension GorionApp {
    /// GORION_APPEARANCE=light|dark — тема окна для проверок и скриншотов,
    /// не трогая системную настройку.
    static var forcedColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["GORION_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// Состояние интерфейса, не относящееся к ядру (листы, поиск).
@Observable
@MainActor
final class UIState {
    var showingAddSubscription = false
    var searchFocusRequest = 0
    /// Страна, выбранная щелчком по планете: список серверов фильтруется по ней.
    var selectedCountry: String?
    /// Страна сервера под курсором в списке: подсвечивается на планете.
    var highlightedCountry: String?
}

struct GorionCommands: Commands {
    let model: AppModel
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(Copy.addSubscription + "…") { ui.showingAddSubscription = true }
                .keyboardShortcut("n")
        }
        CommandMenu("Подключение") {
            Button(Copy.connectButton(model.snapshot.stage)) { model.toggleConnection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.snapshot.activeProfileId == nil || model.snapshot.stage == .stopping)
            Button(Copy.measure) { model.measureDelays() }
                .keyboardShortcut("r")
                .disabled(model.snapshot.activeProfileId == nil || model.snapshot.measuringDelays)
            Button("Найти сервер") { ui.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Divider()
            // Для опытных: на главном экране режима нет — VPN для всего
            // компьютера по умолчанию (ADR-0005).
            Picker(Copy.modeMenu, selection: Binding(
                get: { model.snapshot.mode },
                set: { model.setMode($0) }
            )) {
                ForEach(Copy.modes, id: \.self) { mode in
                    Text(Copy.modeTitle(mode)).tag(mode)
                }
            }
            .disabled(model.isTransitioning || model.snapshot.busy)
        }
    }
}

struct StatusMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Button(Copy.connectButton(model.snapshot.stage)) { model.toggleConnection() }
            .disabled(model.snapshot.activeProfileId == nil || model.snapshot.stage == .stopping)
        Divider()
        Button(Copy.openWindow) {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button(Copy.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard model.isConnected, let server = model.activeServer else {
            return Copy.stage(model.snapshot.stage)
        }
        return "\(Copy.stage(.connected)) · \(server.name)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Подключение продолжает работать из строки меню.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // Ядро останавливается и возвращает системный прокси до выхода.
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
