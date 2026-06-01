import SwiftUI

@main
struct FactorialMacApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Factorial Clock", systemImage: "clock") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.store)
                .environmentObject(appState.client)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.store)
                .environmentObject(appState.client)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
