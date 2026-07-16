import Foundation

struct ScheduledClockEvent: Equatable {
    var kind: ClockEventKind
    var scheduledAt: Date
    var templateID: UUID

    var eventKey: String {
        let components = Calendar.madrid.dateComponents([.year, .month, .day], from: scheduledAt)
        return String(
            format: "%04d-%02d-%02d-%@",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            kind.rawValue
        )
    }
}

enum AutomationScheduler {
    static let missedEventTolerance: TimeInterval = 5 * 60
    static let automaticRetryInterval: TimeInterval = 30
    static let recoveryLookbackDays = 31

    static func activeTemplate(in settings: AppSettings) -> ScheduleTemplate? {
        settings.templates.first(where: \.isActive)
    }

    static func isExcluded(_ date: Date, settings: AppSettings, calendar: Calendar = .madrid) -> Bool {
        settings.exclusions.contains { exclusion in
            exclusion.contains(date, calendar: calendar)
        }
    }

    static func nextEvent(
        after date: Date,
        settings: AppSettings,
        calendar: Calendar = .madrid
    ) -> ScheduledClockEvent? {
        guard !settings.isAutomationPaused,
              let template = activeTemplate(in: settings) else {
            return nil
        }

        let startDay = calendar.startOfDay(for: date)
        var candidates: [ScheduledClockEvent] = []

        for offset in 0..<recoveryLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                continue
            }

