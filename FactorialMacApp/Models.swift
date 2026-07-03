import Foundation

enum ClockEventKind: String, Codable, CaseIterable, Identifiable {
    case clockIn
    case clockOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clockIn:
            "Entrada"
        case .clockOut:
            "Salida"
        }
    }
}

enum ClockAttemptStatus: String, Codable {
    case success
    case skipped
    case failed
}

struct TimeOfDay: Codable, Equatable, Comparable, Hashable {
    var hour: Int
    var minute: Int

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }

    var minutesFromMidnight: Int {
        hour * 60 + minute
    }

    var label: String {
        String(format: "%02d:%02d", hour, minute)
    }

    func date(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: day
        )
    }
}

struct WorkDaySchedule: Codable, Identifiable, Equatable {
    var id: UUID
    var weekday: Int
    var isEnabled: Bool
    var clockIn: TimeOfDay
    var clockOut: TimeOfDay

    init(
        id: UUID = UUID(),
        weekday: Int,
        isEnabled: Bool,
        clockIn: TimeOfDay,
        clockOut: TimeOfDay
    ) {
        self.id = id
        self.weekday = weekday
        self.isEnabled = isEnabled
        self.clockIn = clockIn
        self.clockOut = clockOut
    }
}

struct ScheduleTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isActive: Bool
    var workDays: [WorkDaySchedule]

    init(
        id: UUID = UUID(),
        name: String,
        isActive: Bool,
        workDays: [WorkDaySchedule]
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.workDays = workDays
    }
}

struct ExclusionRange: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var startDate: Date
    var endDate: Date

    init(id: UUID = UUID(), title: String, startDate: Date, endDate: Date) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return day >= start && day <= end
    }
}

struct ClockAttempt: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var kind: ClockEventKind
    var status: ClockAttemptStatus
    var message: String

    init(
        id: UUID = UUID(),
        date: Date,
        kind: ClockEventKind,
        status: ClockAttemptStatus,
        message: String
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.status = status
        self.message = message
    }
}

struct HTTPProxySettings: Codable, Equatable {
    var isEnabled: Bool
    var url: String

    static var defaultSettings: HTTPProxySettings {
        HTTPProxySettings(
            isEnabled: false,
            url: "http://127.0.0.1:8080"
        )
    }

    var hostPort: (host: String, port: UInt16)? {
        guard isEnabled else {
            return nil
        }

        let rawURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            return nil
        }

        let normalizedURL = rawURL.contains("://") ? rawURL : "http://\(rawURL)"
        guard let components = URLComponents(string: normalizedURL),
              components.scheme?.lowercased() == "http",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        let port = components.port ?? 8080
        guard (1...65_535).contains(port) else {
            return nil
        }

        return (host, UInt16(port))
    }

    var statusText: String {
        guard isEnabled else {
            return "Desactivado"
        }

        guard let hostPort else {
            return "Configuracion incompleta"
        }

        return "Activo en \(hostPort.host):\(hostPort.port)"
    }
}

enum ChallengeSolverAPI: String, Codable, CaseIterable, Identifiable {
    case flareSolverrV1
    case trawlScrape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flareSolverrV1:
            "FlareSolverr /v1"
        case .trawlScrape:
            "TRAWL /scrape"
        }
    }

    var path: String {
        switch self {
        case .flareSolverrV1:
            "/v1"
        case .trawlScrape:
            "/scrape"
        }
    }
}

struct ChallengeSolverSettings: Codable, Equatable {
    var isEnabled: Bool
    var api: ChallengeSolverAPI
    var baseURL: String
    var maxTimeoutMilliseconds: Int

    static var defaultSettings: ChallengeSolverSettings {
        ChallengeSolverSettings(
            isEnabled: false,
            api: .flareSolverrV1,
            baseURL: "http://127.0.0.1:8191",
            maxTimeoutMilliseconds: 60_000
        )
    }

    var endpointURL: URL? {
        guard isEnabled else {
            return nil
        }

        let rawURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            return nil
        }

        let normalizedURL = rawURL.contains("://") ? rawURL : "http://\(rawURL)"
        guard var components = URLComponents(string: normalizedURL),
              components.scheme?.lowercased().hasPrefix("http") == true,
              components.host?.isEmpty == false else {
            return nil
        }

