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
        let settings = AppSettings.defaultSettings
        let now = try date(year: 2026, month: 6, day: 1, hour: 9, minute: 6)

        let event = AutomationScheduler.dueEvent(
            now: now,
            settings: settings,
            executedEventKeys: [],
            calendar: calendar
        )

        XCTAssertNil(event)
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

    func testPruneEventKeysKeepsOnlyTodayAndYesterday() throws {
        let now = try date(year: 2026, month: 6, day: 3, hour: 9, minute: 0)
        let keys: Set<String> = [
            "2026-06-03-clockIn",
            "2026-06-02-clockOut",
            "2026-06-01-clockIn",
            "2025-12-31-clockOut"
        ]

        let pruned = AutomationScheduler.pruneEventKeys(keys, now: now, calendar: calendar)

        XCTAssertEqual(pruned, ["2026-06-03-clockIn", "2026-06-02-clockOut"])
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
    }

    func testSettingsRoundTripPersistsExecutedAutomationEventKeys() throws {
        var settings = AppSettings.defaultSettings
        settings.executedAutomationEventKeys = ["2026-06-01-clockIn", "2026-06-01-clockOut"]

        let data = try JSONEncoder.settingsEncoder.encode(settings)
        let decoded = try JSONDecoder.settingsDecoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.executedAutomationEventKeys, ["2026-06-01-clockIn", "2026-06-01-clockOut"])
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
}
