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

struct AppSettings: Codable, Equatable {
    var isAutomationPaused: Bool
    var launchAtLogin: Bool
    var selectedLocation: String
    var templates: [ScheduleTemplate]
    var exclusions: [ExclusionRange]
    var history: [ClockAttempt]

    static var defaultSettings: AppSettings {
        AppSettings(
            isAutomationPaused: false,
            launchAtLogin: false,
            selectedLocation: "Oficina",
            templates: [.standardOffice],
            exclusions: [],
            history: []
        )
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
