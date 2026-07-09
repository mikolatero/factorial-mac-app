import SwiftUI

@main
struct FactorialMacApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()

    var body: some Scene {
        MenuBarExtra("Factorial Clock", systemImage: "clock") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.store)
                .environmentObject(appState.client)
                .environmentObject(appState.logStore)
                .environmentObject(softwareUpdateController)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.store)
                .environmentObject(appState.client)
                .environmentObject(appState.logStore)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
