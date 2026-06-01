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

        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                  !isExcluded(day, settings: settings, calendar: calendar) else {
                continue
            }

            let weekday = calendar.component(.weekday, from: day)
            guard let schedule = template.workDays.first(where: { $0.weekday == weekday && $0.isEnabled }) else {
                continue
            }

            if let clockInDate = schedule.clockIn.date(on: day, calendar: calendar), clockInDate > date {
                candidates.append(
                    ScheduledClockEvent(kind: .clockIn, scheduledAt: clockInDate, templateID: template.id)
                )
            }

            if let clockOutDate = schedule.clockOut.date(on: day, calendar: calendar), clockOutDate > date {
                candidates.append(
                    ScheduledClockEvent(kind: .clockOut, scheduledAt: clockOutDate, templateID: template.id)
                )
            }
        }

        return candidates.min { $0.scheduledAt < $1.scheduledAt }
    }

    static func dueEvent(
        now: Date,
        settings: AppSettings,
        executedEventKeys: Set<String>,
        calendar: Calendar = .madrid
    ) -> ScheduledClockEvent? {
        guard !settings.isAutomationPaused,
              let template = activeTemplate(in: settings),
              !isExcluded(now, settings: settings, calendar: calendar) else {
            return nil
        }

        let weekday = calendar.component(.weekday, from: now)
        guard let schedule = template.workDays.first(where: { $0.weekday == weekday && $0.isEnabled }) else {
            return nil
        }

        let candidates = [
            (ClockEventKind.clockIn, schedule.clockIn),
            (ClockEventKind.clockOut, schedule.clockOut)
        ]

        for candidate in candidates {
            guard let scheduledAt = candidate.1.date(on: now, calendar: calendar) else {
                continue
            }

            let event = ScheduledClockEvent(
                kind: candidate.0,
                scheduledAt: scheduledAt,
                templateID: template.id
            )
            let elapsed = now.timeIntervalSince(scheduledAt)

            if elapsed >= 0,
               elapsed <= missedEventTolerance,
               !executedEventKeys.contains(event.eventKey) {
                return event
            }
        }

        return nil
    }
}
