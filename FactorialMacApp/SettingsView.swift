import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var client: FactorialClockingClient

    @State private var exclusionTitle = "Vacaciones"
    @State private var exclusionStart = Date()
    @State private var exclusionEnd = Date()

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

            loginTab
                .tabItem {
                    Label("Login", systemImage: "lock")
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
                    "Pausar fichajes automaticos",
                    isOn: binding(\.isAutomationPaused)
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

            Section("Estado") {
                LabeledContent("Proximo fichaje", value: nextEventText)
                LabeledContent("Sesion Factorial", value: authStateText)
                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Nuevo bloqueo") {
                    TextField("Nombre", text: $exclusionTitle)
                    DatePicker("Inicio", selection: $exclusionStart, displayedComponents: .date)
                    DatePicker("Fin", selection: $exclusionEnd, displayedComponents: .date)
                    Button {
                        addExclusion()
                    } label: {
                        Label("Anadir rango", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)

            List {
                ForEach(store.settings.exclusions) { exclusion in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(exclusion.title)
                                .font(.headline)
                            Text("\(exclusion.startDate.formatted(date: .abbreviated, time: .omitted)) - \(exclusion.endDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            removeExclusion(exclusion.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
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
                    Label("Abrir Factorial", systemImage: "safari")
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

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                appState.tick()
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