            candidates.append(
                contentsOf: scheduledEventsIfEnabled(
                    on: day,
                    template: template,
                    settings: settings,
                    calendar: calendar
                ).filter { $0.scheduledAt > date }
            )
        }

        return candidates.min { $0.scheduledAt < $1.scheduledAt }
    }

    /// Conserva las claves de los ultimos 31 dias (formato "yyyy-MM-dd-kind").
    /// Ese horizonte permite recuperar una salida tras fines de semana o ausencias
    /// sin que el registro persistido crezca sin limite.
    static func pruneEventKeys(
        _ keys: Set<String>,
        now: Date,
        calendar: Calendar = .madrid
    ) -> Set<String> {
        let validPrefixes = (0..<recoveryLookbackDays).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else {
                return nil
            }

            let components = calendar.dateComponents([.year, .month, .day], from: day)
            return String(
                format: "%04d-%02d-%02d-",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }

        return keys.filter { key in
            validPrefixes.contains { key.hasPrefix($0) }
        }
    }

    static func dueEvent(
        now: Date,
        settings: AppSettings,
        executedEventKeys: Set<String>,
        calendar: Calendar = .madrid
    ) -> ScheduledClockEvent? {
        guard !settings.isAutomationPaused,
              let template = activeTemplate(in: settings) else {
            return nil
        }

        var candidates = scheduledEventsIfEnabled(
            on: now,
            template: template,
            settings: settings,
            calendar: calendar
        )

        let startDay = calendar.startOfDay(for: now)
        for offset in 1..<recoveryLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startDay) else {
                continue
            }

            candidates.append(
                contentsOf: scheduledEventsIfEnabled(
                    on: day,
                    template: template,
                    settings: settings,
                    calendar: calendar
                ).filter { $0.kind == .clockOut }
            )
        }

        for event in candidates.sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
            let elapsed = now.timeIntervalSince(event.scheduledAt)
            guard elapsed >= 0,
                  !executedEventKeys.contains(event.eventKey),
                  canRecover(event, elapsed: elapsed, executedEventKeys: executedEventKeys) else {
                continue
            }

            let deadline = recoveryDeadline(
                for: event,
                settings: settings,
                calendar: calendar
            )

            if now < deadline {
                return event
            }
        }

        return nil
    }

    static func recoveryDeadline(
        for event: ScheduledClockEvent,
        settings: AppSettings,
        calendar: Calendar = .madrid
    ) -> Date {
        let minimumDeadline = event.scheduledAt.addingTimeInterval(missedEventTolerance)

        switch event.kind {
        case .clockIn:
            let configuredGrace = TimeInterval(
                settings.automationRecovery.clampedClockInGraceMinutes * 60
            )
            let graceDeadline = event.scheduledAt.addingTimeInterval(
                max(missedEventTolerance, configuredGrace)
            )

            guard let template = template(for: event, settings: settings),
                  let clockOut = scheduledEventsIfEnabled(
                    on: event.scheduledAt,
                    template: template,
                    settings: settings,
                    calendar: calendar
                  ).first(where: { $0.kind == .clockOut }) else {
                return graceDeadline
            }

            return min(graceDeadline, clockOut.scheduledAt)

        case .clockOut:
            if let nextClockIn = nextClockIn(
                after: event.scheduledAt,
                settings: settings,
                calendar: calendar
            ) {
                return nextClockIn.scheduledAt
            }

            return calendar.date(
                byAdding: .day,
                value: recoveryLookbackDays,
                to: event.scheduledAt
            ) ?? minimumDeadline
        }
    }

    private static func canRecover(
        _ event: ScheduledClockEvent,
        elapsed: TimeInterval,
        executedEventKeys: Set<String>
    ) -> Bool {
        guard event.kind == .clockOut,
              elapsed > missedEventTolerance else {
            return true
        }

        var matchingClockIn = event
        matchingClockIn.kind = .clockIn
        return executedEventKeys.contains(matchingClockIn.eventKey)
    }

    private static func nextClockIn(
        after date: Date,
        settings: AppSettings,
        calendar: Calendar
    ) -> ScheduledClockEvent? {
        guard let template = activeTemplate(in: settings) else {
            return nil
        }

        let startDay = calendar.startOfDay(for: date)
        for offset in 0..<recoveryLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                  let clockIn = scheduledEventsIfEnabled(
                    on: day,
                    template: template,
                    settings: settings,
                    calendar: calendar
                  ).first(where: { $0.kind == .clockIn && $0.scheduledAt > date }) else {
                continue
            }

            return clockIn
        }

        return nil
    }

    private static func template(
        for event: ScheduledClockEvent,
        settings: AppSettings
    ) -> ScheduleTemplate? {
        settings.templates.first(where: { $0.id == event.templateID }) ?? activeTemplate(in: settings)
    }

    private static func scheduledEventsIfEnabled(
        on day: Date,
        template: ScheduleTemplate,
        settings: AppSettings,
        calendar: Calendar
    ) -> [ScheduledClockEvent] {
        guard !isExcluded(day, settings: settings, calendar: calendar) else {
            return []
        }

        let weekday = calendar.component(.weekday, from: day)
        guard let schedule = template.workDays.first(where: { $0.weekday == weekday && $0.isEnabled }) else {
            return []
        }

        return scheduledEvents(
            on: day,
            schedule: schedule,
            template: template,
            settings: settings,
            calendar: calendar
        )
    }

    private static func scheduledEvents(
        on day: Date,
        schedule: WorkDaySchedule,
        template: ScheduleTemplate,
        settings: AppSettings,
        calendar: Calendar
    ) -> [ScheduledClockEvent] {
        guard let clockInDate = clockInDate(
            on: day,
            schedule: schedule,
            template: template,
            settings: settings,
            calendar: calendar
        ) else {
            return []
        }

        let configuredDurationMinutes = schedule.clockOut.minutesFromMidnight - schedule.clockIn.minutesFromMidnight
        let clockOutDate: Date?
        if settings.clockRandomization.isEnabled, configuredDurationMinutes > 0 {
            clockOutDate = calendar.date(
                byAdding: .minute,
                value: configuredDurationMinutes,
                to: clockInDate
            )
        } else {
            clockOutDate = schedule.clockOut.date(on: day, calendar: calendar)
        }

        var events = [
            ScheduledClockEvent(kind: .clockIn, scheduledAt: clockInDate, templateID: template.id)
        ]

        if let clockOutDate {
            events.append(
                ScheduledClockEvent(kind: .clockOut, scheduledAt: clockOutDate, templateID: template.id)
            )
        }

        return events
    }

    private static func clockInDate(
        on day: Date,
        schedule: WorkDaySchedule,
        template: ScheduleTemplate,
        settings: AppSettings,
        calendar: Calendar
    ) -> Date? {
        guard let scheduledClockInDate = schedule.clockIn.date(on: day, calendar: calendar),
              settings.clockRandomization.isEnabled else {
            return schedule.clockIn.date(on: day, calendar: calendar)
        }

        let offset = stableClockInOffsetMinutes(
            on: day,
            templateID: template.id,
            maxOffsetMinutes: settings.clockRandomization.clampedMaxClockInOffsetMinutes,
            calendar: calendar
        )

        return calendar.date(byAdding: .minute, value: offset, to: scheduledClockInDate)
    }

    private static func stableClockInOffsetMinutes(
        on day: Date,
        templateID: UUID,
        maxOffsetMinutes: Int,
        calendar: Calendar
    ) -> Int {
        guard maxOffsetMinutes > 0 else {
            return 0
        }

        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let seed = String(
            format: "%@-%04d-%02d-%02d",
            templateID.uuidString,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        let range = maxOffsetMinutes * 2 + 1

        return Int(stableHash(seed) % UInt64(range)) - maxOffsetMinutes
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        return hash
    }
}

struct AutomationRetryThrottle: Equatable {
    private(set) var eventKey: String?
    private(set) var retryNotBefore: Date?

    func allowsAttempt(for event: ScheduledClockEvent, now: Date) -> Bool {
        guard eventKey == event.eventKey,
              let retryNotBefore else {
            return true
        }

        return now >= retryNotBefore
    }

    mutating func recordFailure(for event: ScheduledClockEvent, now: Date) {
        eventKey = event.eventKey
        retryNotBefore = now.addingTimeInterval(AutomationScheduler.automaticRetryInterval)
    }

    mutating func clear(for event: ScheduledClockEvent? = nil) {
        if let event, eventKey != event.eventKey {
            return
        }

        eventKey = nil
        retryNotBefore = nil
    }
}
