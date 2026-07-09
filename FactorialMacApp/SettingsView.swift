import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var client: FactorialClockingClient
    @EnvironmentObject private var logStore: AppLogStore
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController

    @State private var exclusionTitle = "Vacaciones"
    @State private var exclusionStart = Date()
    @State private var exclusionEnd = Date()
    @State private var selectedLogLevel = "all"
    @State private var logSearchText = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            scheduleTab
                .tabItem {
                    Label("Horarios", systemImage: "calendar")
                }

            exclusionsTab
                .tabItem {
                    Label("Ausencias", systemImage: "sun.max")
                }

            networkTab
                .tabItem {
                    Label("Red", systemImage: "network")
                }

            loginTab
                .tabItem {
                    Label("Login", systemImage: "lock")
                }

            logsTab
                .tabItem {
                    Label("Logs", systemImage: "terminal")
                }
        }
        .padding()
        .onAppear {
            store.settings.launchAtLogin = LoginItemController.isEnabled
        }
    }

    private var generalTab: some View {
        Form {
            Section("Automatizacion") {
                Toggle(
                    "Activar fichajes automaticos",
                    isOn: automationEnabledBinding
                )

                Toggle(
                    "Abrir al iniciar sesion",
                    isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )

                TextField("Lugar de trabajo", text: binding(\.selectedLocation))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Entrada aleatoria") {
                Toggle(
                    "Activar entrada aleatoria",
                    isOn: binding(\.clockRandomization.isEnabled)
                )

                LabeledContent("Rango") {
                    HStack(spacing: 8) {
                        Text("+/-")
                            .foregroundStyle(.secondary)

                        TextField(
                            "Min",
                            value: clockInOffsetMinutesBinding,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 56)

                        Text("min")
                            .foregroundStyle(.secondary)

                        Stepper(
                            "Rango",
                            value: clockInOffsetMinutesBinding,
                            in: 0...60,
                            step: 1
                        )
                        .labelsHidden()
                    }
                }
                .disabled(!store.settings.clockRandomization.isEnabled)
            }

            Section("Estado") {
                LabeledContent("Proximo fichaje", value: nextEventText)
                LabeledContent("Sesion Factorial", value: authStateText)
                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)
            }

            Section("Actualizaciones") {
                Button {
                    softwareUpdateController.checkForUpdates()
                } label: {
                    Label("Buscar actualizaciones...", systemImage: "arrow.down.circle")
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)

                LabeledContent("Comprobacion automatica", value: "Diaria")
                LabeledContent("Instalacion", value: "Con confirmacion")
            }

            Section("Historial") {
                if store.settings.history.isEmpty {
                    Text("Todavia no hay intentos registrados.")
                        .foregroundStyle(.secondary)
                } else {
                    List(store.settings.history.prefix(10)) { attempt in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(attempt.kind.title)
                                    .font(.headline)
                                Spacer()
                                Text(statusText(attempt.status))
                                    .foregroundStyle(statusColor(attempt.status))
                            }
                            Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(attempt.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var networkTab: some View {
        Form {
            Section("Proxy HTTP") {
                Toggle(
                    "Usar proxy HTTP",
                    isOn: binding(\.httpProxy.isEnabled)
                )

                TextField("URL del proxy", text: binding(\.httpProxy.url))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!store.settings.httpProxy.isEnabled)

                LabeledContent("Estado", value: store.settings.httpProxy.statusText)
            }

            Section("Resolvedor local") {
                Toggle(
                    "Usar FlareSolverr o TRAWL",
                    isOn: binding(\.challengeSolver.isEnabled)
                )

                Picker("API", selection: binding(\.challengeSolver.api)) {
                    ForEach(ChallengeSolverAPI.allCases) { api in
                        Text(api.title).tag(api)
                    }
                }
                .disabled(!store.settings.challengeSolver.isEnabled)

                TextField("URL base", text: binding(\.challengeSolver.baseURL))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!store.settings.challengeSolver.isEnabled)

                Stepper(
                    value: binding(\.challengeSolver.maxTimeoutMilliseconds),
                    in: 5_000...180_000,
                    step: 5_000
                ) {
                    LabeledContent(
                        "Timeout",
                        value: "\(store.settings.challengeSolver.clampedMaxTimeoutMilliseconds / 1000) s"
                    )
                }
                .disabled(!store.settings.challengeSolver.isEnabled)

                LabeledContent("Estado", value: store.settings.challengeSolver.statusText)

                Button {
                    appState.openLogin()
                } label: {
                    Label("Recargar login", systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Plantilla activa", selection: activeTemplateID) {
                    ForEach(store.settings.templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .frame(maxWidth: 360)

                Button {
                    addTemplate()
                } label: {
                    Label("Nueva", systemImage: "plus")
                }

                Button {
                    removeActiveTemplate()
                } label: {
                    Label("Eliminar", systemImage: "trash")
                }
                .disabled(store.settings.templates.count <= 1)
            }

            if let template = activeTemplate {
                TextField(
                    "Nombre de plantilla",
                    text: templateNameBinding(template.id)
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

                List {
                    ForEach(template.workDays) { day in
                        WorkDayRow(
                            dayName: weekdayName(day.weekday),
                            schedule: workDayBinding(templateID: template.id, dayID: day.id)
                        )
                    }
                }
            } else {
                ContentUnavailableView("Sin plantillas", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .padding()
    }

    private var exclusionsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nueva ausencia")
                    .font(.headline)

                HStack(alignment: .bottom, spacing: 14) {
                    LabeledAbsenceField(title: "Nombre") {
                        TextField("Nombre", text: $exclusionTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240)
                    }

                    LabeledAbsenceField(title: "Inicio", alignment: .center) {
                        DatePicker("", selection: $exclusionStart, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .fixedSize()
                    }
                    .frame(width: 128)

                    LabeledAbsenceField(title: "Fin", alignment: .center) {
                        DatePicker("", selection: $exclusionEnd, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .fixedSize()
                    }
                    .frame(width: 128)

                    Button {
                        addExclusion()
                    } label: {
                        Label("Añadir ausencia", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Ausencias guardadas")
                        .font(.headline)

                    Spacer()

                    Text("\(store.settings.exclusions.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }

                Divider()

                if store.settings.exclusions.isEmpty {
                    ContentUnavailableView("Sin ausencias guardadas", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.settings.exclusions) { exclusion in
                                AbsenceRow(
                                    title: exclusion.title,
                                    dateRange: exclusionDateRangeText(exclusion),
                                    onRemove: {
                                        removeExclusion(exclusion.id)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Nivel", selection: $selectedLogLevel) {
                    Text("Todos").tag("all")
                    ForEach(AppLogLevel.allCases) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)

                TextField("Filtrar", text: $logSearchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    copyLogs()
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .disabled(logStore.entries.isEmpty)

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Label("Limpiar", systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)
            }

            if filteredLogEntries.isEmpty {
                ContentUnavailableView("Sin logs", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredLogEntries) { entry in
                    LogEntryRow(entry: entry)
                }
            }
        }
        .padding()
    }

    private var loginTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    appState.openLogin()
                } label: {
                    Label("Abrir dashboard", systemImage: "safari")
                }

                Button {
                    appState.refreshDashboard()
                } label: {
                    Label("Refrescar", systemImage: "arrow.clockwise")
                }

                Button {
                    NSWorkspace.shared.open(URL(string: "https://app.factorialhr.com")!)
                } label: {
                    Label("Abrir en navegador", systemImage: "arrow.up.forward.app")
                }

                Spacer()

                Text(authStateText)
                    .foregroundStyle(client.authState == .authenticated ? .green : .secondary)
            }

            Text("Inicia sesion aqui con tu MFA. La app reutiliza la sesion de WebKit y no guarda tu contrasena.")
                .foregroundStyle(.secondary)

            WebLoginView(webView: client.webView)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator)
                }
        }
        .padding()
    }

    private var activeTemplate: ScheduleTemplate? {
        store.settings.templates.first(where: \.isActive) ?? store.settings.templates.first
    }

    private var activeTemplateID: Binding<UUID> {
        Binding(
            get: { activeTemplate?.id ?? UUID() },
            set: { selectedID in
                for index in store.settings.templates.indices {
                    store.settings.templates[index].isActive = store.settings.templates[index].id == selectedID
                }
                appState.tick()
            }
        )
    }

    private var nextEventText: String {
        guard let nextEvent = appState.nextEvent else {
            return "Sin programar"
        }

        return "\(nextEvent.kind.title) \(nextEvent.scheduledAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var authStateText: String {
        switch client.authState {
        case .unknown:
            "No comprobada"
        case .loginRequired:
            "Login requerido"
        case .authenticated:
            "Sesion iniciada"
        }
    }

    private var filteredLogEntries: [AppLogEntry] {
        logStore.entries.filter { entry in
            let matchesLevel = selectedLogLevel == "all" || entry.level.rawValue == selectedLogLevel
            let query = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesQuery = query.isEmpty ||
                entry.message.lowercased().contains(query) ||
                entry.source.lowercased().contains(query) ||
                entry.level.title.lowercased().contains(query)

            return matchesLevel && matchesQuery
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                appState.settingsDidChange()
            }
        )
    }

    private var automationEnabledBinding: Binding<Bool> {
        Binding(
            get: { !store.settings.isAutomationPaused },
            set: { enabled in
                store.settings.isAutomationPaused = !enabled
                appState.settingsDidChange()
            }
        )
    }

    private var clockInOffsetMinutesBinding: Binding<Int> {
        Binding(
            get: { store.settings.clockRandomization.clampedMaxClockInOffsetMinutes },
            set: { minutes in
                store.settings.clockRandomization.maxClockInOffsetMinutes = min(max(minutes, 0), 60)
                appState.settingsDidChange()
            }
        )
    }

    private func templateNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                store.settings.templates.first(where: { $0.id == id })?.name ?? ""
            },
            set: { name in
                guard let index = store.settings.templates.firstIndex(where: { $0.id == id }) else {
                    return
                }
                store.settings.templates[index].name = name
            }
        )
    }

    private func workDayBinding(templateID: UUID, dayID: UUID) -> Binding<WorkDaySchedule> {
        Binding(
            get: {
                guard let templateIndex = store.settings.templates.firstIndex(where: { $0.id == templateID }),
                      let dayIndex = store.settings.templates[templateIndex].workDays.firstIndex(where: { $0.id == dayID }) else {
                    return WorkDaySchedule(
                        weekday: 2,
                        isEnabled: false,
                        clockIn: TimeOfDay(hour: 9, minute: 0),
                        clockOut: TimeOfDay(hour: 18, minute: 0)
                    )
                }

                return store.settings.templates[templateIndex].workDays[dayIndex]
            },
            set: { updatedDay in
                guard let templateIndex = store.settings.templates.firstIndex(where: { $0.id == templateID }),
                      let dayIndex = store.settings.templates[templateIndex].workDays.firstIndex(where: { $0.id == dayID }) else {
                    return
                }

                store.settings.templates[templateIndex].workDays[dayIndex] = updatedDay
                appState.tick()
            }
        )
    }

    private func addTemplate() {
        for index in store.settings.templates.indices {
            store.settings.templates[index].isActive = false
        }

        var template = ScheduleTemplate.standardOffice
        template.name = "Nueva plantilla"
        template.isActive = true
        store.settings.templates.append(template)
        appState.tick()
    }

    private func removeActiveTemplate() {
        guard store.settings.templates.count > 1,
              let id = activeTemplate?.id else {
            return
        }

        store.settings.templates.removeAll { $0.id == id }
        store.settings.templates[0].isActive = true
        appState.tick()
    }

    private func addExclusion() {
        let start = min(exclusionStart, exclusionEnd)
        let end = max(exclusionStart, exclusionEnd)
        store.settings.exclusions.append(
            ExclusionRange(
                title: exclusionTitle.isEmpty ? "Ausencia" : exclusionTitle,
                startDate: start,
                endDate: end
            )
        )
        appState.tick()
    }

    private func removeExclusion(_ id: UUID) {
        store.settings.exclusions.removeAll { $0.id == id }
        appState.tick()
    }

    private func exclusionDateRangeText(_ exclusion: ExclusionRange) -> String {
        "\(exclusion.startDate.formatted(date: .abbreviated, time: .omitted)) - \(exclusion.endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logStore.plainText, forType: .string)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.madrid.weekdaySymbols
        return symbols[max(0, min(weekday - 1, symbols.count - 1))].capitalized
    }

    private func statusText(_ status: ClockAttemptStatus) -> String {
        switch status {
        case .success:
            "OK"
        case .skipped:
            "Omitido"
        case .failed:
            "Error"
        }
    }

    private func statusColor(_ status: ClockAttemptStatus) -> Color {
        switch status {
        case .success:
            .green
        case .skipped:
            .orange
        case .failed:
            .red
        }
    }
}

private struct LogEntryRow: View {
    let entry: AppLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(entry.level.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                    .frame(width: 58, alignment: .leading)

                Text(entry.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(entry.message.isEmpty ? "(sin mensaje)" : entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:
            .secondary
        case .info:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

private struct LabeledAbsenceField<Content: View>: View {
    let title: String
    let alignment: HorizontalAlignment
    @ViewBuilder var content: Content

    init(
        title: String,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
    }
}

private struct AbsenceRow: View {
    let title: String
    let dateRange: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                Text(dateRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55))
        }
    }
}

private struct WorkDayRow: View {
    let dayName: String
    @Binding var schedule: WorkDaySchedule

    var body: some View {
        HStack(spacing: 16) {
            Toggle(dayName, isOn: $schedule.isEnabled)
                .frame(width: 160, alignment: .leading)

            TimeOfDayEditor(title: "Entrada", time: $schedule.clockIn)
                .disabled(!schedule.isEnabled)

            TimeOfDayEditor(title: "Salida", time: $schedule.clockOut)
                .disabled(!schedule.isEnabled)
        }
        .padding(.vertical, 4)
    }
}

private struct TimeOfDayEditor: View {
    let title: String
    @Binding var time: TimeOfDay

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Stepper(value: $time.hour, in: 0...23) {
                Text(String(format: "%02d", time.hour))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            Stepper(value: $time.minute, in: 0...55, step: 5) {
                Text(String(format: "%02d", time.minute))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}
