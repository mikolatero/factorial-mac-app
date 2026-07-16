import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var nextEvent: ScheduledClockEvent?
    @Published var statusMessage = "Listo"
    @Published var isClocking = false

    let store: SettingsStore
    let client: FactorialClockingClient
    let logStore: AppLogStore

    private let notifications: ClockNotificationCenter
    private var timer: Timer?
    private var dashboardRefreshTimer: Timer?
    private var systemResumeObservers: [NSObjectProtocol] = []
    private var resumeTickTask: Task<Void, Never>?
    private var executedEventKeys: Set<String>
    private var pendingAutomationFailure: PendingAutomationFailure?
    private var automationRetryThrottle = AutomationRetryThrottle()

    private struct PendingAutomationFailure {
        let event: ScheduledClockEvent
        var lastMessage: String
        var attemptCount: Int
    }

    init(
        store: SettingsStore = SettingsStore(),
        client: FactorialClockingClient = FactorialClockingClient(),
        logStore: AppLogStore = AppLogStore(),
        notifications: ClockNotificationCenter = ClockNotificationCenter()
    ) {
        self.store = store
        self.client = client
        self.logStore = logStore
        self.notifications = notifications
        executedEventKeys = Set(store.settings.executedAutomationEventKeys)
        client.attachLogStore(logStore)
        store.attachLogStore(logStore)
        notifications.attachLogStore(logStore)
        logStore.info("App iniciada")
        notifications.start()
        applyNetworkSettings()
        tick()
        startTimer()
        startDashboardRefreshTimer()
        startSystemResumeObservers()
    }

    func openLogin() {
        logStore.info("Solicitud de apertura del dashboard")
        client.openLogin()
    }

    func refreshDashboard() {
        logStore.info("Refresco manual del dashboard solicitado")
        client.refreshDashboardManually()
    }

    func toggleAutomationPaused() {
        store.settings.isAutomationPaused.toggle()
        logStore.info(
            store.settings.isAutomationPaused ? "Automatizacion pausada" : "Automatizacion reanudada"
        )
        tick()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            store.settings.launchAtLogin = enabled
            statusMessage = enabled ? "Inicio automatico activado" : "Inicio automatico desactivado"
            logStore.info(statusMessage)
        } catch {
            store.settings.launchAtLogin = LoginItemController.isEnabled
            statusMessage = "No se pudo cambiar el inicio automatico: \(error.localizedDescription)"
            logStore.error(statusMessage)
        }
    }

    func settingsDidChange() {
        logStore.debug("Ajustes actualizados")
        applyNetworkSettings()
        tick()
    }

    func manualClock(_ kind: ClockEventKind) {
        logStore.info("Fichaje manual solicitado: \(kind.title)")
        Task {
            await performClock(kind, isAutomatic: false)
        }
    }

    func tick(now: Date = Date()) {
        pruneExecutedEventKeys(now: now)
        recordMissedEventIfNeeded(now: now)
        finalizeExpiredAutomationFailure(now: now)

        if let event = AutomationScheduler.dueEvent(
            now: now,
            settings: store.settings,
            executedEventKeys: executedEventKeys
        ) {
            if client.authState == .loginRequired {
                registerLoginRequiredIfNeeded(event, now: now)
            } else if automationRetryThrottle.allowsAttempt(for: event, now: now) {
                Task {
                    await performClock(event.kind, isAutomatic: true, event: event)
                }
            }
        }

        nextEvent = AutomationScheduler.nextEvent(after: now, settings: store.settings)
    }

    private func applyNetworkSettings() {
        client.applyProxySettings(store.settings.httpProxy)
        client.applyChallengeSolverSettings(store.settings.challengeSolver)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func startDashboardRefreshTimer() {
        dashboardRefreshTimer?.invalidate()
        dashboardRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                // No recargar mientras el usuario puede estar completando el login/MFA.
                guard self.client.authState != .loginRequired else {
                    self.logStore.debug("Refresco horario omitido: hay un login pendiente", source: "WebKit")
                    return
                }

                self.logStore.info("Refresco automatico horario del dashboard")
                do {
                    try await self.client.refreshDashboardFromOrigin(reason: "Refresco automatico horario del dashboard")
                } catch {
                    self.logStore.warning("No se pudo refrescar el dashboard: \(error.localizedDescription)", source: "WebKit")
                }
            }
        }
    }

    private func startSystemResumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "Mac activo tras la suspension"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "Sesion de macOS desbloqueada")
        ]

        systemResumeObservers = notifications.map { name, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleResumeTick(reason: reason)
                }
            }
        }
    }

    private func scheduleResumeTick(reason: String) {
        resumeTickTask?.cancel()
        logStore.debug("\(reason): esperando a que la red este disponible")
        resumeTickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else {
                return
            }

            self.logStore.debug("Comprobando fichajes pendientes tras reactivar el sistema")
            self.tick()
        }
    }

    private func performClock(_ kind: ClockEventKind, isAutomatic: Bool, event: ScheduledClockEvent? = nil) async {
        guard !isClocking else {
            return
        }

        isClocking = true
        statusMessage = "\(kind.title) en curso..."
        logStore.info(statusMessage)

        do {
            switch kind {
            case .clockIn:
                try await client.clockIn(location: store.settings.selectedLocation)
            case .clockOut:
                try await client.clockOut(location: store.settings.selectedLocation)
            }

            let message = isAutomatic ? "Fichaje automatico completado" : "Fichaje manual completado"
            statusMessage = message
            logStore.info(message)
            await notifications.notifyClockSuccess(kind: kind, isAutomatic: isAutomatic)
            store.addHistory(
                ClockAttempt(
                    date: Date(),
                    kind: kind,
                    status: .success,
                    message: message
                )
            )
            markExecutedEvent(event?.eventKey)
            if let event, pendingAutomationFailure?.event == event {
                pendingAutomationFailure = nil
                automationRetryThrottle.clear(for: event)
            }
        } catch {
            statusMessage = error.localizedDescription
            logStore.error(error.localizedDescription, source: "Fichaje")

            if isAutomatic, let event {
                // No se marca como ejecutado: dueEvent lo volvera a devolver en los
                // siguientes ticks mientras dure la ventana de tolerancia. El throttle
                // impide que un fallo inmediato provoque un bucle de peticiones.
                registerAutomationFailure(event, message: error.localizedDescription, now: Date())
            } else {
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
        }

        isClocking = false
        tick()
    }

    private func registerAutomationFailure(_ event: ScheduledClockEvent, message: String, now: Date) {
        if var pending = pendingAutomationFailure, pending.event == event {
            pending.lastMessage = message
            pending.attemptCount += 1
            pendingAutomationFailure = pending
        } else {
            pendingAutomationFailure = PendingAutomationFailure(event: event, lastMessage: message, attemptCount: 1)
        }

        automationRetryThrottle.recordFailure(for: event, now: now)

        let attempts = pendingAutomationFailure?.attemptCount ?? 1
        if client.authState == .loginRequired {
            logStore.warning(
                "\(event.kind.title) automatica fallida (intento \(attempts)). No se reintentara hasta que la sesion vuelva a estar iniciada.",
                source: "Fichaje"
            )
        } else {
            logStore.warning(
                "\(event.kind.title) automatica fallida (intento \(attempts)). Se reintentara en \(Int(AutomationScheduler.automaticRetryInterval)) segundos.",
                source: "Fichaje"
            )
        }
    }

    private func registerLoginRequiredIfNeeded(_ event: ScheduledClockEvent, now: Date) {
        guard pendingAutomationFailure?.event != event else {
            return
        }

        let message = FactorialClockingError.notAuthenticated.localizedDescription
        pendingAutomationFailure = PendingAutomationFailure(
            event: event,
            lastMessage: message,
            attemptCount: 1
        )
        automationRetryThrottle.recordFailure(for: event, now: now)
        statusMessage = message
        logStore.warning(
            "\(event.kind.title) automatica pendiente: se requiere iniciar sesion en Factorial.",
            source: "Fichaje"
        )
    }

    private func finalizeExpiredAutomationFailure(now: Date) {
        guard let pending = pendingAutomationFailure,
              now >= AutomationScheduler.recoveryDeadline(
                for: pending.event,
                settings: store.settings
              ),
              !executedEventKeys.contains(pending.event.eventKey) else {
            return
        }

        pendingAutomationFailure = nil
        automationRetryThrottle.clear(for: pending.event)
        markExecutedEvent(pending.event.eventKey)

        let message = "No se pudo completar \(pending.event.kind.title.lowercased()) automatica tras \(pending.attemptCount) intento(s): \(pending.lastMessage)"
        statusMessage = message
        logStore.error(message, source: "Fichaje")
        store.addHistory(
            ClockAttempt(
                date: now,
                kind: pending.event.kind,
                status: .failed,
                message: message
            )
        )

        Task {
            await notifications.notifyClockFailure(
                kind: pending.event.kind,
                isAutomatic: true,
                message: pending.lastMessage
            )
        }
    }

    private func markExecutedEvent(_ eventKey: String?) {
        guard let eventKey else {
            return
        }

        executedEventKeys.insert(eventKey)
        persistExecutedEventKeys()
    }

    private func pruneExecutedEventKeys(now: Date) {
        let pruned = AutomationScheduler.pruneEventKeys(executedEventKeys, now: now)
        guard pruned != executedEventKeys else {
            return
        }

        executedEventKeys = pruned
        persistExecutedEventKeys()
    }

    private func persistExecutedEventKeys() {
        store.settings.executedAutomationEventKeys = executedEventKeys.sorted()
    }

    private func recordMissedEventIfNeeded(now: Date) {
        guard let nextEvent,
              now >= AutomationScheduler.recoveryDeadline(
                for: nextEvent,
                settings: store.settings
              ),
              !executedEventKeys.contains(nextEvent.eventKey) else {
            return
        }

        markExecutedEvent(nextEvent.eventKey)
        logStore.warning("Fichaje omitido: se supero el margen de recuperacion configurado")
        store.addHistory(
            ClockAttempt(
                date: now,
                kind: nextEvent.kind,
                status: .skipped,
                message: "Omitido porque se supero el margen de recuperacion configurado"
            )
        )
    }
}

@MainActor
final class ClockNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false
    private var didLogDeniedAuthorization = false
    private weak var logStore: AppLogStore?

    func start() {
        center.delegate = self
    }

    func attachLogStore(_ logStore: AppLogStore) {
        self.logStore = logStore
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
            logStore?.warning(
                "No se pudo solicitar permiso de notificaciones: \(error.localizedDescription)",
                source: "Notificaciones"
            )
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
                if !didLogDeniedAuthorization {
                    didLogDeniedAuthorization = true
                    logStore?.warning(
                        "Las notificaciones estan desactivadas para la app: no se mostraran avisos de fichaje.",
                        source: "Notificaciones"
                    )
                }
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

        do {
            try await center.add(request)
        } catch {
            logStore?.warning(
                "No se pudo mostrar la notificacion: \(error.localizedDescription)",
                source: "Notificaciones"
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
