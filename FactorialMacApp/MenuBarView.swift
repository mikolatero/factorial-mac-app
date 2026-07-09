import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var client: FactorialClockingClient
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    appState.manualClock(.clockIn)
                } label: {
                    Label("Fichar entrada", systemImage: "play.circle")
                }
                .disabled(appState.isClocking)

                Button {
                    appState.manualClock(.clockOut)
                } label: {
                    Label("Fichar salida", systemImage: "stop.circle")
                }
                .disabled(appState.isClocking)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label(nextEventText, systemImage: "calendar.badge.clock")
                    .font(.callout)
                Label(automationText, systemImage: store.settings.isAutomationPaused ? "pause.circle" : "bolt.circle")
                    .font(.callout)
                Label(authText, systemImage: authIcon)
                    .font(.callout)
            }
            .foregroundStyle(.secondary)

            Text(appState.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Button {
                softwareUpdateController.checkForUpdates()
            } label: {
                Label("Buscar actualizaciones...", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!softwareUpdateController.canCheckForUpdates)

            Divider()

            HStack {
                Button {
                    appState.toggleAutomationPaused()
                } label: {
                    Label(
                        store.settings.isAutomationPaused ? "Reanudar" : "Pausar",
                        systemImage: store.settings.isAutomationPaused ? "play.fill" : "pause.fill"
                    )
                }

                Spacer()

                Button {
                    openSettingsInFront()
                } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Salir", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task {
            await client.refreshAuthState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Factorial Clock")
                .font(.headline)
            Text(store.settings.selectedLocation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var nextEventText: String {
        guard let nextEvent = appState.nextEvent else {
            return "Sin fichajes programados"
        }

        return "\(nextEvent.kind.title): \(nextEvent.scheduledAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var automationText: String {
        store.settings.isAutomationPaused ? "Automatizacion pausada" : "Automatizacion activa"
    }

    private var authText: String {
        switch client.authState {
        case .unknown:
            "Sesion no comprobada"
        case .loginRequired:
            "Login requerido"
        case .authenticated:
            "Sesion iniciada"
        }
    }

    private var authIcon: String {
        switch client.authState {
        case .unknown:
            "questionmark.circle"
        case .loginRequired:
            "exclamationmark.triangle"
        case .authenticated:
            "checkmark.circle"
        }
    }

    private func openSettingsInFront() {
        openSettings()

        Task { @MainActor in
            SettingsWindowPresenter.bringToFront()
            try? await Task.sleep(for: .milliseconds(150))
            SettingsWindowPresenter.bringToFront()
        }
    }
}

@MainActor
private enum SettingsWindowPresenter {
    static func bringToFront() {
        let application = NSApplication.shared
        application.unhide(nil)
        application.activate(ignoringOtherApps: true)

        guard let window = settingsWindow(in: application.windows) else {
            return
        }

        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        let candidates = windows.filter { window in
            window.isVisible &&
                window.canBecomeKey &&
                !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return candidates.first { window in
            let title = window.title
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()

            return title.contains("ajustes") ||
                title.contains("settings") ||
                title.contains("general") ||
                title.contains("horarios") ||
                title.contains("ausencias") ||
                title.contains("login")
        } ?? candidates.first
    }
}
