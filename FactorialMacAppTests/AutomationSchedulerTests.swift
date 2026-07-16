import XCTest
@testable import FactorialMacApp

final class AutomationSchedulerTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = .madrid
    }

    func testNextEventUsesActiveTemplate() throws {
        let activeTemplate = ScheduleTemplate(
            name: "Tarde",
            isActive: true,
            workDays: [
                WorkDaySchedule(
                    weekday: 2,
                    isEnabled: true,
                    clockIn: TimeOfDay(hour: 12, minute: 0),
                    clockOut: TimeOfDay(hour: 20, minute: 0)
                )
            ]
        )
        let inactiveTemplate = ScheduleTemplate(
            name: "Manana",
            isActive: false,
            workDays: [
                WorkDaySchedule(
                    weekday: 2,
                    isEnabled: true,
                    clockIn: TimeOfDay(hour: 9, minute: 0),
                    clockOut: TimeOfDay(hour: 18, minute: 0)
                )
            ]
        )
        let settings = AppSettings(
            isAutomationPaused: false,
            launchAtLogin: false,
            selectedLocation: "Oficina",
            templates: [inactiveTemplate, activeTemplate],
            exclusions: [],
            history: []
        )

        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 30)
        let event = try XCTUnwrap(AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar))

        XCTAssertEqual(event.kind, .clockIn)
        XCTAssertEqual(calendar.component(.hour, from: event.scheduledAt), 12)
    }

    func testPausedAutomationHasNoNextEvent() throws {
        var settings = AppSettings.defaultSettings
        settings.isAutomationPaused = true

        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 30)

        XCTAssertNil(AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar))
    }

    func testExclusionSkipsBlockedDay() throws {
        var settings = AppSettings.defaultSettings
        let blockedDay = try date(year: 2026, month: 6, day: 1, hour: 0, minute: 0)
        settings.exclusions = [
            ExclusionRange(title: "Vacaciones", startDate: blockedDay, endDate: blockedDay)
        ]

        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 30)
        let event = try XCTUnwrap(AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar))

        XCTAssertEqual(calendar.component(.day, from: event.scheduledAt), 2)
        XCTAssertEqual(event.kind, .clockIn)
    }

    func testDueEventWithinToleranceRuns() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 3)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockIn)
    }

    func testDueEventAfterToleranceIsOmitted() throws {
        var settings = AppSettings.defaultSettings
        settings.automationRecovery.clockInGraceMinutes = 0
        let now = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 6)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertNil(event)
    }

    func testClockInRecoversWithinDefaultTwoHourMargin() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 10, minute: 59)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockIn)
    }

    func testClockInExpiresAtConfiguredDeadline() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 11, minute: 0)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertNil(event)
    }

    func testClockInRecoveryNeverPassesClockOut() throws {
        var settings = settingsWithSchedule(
            clockIn: TimeOfDay(hour: 9, minute: 0),
            clockOut: TimeOfDay(hour: 10, minute: 0)
        )
        settings.automationRecovery.clockInGraceMinutes = 120
        let now = try date(year: 2026, month: 6, day: 1, hour: 10, minute: 0)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
    }

    func testLateClockOutRecoversSameDayWhenClockInWasExecuted() throws {
        let settings = AppSettings.defaultSettings
        let morning = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let clockIn = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: morning,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        let evening = try date(year: 2026, month: 6, day: 1, hour: 20, minute: 0)

        let event = AutomationScheduler.dueEvent(
            now: evening,
            settings: settings,
            executedEventKeys: [clockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
        XCTAssertEqual(calendar.component(.day, from: event?.scheduledAt ?? evening), 1)
    }

    func testLateClockOutRecoversNextMorningBeforeClockIn() throws {
        let settings = AppSettings.defaultSettings
        let mondayMorning = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let mondayClockIn = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: mondayMorning,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        let tuesdayMorning = try date(year: 2026, month: 6, day: 2, hour: 8, minute: 30)

        let event = AutomationScheduler.dueEvent(
            now: tuesdayMorning,
            settings: settings,
            executedEventKeys: [mondayClockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
        XCTAssertEqual(calendar.component(.day, from: event?.scheduledAt ?? tuesdayMorning), 1)
    }

    func testLateClockOutRequiresRecordedClockIn() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 20, minute: 0)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertNil(event)
    }

    func testClockOutWithinBaseToleranceDoesNotRequireRecordedClockIn() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 18, minute: 3)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
    }

    func testPreviousClockOutExpiresWhenNextClockInStarts() throws {
        let settings = AppSettings.defaultSettings
        let mondayMorning = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let mondayClockIn = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: mondayMorning,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        let tuesdayClockInTime = try date(year: 2026, month: 6, day: 2, hour: 9, minute: 0)

        let event = AutomationScheduler.dueEvent(
            now: tuesdayClockInTime,
            settings: settings,
            executedEventKeys: [mondayClockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockIn)
        XCTAssertEqual(calendar.component(.day, from: event?.scheduledAt ?? tuesdayClockInTime), 2)
    }

    func testClockOutRecoverySpansWeekend() throws {
        let settings = AppSettings.defaultSettings
        let fridayMorning = try date(year: 2026, month: 6, day: 5, hour: 9, minute: 1)
        let fridayClockIn = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: fridayMorning,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        let mondayMorning = try date(year: 2026, month: 6, day: 8, hour: 8, minute: 30)

        let event = AutomationScheduler.dueEvent(
            now: mondayMorning,
            settings: settings,
            executedEventKeys: [fridayClockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
        XCTAssertEqual(calendar.component(.day, from: event?.scheduledAt ?? mondayMorning), 5)
    }

    func testClockOutRecoveryContinuesDuringExcludedDay() throws {
        var settings = AppSettings.defaultSettings
        let fridayMorning = try date(year: 2026, month: 6, day: 5, hour: 9, minute: 1)
        let fridayClockIn = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: fridayMorning,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        let monday = try date(year: 2026, month: 6, day: 8, hour: 8, minute: 30)
        settings.exclusions = [ExclusionRange(title: "Vacaciones", startDate: monday, endDate: monday)]

        let event = AutomationScheduler.dueEvent(
            now: monday,
            settings: settings,
            executedEventKeys: [fridayClockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(event?.kind, .clockOut)
    }

    func testAutomaticRetryThrottleBlocksImmediateRetry() throws {
        let settings = AppSettings.defaultSettings
        let failureDate = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let event = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: failureDate,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        var throttle = AutomationRetryThrottle()

        throttle.recordFailure(for: event, now: failureDate)

        XCTAssertFalse(throttle.allowsAttempt(for: event, now: failureDate))
        XCTAssertFalse(
            throttle.allowsAttempt(
                for: event,
                now: failureDate.addingTimeInterval(AutomationScheduler.automaticRetryInterval - 1)
            )
        )
        XCTAssertTrue(
            throttle.allowsAttempt(
                for: event,
                now: failureDate.addingTimeInterval(AutomationScheduler.automaticRetryInterval)
            )
        )
    }

    func testAutomaticRetryThrottleClearAllowsRetry() throws {
        let settings = AppSettings.defaultSettings
        let failureDate = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let event = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: failureDate,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )
        var throttle = AutomationRetryThrottle()
        throttle.recordFailure(for: event, now: failureDate)

        throttle.clear(for: event)

        XCTAssertTrue(throttle.allowsAttempt(for: event, now: failureDate))
    }

    func testExecutedEventDoesNotRunTwice() throws {
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 1)
        let firstEvent = try XCTUnwrap(
            AutomationScheduler.dueEvent(
                now: now,
                settings: settings,
                executedEventKeys: [],
                calendar: calendar
            )
        )

        let secondEvent = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [firstEvent.eventKey],
            calendar: calendar
        )

        XCTAssertNil(secondEvent)
    }

    func testRandomizedClockInIsStableWithinConfiguredRange() throws {
        let settings = randomizedSettings(maxOffsetMinutes: 5)
        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 0)
        let expectedClockIn = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 0)

        let firstEvent = try XCTUnwrap(AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar))
        let secondEvent = try XCTUnwrap(AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar))
        let offset = try XCTUnwrap(
            calendar.dateComponents([.minute], from: expectedClockIn, to: firstEvent.scheduledAt).minute
        )

        XCTAssertEqual(firstEvent.kind, .clockIn)
        XCTAssertEqual(firstEvent, secondEvent)
        XCTAssertTrue((-5...5).contains(offset))
    }

    func testRandomizedClockOutPreservesConfiguredDuration() throws {
        // El horario configurado es 9:00-18:00 (9 h): la salida aleatorizada debe
        // mantener esa duracion desde la entrada, no una jornada fija.
        let settings = randomizedSettings(maxOffsetMinutes: 5)
        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 0)
        let clockInEvent = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar)
        )
        let afterClockIn = try XCTUnwrap(
            calendar.date(byAdding: .second, value: 1, to: clockInEvent.scheduledAt)
        )

        let clockOutEvent = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: afterClockIn, settings: settings, calendar: calendar)
        )

        XCTAssertEqual(clockOutEvent.kind, .clockOut)
        XCTAssertEqual(clockOutEvent.scheduledAt.timeIntervalSince(clockInEvent.scheduledAt), 9 * 60 * 60)
    }

    func testPruneEventKeysKeepsLastThirtyOneDays() throws {
        let now = try date(year: 2026, month: 6, day: 30, hour: 9, minute: 0)
        let keys: Set<String> = [
            "2026-06-30-clockIn",
            "2026-06-15-clockOut",
            "2026-05-31-clockIn",
            "2026-05-30-clockOut"
        ]

        let pruned = AutomationScheduler.pruneEventKeys(keys, now: now, calendar: calendar)

        XCTAssertEqual(pruned, ["2026-06-30-clockIn", "2026-06-15-clockOut", "2026-05-31-clockIn"])
    }

    func testRandomizedDueEventRunsAtRandomizedClockIn() throws {
        let settings = randomizedSettings(maxOffsetMinutes: 5)
        let now = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 0)
        let clockInEvent = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: now, settings: settings, calendar: calendar)
        )
        let dueTime = try XCTUnwrap(
            calendar.date(byAdding: .minute, value: 1, to: clockInEvent.scheduledAt)
        )

        let dueEvent = AutomationScheduler.dueEvent(
            now: dueTime,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertEqual(dueEvent, clockInEvent)
    }

    func testRandomizedNextClockInEndsPreviousClockOutRecovery() throws {
        let settings = randomizedSettings(maxOffsetMinutes: 5)
        let beforeFirstClockIn = try date(year: 2026, month: 6, day: 1, hour: 8, minute: 0)
        let firstClockIn = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: beforeFirstClockIn, settings: settings, calendar: calendar)
        )
        let afterFirstClockIn = firstClockIn.scheduledAt.addingTimeInterval(1)
        let firstClockOut = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: afterFirstClockIn, settings: settings, calendar: calendar)
        )
        let nextClockIn = try XCTUnwrap(
            AutomationScheduler.nextEvent(after: firstClockOut.scheduledAt, settings: settings, calendar: calendar)
        )
        let beforeNextClockIn = nextClockIn.scheduledAt.addingTimeInterval(-1)

        let pendingClockOut = AutomationScheduler.dueEvent(
            now: beforeNextClockIn,
            settings: settings,
            executedEventKeys: [firstClockIn.eventKey],
            calendar: calendar
        )
        let eventAtNextClockIn = AutomationScheduler.dueEvent(
            now: nextClockIn.scheduledAt,
            settings: settings,
            executedEventKeys: [firstClockIn.eventKey],
            calendar: calendar
        )

        XCTAssertEqual(pendingClockOut, firstClockOut)
        XCTAssertEqual(eventAtNextClockIn, nextClockIn)
    }

    func testHTTPProxyParsesHostAndPort() throws {
        let proxy = HTTPProxySettings(
            isEnabled: true,
            url: "127.0.0.1:8081"
        )

        let hostPort = try XCTUnwrap(proxy.hostPort)

        XCTAssertEqual(hostPort.host, "127.0.0.1")
        XCTAssertEqual(hostPort.port, 8081)
    }

    func testHTTPProxyRejectsNonHTTPURL() {
        let proxy = HTTPProxySettings(
            isEnabled: true,
            url: "https://127.0.0.1:8081"
        )

        XCTAssertNil(proxy.hostPort)
    }

    func testSettingsDecodeDefaultsHTTPProxyForOlderPayloads() throws {
        let payload = """
        {
          "isAutomationPaused": false,
          "launchAtLogin": false,
          "selectedLocation": "Oficina",
          "templates": [],
          "exclusions": [],
          "history": []
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: payload)

        XCTAssertEqual(settings.httpProxy, .defaultSettings)
        XCTAssertEqual(settings.challengeSolver, .defaultSettings)
        XCTAssertEqual(settings.clockRandomization, .defaultSettings)
        XCTAssertEqual(settings.automationRecovery, .defaultSettings)
        XCTAssertEqual(settings.executedAutomationEventKeys, [])
    }

    func testSettingsDecodePartialPayloadKeepsPresentFields() throws {
        // Un blob con claves ausentes no debe invalidar toda la decodificacion:
        // los campos presentes se conservan y el resto toma sus valores por defecto.
        let payload = """
        {
          "selectedLocation": "Remoto",
          "isAutomationPaused": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: payload)

        XCTAssertEqual(settings.selectedLocation, "Remoto")
        XCTAssertTrue(settings.isAutomationPaused)
        XCTAssertEqual(settings.templates.count, 1)
        XCTAssertEqual(settings.templates.first?.name, "Oficina")
        XCTAssertEqual(settings.exclusions, [])
        XCTAssertEqual(settings.history, [])
        XCTAssertEqual(settings.httpProxy, .defaultSettings)
        XCTAssertEqual(settings.automationRecovery.clockInGraceMinutes, 120)
    }

    func testSettingsRoundTripPersistsExecutedAutomationEventKeys() throws {
        var settings = AppSettings.defaultSettings
        settings.executedAutomationEventKeys = ["2026-06-01-clockIn", "2026-06-01-clockOut"]

        let data = try JSONEncoder.settingsEncoder.encode(settings)
        let decoded = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.executedAutomationEventKeys, ["2026-06-01-clockIn", "2026-06-01-clockOut"])
    }

    func testSettingsRoundTripPersistsAutomationRecoveryMargin() throws {
        var settings = AppSettings.defaultSettings
        settings.automationRecovery.clockInGraceMinutes = 180

        let data = try JSONEncoder.settingsEncoder.encode(settings)
        let decoded = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.automationRecovery.clockInGraceMinutes, 180)
    }

    func testAutomationRecoveryMarginIsClamped() {
        XCTAssertEqual(AutomationRecoverySettings(clockInGraceMinutes: -15).clampedClockInGraceMinutes, 0)
        XCTAssertEqual(AutomationRecoverySettings(clockInGraceMinutes: 900).clampedClockInGraceMinutes, 720)
    }

    func testChallengeSolverDefaultsToFlareSolverrEndpoint() throws {
        let solver = ChallengeSolverSettings(
            isEnabled: true,
            api: .flareSolverrV1,
            baseURL: "http://127.0.0.1:8191",
            maxTimeoutMilliseconds: 60_000
        )

        XCTAssertEqual(solver.endpointURL?.absoluteString, "http://127.0.0.1:8191/v1")
    }

    func testChallengeSolverKeepsExplicitTrawlScrapePath() throws {
        let solver = ChallengeSolverSettings(
            isEnabled: true,
            api: .trawlScrape,
            baseURL: "http://localhost:8191/scrape",
            maxTimeoutMilliseconds: 60_000
        )

        XCTAssertEqual(solver.endpointURL?.absoluteString, "http://localhost:8191/scrape")
    }

    func testChallengeSolverKeepsPrivateNetworkHTTP() throws {
        let solver = ChallengeSolverSettings(
            isEnabled: true,
            api: .trawlScrape,
            baseURL: "http://172.16.0.12",
            maxTimeoutMilliseconds: 60_000
        )

        XCTAssertEqual(solver.endpointURL?.absoluteString, "http://172.16.0.12/scrape")
    }

    func testChallengeSolverKeepsHomeNetworkHTTP() throws {
        let solver = ChallengeSolverSettings(
            isEnabled: true,
            api: .trawlScrape,
            baseURL: "http://192.168.1.20:8191",
            maxTimeoutMilliseconds: 60_000
        )

        XCTAssertEqual(solver.endpointURL?.absoluteString, "http://192.168.1.20:8191/scrape")
    }

    func testChallengeSolverUpgradesRemoteHTTPToHTTPS() throws {
        let solver = ChallengeSolverSettings(
            isEnabled: true,
            api: .trawlScrape,
            baseURL: "http://cfbypass.chema.plus/scrape",
            maxTimeoutMilliseconds: 60_000
        )

        XCTAssertEqual(solver.endpointURL?.absoluteString, "https://cfbypass.chema.plus/scrape")
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            )
        )
    }

    private func randomizedSettings(maxOffsetMinutes: Int) -> AppSettings {
        let template = ScheduleTemplate(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Random",
            isActive: true,
            workDays: [
                WorkDaySchedule(
                    weekday: 2,
                    isEnabled: true,
                    clockIn: TimeOfDay(hour: 9, minute: 0),
                    clockOut: TimeOfDay(hour: 18, minute: 0)
                )
            ]
        )

        return AppSettings(
            isAutomationPaused: false,
            launchAtLogin: false,
            selectedLocation: "Oficina",
            templates: [template],
            exclusions: [],
            history: [],
            clockRandomization: ClockRandomizationSettings(
                isEnabled: true,
                maxClockInOffsetMinutes: maxOffsetMinutes
            )
        )
    }

    private func settingsWithSchedule(
        clockIn: TimeOfDay,
        clockOut: TimeOfDay
    ) -> AppSettings {
        let template = ScheduleTemplate(
            name: "Pruebas",
            isActive: true,
            workDays: (1...7).map { weekday in
                WorkDaySchedule(
                    weekday: weekday,
                    isEnabled: (2...6).contains(weekday),
                    clockIn: clockIn,
                    clockOut: clockOut
                )
            }
        )

        return AppSettings(
            isAutomationPaused: false,
            launchAtLogin: false,
            selectedLocation: "Oficina",
            templates: [template],
            exclusions: [],
            history: []
        )
    }
}