        let currentPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if currentPath.isEmpty {
            components.path = api.path
        }

        return components.url
    }

    var clampedMaxTimeoutMilliseconds: Int {
        min(max(maxTimeoutMilliseconds, 5_000), 180_000)
    }

    var statusText: String {
        guard isEnabled else {
            return "Desactivado"
        }

        guard let endpointURL else {
            return "Configuracion incompleta"
        }

        return "Activo en \(endpointURL.absoluteString)"
    }
}

struct ClockRandomizationSettings: Codable, Equatable {
    var isEnabled: Bool
    var maxClockInOffsetMinutes: Int

    static var defaultSettings: ClockRandomizationSettings {
        ClockRandomizationSettings(
            isEnabled: false,
            maxClockInOffsetMinutes: 5
        )
    }

    var clampedMaxClockInOffsetMinutes: Int {
        min(max(maxClockInOffsetMinutes, 0), 60)
    }

    var statusText: String {
        guard isEnabled else {
            return "Desactivado"
        }

        return "+/- \(clampedMaxClockInOffsetMinutes) min"
    }
}

struct AppSettings: Codable, Equatable {
    var isAutomationPaused: Bool
    var launchAtLogin: Bool
    var selectedLocation: String
    var templates: [ScheduleTemplate]
    var exclusions: [ExclusionRange]
    var history: [ClockAttempt]
    var httpProxy: HTTPProxySettings
    var challengeSolver: ChallengeSolverSettings
    var clockRandomization: ClockRandomizationSettings

    init(
        isAutomationPaused: Bool,
        launchAtLogin: Bool,
        selectedLocation: String,
        templates: [ScheduleTemplate],
        exclusions: [ExclusionRange],
        history: [ClockAttempt],
        httpProxy: HTTPProxySettings = .defaultSettings,
        challengeSolver: ChallengeSolverSettings = .defaultSettings,
        clockRandomization: ClockRandomizationSettings = .defaultSettings
    ) {
        self.isAutomationPaused = isAutomationPaused
        self.launchAtLogin = launchAtLogin
        self.selectedLocation = selectedLocation
        self.templates = templates
        self.exclusions = exclusions
        self.history = history
        self.httpProxy = httpProxy
        self.challengeSolver = challengeSolver
        self.clockRandomization = clockRandomization
    }

    static var defaultSettings: AppSettings {
        AppSettings(
            isAutomationPaused: false,
            launchAtLogin: false,
            selectedLocation: "Oficina",
            templates: [.standardOffice],
            exclusions: [],
            history: [],
            httpProxy: .defaultSettings,
            challengeSolver: .defaultSettings,
            clockRandomization: .defaultSettings
        )
    }

    enum CodingKeys: String, CodingKey {
        case isAutomationPaused
        case launchAtLogin
        case selectedLocation
        case templates
        case exclusions
        case history
        case httpProxy
        case challengeSolver
        case clockRandomization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAutomationPaused = try container.decode(Bool.self, forKey: .isAutomationPaused)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        selectedLocation = try container.decode(String.self, forKey: .selectedLocation)
        templates = try container.decode([ScheduleTemplate].self, forKey: .templates)
        exclusions = try container.decode([ExclusionRange].self, forKey: .exclusions)
        history = try container.decode([ClockAttempt].self, forKey: .history)
        httpProxy = try container.decodeIfPresent(HTTPProxySettings.self, forKey: .httpProxy) ?? .defaultSettings
        challengeSolver = try container.decodeIfPresent(ChallengeSolverSettings.self, forKey: .challengeSolver) ?? .defaultSettings
        clockRandomization = try container.decodeIfPresent(ClockRandomizationSettings.self, forKey: .clockRandomization) ?? .defaultSettings
    }
}

extension ScheduleTemplate {
    static var standardOffice: ScheduleTemplate {
        ScheduleTemplate(
            name: "Oficina",
            isActive: true,
            workDays: (1...7).map { weekday in
                WorkDaySchedule(
                    weekday: weekday,
                    isEnabled: (2...6).contains(weekday),
                    clockIn: TimeOfDay(hour: 9, minute: 0),
                    clockOut: TimeOfDay(hour: 18, minute: 0)
                )
            }
        )
    }
}

extension Calendar {
    static var madrid: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "es_ES")
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        return calendar
    }
}
