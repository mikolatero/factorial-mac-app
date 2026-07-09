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
}
