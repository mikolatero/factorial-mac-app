import Foundation
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var nextEvent: ScheduledClockEvent?
    @Published var statusMessage = "Listo"
    @Published var isClocking = false

    let store: SettingsStore
    let client: FactorialClockingClient

    private let notifications: ClockNotificationCenter
    private var timer: Timer?
    private var executedEventKeys: Set<String> = []

    init(
        store: SettingsStore = SettingsStore(),
        client: FactorialClockingClient = FactorialClockingClient(),
        notifications: ClockNotificationCenter = ClockNotificationCenter()
    ) {
        self.store = store
        self.client = client
        self.notifications = notifications
        notifications.start()
        tick()
        startTimer()
    }

    func openLogin() {
        client.openLogin()
    }

    func toggleAutomationPaused() {
        store.settings.isAutomationPaused.toggle()
        tick()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            store.settings.launchAtLogin = enabled
            statusMessage = enabled ? "Inicio automatico activado" : "Inicio automatico desactivado"
        } catch {
            store.settings.launchAtLogin = LoginItemController.isEnabled
            statusMessage = "No se pudo cambiar el inicio automatico: \(error.localizedDescription)"
        }
    }

    func manualClock(_ kind: ClockEventKind) {
        Task {
            await performClock(kind, isAutomatic: false)
        }
    }

    func tick(now: Date = Date()) {
        recordMissedEventIfNeeded(now: now)

        if let event = AutomationScheduler.dueEvent(
            now: now,
            settings: store.settings,
            executedEventKeys: executedEventKeys
        ) {
            executedEventKeys.insert(event.eventKey)
            Task {
                await performClock(event.kind, isAutomatic: true)
            }
        }

        nextEvent = AutomationScheduler.nextEvent(after: now, settings: store.settings)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func performClock(_ kind: ClockEventKind, isAutomatic: Bool) async {
        guard !isClocking else {
            return
        }

        isClocking = true
        statusMessage = "\(kind.title) en curso..."

        do {
            switch kind {
            case .clockIn:
                try await client.clockIn(location: store.settings.selectedLocation)
            case .clockOut:
                try await client.clockOut(location: store.settings.selectedLocation)
            }

            let message = isAutomatic ? "Fichaje automatico completado" : "Fichaje manual completado"
            statusMessage = message
            await notifications.notifyClockSuccess(kind: kind, isAutomatic: isAutomatic)
            store.addHistory(
                ClockAttempt(
                    date: Date(),
                    kind: kind,
                    status: .success,
                    message: message
                )
            )
        } catch {
            statusMessage = error.localizedDescription
            await notifications.notifyClockFailure(
                kind: kind,
                isAutomatic: isAutomatic,
                message: error.localizedDescription
            )
            store.addHistory(
                ClockAttempt(
                    date: Date(),
                    kind: kind,
                    status: .failed,
                    message: error.localizedDescription
                )
            )
        }

        isClocking = false
        tick()
    }

    private func recordMissedEventIfNeeded(now: Date) {
        guard let nextEvent,
              now.timeIntervalSince(nextEvent.scheduledAt) > AutomationScheduler.missedEventTolerance,
              !executedEventKeys.contains(nextEvent.eventKey) else {
            return
        }

        executedEventKeys.insert(nextEvent.eventKey)
        store.addHistory(
            ClockAttempt(
                date: now,
                kind: nextEvent.kind,
                status: .skipped,
                message: "Omitido porque el Mac desperto tarde o no habia conexion a tiempo"
            )
        )
    }
}

@MainActor
final class ClockNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    func start() {
        center.delegate = self
    }

    func notifyClockSuccess(kind: ClockEventKind, isAutomatic: Bool) async {
        let title = kind == .clockIn ? "Entrada fichada" : "Salida fichada"
        let mode = isAutomatic ? "automatico" : "manual"
        let body = "\(kind.title) registrada correctamente con fichaje \(mode)."

        await send(title: title, body: body, interruptionLevel: .active)
    }

    func notifyClockFailure(kind: ClockEventKind, isAutomatic: Bool, message: String) async {
        let mode = isAutomatic ? "automatico" : "manual"
        let body = "No se pudo registrar \(kind.title.lowercased()) con fichaje \(mode): \(message)"

        await send(title: "Error al fichar", body: body, interruptionLevel: .timeSensitive)
    }

    private func requestAuthorization() async {
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                isAuthorized = true
                return
            }

            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            isAuthorized = false
        }
    }

    private func send(
        title: String,
        body: String,
        interruptionLevel: UNNotificationInterruptionLevel
    ) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel

        let request = UNNotificationRequest(
            identifier: "factorial-clock-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
