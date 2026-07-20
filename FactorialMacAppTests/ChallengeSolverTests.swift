import XCTest
@testable import FactorialMacApp

final class ChallengeSolverTests: XCTestCase {
    private let fallbackURL = URL(string: "https://app.factorialhr.com")!

    func testSessionCookieWithNegativeExpiresHasNoExpiryDate() throws {
        // FlareSolverr devuelve expires: -1 para cookies de sesion; deben
        // convertirse en cookies sin caducidad, no en cookies ya caducadas.
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "abc123",
                "domain": ".factorialhr.com",
                "expires": -1
            ])
        )

        let httpCookie = try XCTUnwrap(cookie.httpCookie(fallbackURL: fallbackURL))

        XCTAssertNil(httpCookie.expiresDate)
        XCTAssertTrue(httpCookie.isSessionOnly)
    }

    func testCookieWithFutureExpiresKeepsExpiryDate() throws {
        let expires = Date().addingTimeInterval(3600).timeIntervalSince1970
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "session",
                "value": "xyz",
                "expires": expires
            ])
        )

        let httpCookie = try XCTUnwrap(cookie.httpCookie(fallbackURL: fallbackURL))
        let expiresDate = try XCTUnwrap(httpCookie.expiresDate)

        XCTAssertEqual(expiresDate.timeIntervalSince1970, expires, accuracy: 1)
    }

    func testCookieWithoutDomainFallsBackToRequestHost() throws {
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "session",
                "value": "xyz"
            ])
        )

        let httpCookie = try XCTUnwrap(cookie.httpCookie(fallbackURL: fallbackURL))

        XCTAssertEqual(httpCookie.domain, "app.factorialhr.com")
        XCTAssertEqual(httpCookie.path, "/")
    }

    func testDomainCookieAppliesToApiSubdomain() throws {
        let apiURL = URL(string: "https://api.factorialhr.com")!
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "abc123",
                "domain": ".factorialhr.com"
            ])
        )

        XCTAssertTrue(cookie.isCloudflareClearance)
        XCTAssertTrue(cookie.applies(to: apiURL, fallbackURL: fallbackURL))
    }

    func testHostCookieDoesNotApplyToSiblingSubdomain() throws {
        let apiURL = URL(string: "https://api.factorialhr.com")!
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "abc123",
                "domain": "app.factorialhr.com"
            ])
        )

        XCTAssertFalse(cookie.applies(to: apiURL, fallbackURL: fallbackURL))
    }

    func testImportPolicyAcceptsOnlyCloudflareCookiesForTarget() throws {
        let apiURL = URL(string: "https://api.factorialhr.com")!
        let clearanceCookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "clearance",
                "domain": ".api.factorialhr.com"
            ])
        )
        let authenticationCookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "_factorial_id_refresh",
                "value": "refresh-token",
                "domain": ".factorialhr.com"
            ])
        )
        let clearanceForAnotherHost = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "other-clearance",
                "domain": "app.factorialhr.com"
            ])
        )

        XCTAssertTrue(
            ChallengeSolverCookiePolicy.shouldImport(
                clearanceCookie,
                for: apiURL,
                fallbackURL: apiURL
            )
        )
        XCTAssertFalse(
            ChallengeSolverCookiePolicy.shouldImport(
                authenticationCookie,
                for: apiURL,
                fallbackURL: apiURL
            )
        )
        XCTAssertFalse(
            ChallengeSolverCookiePolicy.shouldImport(
                clearanceForAnotherHost,
                for: apiURL,
                fallbackURL: apiURL
            )
        )
    }

    func testConflictSelectionPreservesAuthenticationAndOtherCookieScopes() throws {
        let incoming = try makeHTTPCookie(
            name: "cf_clearance",
            value: "new-clearance",
            domain: ".api.factorialhr.com"
        )
        let oldClearanceInSameScope = try makeHTTPCookie(
            name: "cf_clearance",
            value: "old-clearance",
            domain: "api.factorialhr.com"
        )
        let authenticationCookie = try makeHTTPCookie(
            name: "_factorial_id_refresh",
            value: "refresh-token",
            domain: ".factorialhr.com"
        )
        let clearanceForAnotherHost = try makeHTTPCookie(
            name: "cf_clearance",
            value: "app-clearance",
            domain: ".app.factorialhr.com"
        )
        let clearanceForAnotherPath = try makeHTTPCookie(
            name: "cf_clearance",
            value: "api-login-clearance",
            domain: ".api.factorialhr.com",
            path: "/login"
        )

        let conflicts = ChallengeSolverCookiePolicy.conflictingCookies(
            beforeImporting: incoming,
            from: [
                oldClearanceInSameScope,
                authenticationCookie,
                clearanceForAnotherHost,
                clearanceForAnotherPath
            ]
        )

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.value, "old-clearance")
        XCTAssertFalse(conflicts.contains { $0.name == "_factorial_id_refresh" })
    }

    func testStoredCookieComparisonNormalizesLeadingDomainDot() throws {
        let expected = try makeHTTPCookie(
            name: "cf_clearance",
            value: "clearance",
            domain: ".api.factorialhr.com"
        )
        let stored = try makeHTTPCookie(
            name: "CF_CLEARANCE",
            value: "clearance",
            domain: "api.factorialhr.com"
        )

        XCTAssertTrue(
            ChallengeSolverCookiePolicy.contains(
                expected,
                in: [stored]
            )
        )
    }

    func testCookieParsesSameSiteNoneMetadata() throws {
        let cookie = try XCTUnwrap(
            ChallengeSolverCookie(dictionary: [
                "name": "cf_clearance",
                "value": "abc123",
                "domain": ".api.factorialhr.com",
                "sameSite": "None"
            ])
        )

        let httpCookie = try XCTUnwrap(cookie.httpCookie(fallbackURL: fallbackURL))

        XCTAssertEqual(cookie.sameSite, "None")
        XCTAssertEqual(httpCookie.domain, ".api.factorialhr.com")
    }

    func testSolutionParsesFlareSolverrPayload() throws {
        let payload = """
        {
          "status": "ok",
          "solution": {
            "userAgent": "Mozilla/5.0 Test",
            "cookies": [
              {"name": "cf_clearance", "value": "abc", "domain": ".factorialhr.com", "expires": -1},
              {"name": "session", "value": "def", "expires": 1893456000}
            ]
          }
        }
        """.data(using: .utf8)!

        let solution = try ChallengeSolverSolution(data: payload)

        XCTAssertEqual(solution.userAgent, "Mozilla/5.0 Test")
        XCTAssertEqual(solution.cookies.count, 2)
        XCTAssertEqual(solution.cookies.first?.name, "cf_clearance")
    }

    func testSolutionWithErrorStatusThrows() {
        let payload = """
        {"status": "error", "message": "Challenge no resuelto"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try ChallengeSolverSolution(data: payload)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Challenge no resuelto"
            )
        }
    }

    func testSolutionWithoutCookiesNorUserAgentThrows() {
        let payload = """
        {"status": "ok", "solution": {}}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try ChallengeSolverSolution(data: payload))
    }

    private func makeHTTPCookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/"
    ) throws -> HTTPCookie {
        try XCTUnwrap(
            HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .secure: "TRUE"
            ])
        )
    }
}
