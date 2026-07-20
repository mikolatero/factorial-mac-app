import Foundation

struct ChallengeSolverSolution {
    let cookies: [ChallengeSolverCookie]
    let userAgent: String?
    let statusCode: Int?
    let tier: Int?
    let sessionCached: Bool?
    let totalMilliseconds: Int?
    let proxyUsed: Bool?

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw FactorialClockingError.challengeSolverError("El resolvedor local devolvio JSON inesperado.")
        }

        if let status = dictionary["status"] as? String,
           status.lowercased() == "error" {
            let message = dictionary["message"] as? String ?? "El resolvedor local devolvio error."
            throw FactorialClockingError.challengeSolverError(message)
        }

        let solution = dictionary["solution"] as? [String: Any]
        let cookieObjects = Self.firstCookieArray(in: solution ?? dictionary) ?? []
        cookies = cookieObjects.compactMap(ChallengeSolverCookie.init(dictionary:))
        userAgent = Self.firstStringValue(named: "userAgent", in: solution ?? dictionary) ??
            Self.firstStringValue(named: "user_agent", in: solution ?? dictionary)
        statusCode = Self.intValue(named: "statusCode", in: dictionary)
        tier = Self.intValue(named: "tier", in: dictionary)
        sessionCached = dictionary["sessionCached"] as? Bool
        totalMilliseconds = Self.intValue(named: "totalMs", in: dictionary)
        proxyUsed = dictionary["proxyUsed"] as? Bool

        if cookies.isEmpty, userAgent == nil {
            throw FactorialClockingError.challengeSolverError("El resolvedor local no devolvio cookies ni user agent.")
        }
    }

    private static func firstCookieArray(in object: Any) -> [[String: Any]]? {
        if let dictionary = object as? [String: Any] {
            if let cookies = dictionary["cookies"] as? [[String: Any]] {
                return cookies
            }

            for value in dictionary.values {
                if let cookies = firstCookieArray(in: value) {
                    return cookies
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let cookies = firstCookieArray(in: value) {
                    return cookies
                }
            }
        }

        return nil
    }

    private static func firstStringValue(named name: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[name] as? String, !value.isEmpty {
                return value
            }

            for value in dictionary.values {
                if let result = firstStringValue(named: name, in: value) {
                    return result
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let result = firstStringValue(named: name, in: value) {
                    return result
                }
            }
        }

        return nil
    }

    private static func intValue(named name: String, in dictionary: [String: Any]) -> Int? {
        if let value = dictionary[name] as? Int {
            return value
        }

        if let value = dictionary[name] as? Double {
            return Int(value)
        }

        if let value = dictionary[name] as? String {
            return Int(value)
        }

        return nil
    }

    func hasCloudflareClearance(forAnyOf urls: [URL], fallbackURL: URL) -> Bool {
        cookies.contains { cookie in
            cookie.isCloudflareClearance &&
                urls.contains { cookie.applies(to: $0, fallbackURL: fallbackURL) }
        }
    }
}

struct ChallengeSolverCookie {
    let name: String
    let value: String
    let domain: String?
    let path: String?
    let expires: TimeInterval?
    let httpOnly: Bool
    let secure: Bool
    let sameSite: String?

    var isCloudflareClearance: Bool {
        name.caseInsensitiveCompare("cf_clearance") == .orderedSame
    }

    init?(dictionary: [String: Any]) {
        guard let name = dictionary["name"] as? String,
              let value = dictionary["value"] as? String,
              !name.isEmpty else {
            return nil
        }

        self.name = name
        self.value = value
        domain = dictionary["domain"] as? String
        path = dictionary["path"] as? String
        expires = Self.timeInterval(from: dictionary["expires"] ?? dictionary["expiry"] ?? dictionary["expiresAt"])
        httpOnly = dictionary["httpOnly"] as? Bool ?? dictionary["http_only"] as? Bool ?? false
        secure = dictionary["secure"] as? Bool ?? true
        sameSite = dictionary["sameSite"] as? String ?? dictionary["same_site"] as? String
    }

    func httpCookie(fallbackURL: URL) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: normalizedDomain(fallbackURL: fallbackURL),
            .path: path?.isEmpty == false ? path! : "/",
            .secure: secure ? "TRUE" : "FALSE"
        ]

        // FlareSolverr devuelve expires <= 0 (habitualmente -1) para cookies de sesion:
        // no hay que asignar caducidad o WebKit las descarta como caducadas.
        if let expires, expires > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }

        if httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        return HTTPCookie(properties: properties)
    }

    func applies(to url: URL, fallbackURL: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        let cookieDomain = normalizedDomain(fallbackURL: fallbackURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingPrefix(".")

        return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
    }

    private func normalizedDomain(fallbackURL: URL) -> String {
        guard let domain,
              !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallbackURL.host ?? "app.factorialhr.com"
        }

        return domain
    }

    private static func timeInterval(from value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval {
            return value
        }

        if let value = value as? Int {
            return TimeInterval(value)
        }

        if let value = value as? String {
            return TimeInterval(value)
        }

        return nil
    }
}

/// The challenge solver runs in a separate browser session. Only Cloudflare
/// infrastructure cookies may cross that boundary; importing Factorial
/// authentication cookies would replace the user's persistent WebKit session.
enum ChallengeSolverCookiePolicy {
    static func shouldImport(
        _ cookie: ChallengeSolverCookie,
        for targetURL: URL,
        fallbackURL: URL
    ) -> Bool {
        isCloudflareCookieName(cookie.name) &&
            cookie.applies(to: targetURL, fallbackURL: fallbackURL)
    }

    static func conflictingCookies(
        beforeImporting incomingCookie: HTTPCookie,
        from storedCookies: [HTTPCookie]
    ) -> [HTTPCookie] {
        guard isFactorialCloudflareCookie(incomingCookie) else {
            return []
        }

        return storedCookies.filter { storedCookie in
            isFactorialCloudflareCookie(storedCookie) &&
                hasSameScope(storedCookie, incomingCookie) &&
                storedCookie.value != incomingCookie.value
        }
    }

    static func contains(_ expectedCookie: HTTPCookie, in storedCookies: [HTTPCookie]) -> Bool {
        storedCookies.contains { storedCookie in
            hasSameScope(storedCookie, expectedCookie) &&
                storedCookie.value == expectedCookie.value
        }
    }

    static func isCloudflareCookieName(_ name: String) -> Bool {
        let normalizedName = name.lowercased()
        let exactNames = [
            "cf_clearance",
            "__cf_bm",
            "__cflb",
            "__cfseq",
            "__cfwaitingroom",
            "_cfuvid",
            "cf_ob_info",
            "cf_use_ob"
        ]

        return exactNames.contains(normalizedName) ||
            normalizedName.hasPrefix("cf_chl_")
    }

    private static func isFactorialCloudflareCookie(_ cookie: HTTPCookie) -> Bool {
        isCloudflareCookieName(cookie.name) &&
            isFactorialCookieDomain(cookie.domain)
    }

    private static func isFactorialCookieDomain(_ domain: String) -> Bool {
        let normalizedDomain = normalizeDomain(domain)
        return normalizedDomain == "factorialhr.com" ||
            normalizedDomain.hasSuffix(".factorialhr.com")
    }

    private static func hasSameScope(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame &&
            normalizeDomain(lhs.domain) == normalizeDomain(rhs.domain) &&
            normalizePath(lhs.path) == normalizePath(rhs.path)
    }

    private static func normalizeDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingPrefix(".")
    }

    private static func normalizePath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else {
            return self
        }

        return String(dropFirst(prefix.count))
    }
}
