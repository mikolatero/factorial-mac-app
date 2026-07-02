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
}
