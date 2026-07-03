import Foundation
import Network
import WebKit

enum FactorialClockingError: LocalizedError {
    case notAuthenticated
    case graphqlError(String)
    case invalidResult
    case javascriptException(String)
    case challengeSolverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "La sesion de Factorial no esta iniciada o ha caducado."
        case .graphqlError(let message):
            message
        case .invalidResult:
            "Factorial devolvio una respuesta inesperada."
        case .javascriptException(let message):
            message
        case .challengeSolverError(let message):
            message
        }
    }
}

enum FactorialAuthState: Equatable {
    case unknown
    case loginRequired
    case authenticated
}

@MainActor
final class FactorialClockingClient: NSObject, ObservableObject {
    @Published private(set) var authState: FactorialAuthState = .unknown

    let webView: WKWebView

    private let baseURL = URL(string: "https://app.factorialhr.com")!
    private let dashboardURL = URL(string: "https://app.factorialhr.com/dashboard")!
    private var appliedProxySettings = HTTPProxySettings.defaultSettings
    private var appliedChallengeSolverSettings = ChallengeSolverSettings.defaultSettings
    private var preparedChallengeSolverKey: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func openLogin() {
        Task { @MainActor in
            try? await prepareChallengeSolverSessionIfNeeded(force: false)
            loadLogin()
        }
    }

    func applyProxySettings(_ settings: HTTPProxySettings) {
        guard settings != appliedProxySettings else {
            return
        }

        appliedProxySettings = settings
        configureWebKitProxy(settings)
    }

    func applyChallengeSolverSettings(_ settings: ChallengeSolverSettings) {
        guard settings != appliedChallengeSolverSettings else {
            return
        }

        appliedChallengeSolverSettings = settings
        preparedChallengeSolverKey = nil
    }

    func refreshAuthState() async {
        if webView.url == nil {
            openLogin()
            authState = .loginRequired
            return
        }

        do {
            let href = try await currentURLString()
            authState = href.isFactorialLoginURL ? .loginRequired : .authenticated
        } catch {
            authState = .unknown
        }
    }

    func clockIn(location: String) async throws {
        try await clock(.clockIn, location: location)
    }

    func clockOut(location: String) async throws {
        try await clock(.clockOut, location: location)
    }

    private func clock(_ kind: ClockEventKind, location: String) async throws {
        if webView.url == nil {
            try await prepareChallengeSolverSessionIfNeeded(force: false)
            loadLogin()
            try await Task.sleep(for: .seconds(2))
        }

        try await refreshAuthBeforeClocking()

        let script = Self.graphQLClockScript(kind: kind, location: location)
        var result = try await executeClockScript(script)
        var ok = result["ok"] as? Bool ?? false

        if ok {
            authState = .authenticated
            return
        }

        if shouldRefreshChallengeSession(statusCode(from: result)) {
            try await prepareChallengeSolverSessionIfNeeded(force: true)
            result = try await executeClockScript(script)
            ok = result["ok"] as? Bool ?? false

            if ok {
                authState = .authenticated
                return
            }
        }

        let message = result["message"] as? String ?? "Factorial rechazo el fichaje."
        if statusCode(from: result) == 401 {
            try await openDashboardBeforeVisibleClocking()
            if try await clockUsingFactorialUI(kind) {
                authState = .authenticated
                return
            }

            await refreshAuthState()
            throw FactorialClockingError.graphqlError(
                "\(message). La sesion web esta abierta, pero la llamada directa de fichaje ha caducado y no pude completar el fichaje desde el boton visible de Factorial. Vuelve a cargar Factorial en la pestana Login."
            )
        }

        throw FactorialClockingError.graphqlError(message)
    }

    private func loadLogin() {
        webView.load(URLRequest(url: baseURL))
    }

    private func refreshAuthBeforeClocking() async throws {
        if webView.url == nil {
            openLogin()
        }

        let href = try await currentURLString()
        if href.isFactorialLoginURL {
            authState = .loginRequired
            throw FactorialClockingError.notAuthenticated
        }

        authState = .authenticated
    }

    private func openDashboardBeforeVisibleClocking() async throws {
        let href = try await currentURLString()
        if href.isFactorialDashboardURL {
            return
        }

        webView.load(URLRequest(url: dashboardURL))
        try await waitForURL(timeoutTicks: 40) { urlString in
            urlString.isFactorialDashboardURL || urlString.isFactorialLoginURL
        }

        let updatedHref = try await currentURLString()
        if updatedHref.isFactorialLoginURL {
            authState = .loginRequired
            throw FactorialClockingError.notAuthenticated
        }
    }

    private func waitForURL(timeoutTicks: Int, matches: (String) -> Bool) async throws {
        for _ in 0..<timeoutTicks {
            let href = try await currentURLString()
            if matches(href) {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        throw FactorialClockingError.graphqlError("No se pudo abrir el dashboard de Factorial antes de pulsar el boton visible.")
    }

    private func currentURLString() async throws -> String {
        if let url = webView.url?.absoluteString {
            return url
        }

        let result = try await webView.evaluateJavaScript("window.location.href")
        return result as? String ?? ""
    }

    private func clockUsingFactorialUI(_ kind: ClockEventKind) async throws -> Bool {
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.visibleClockButtonScript(kind: kind),
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw Self.enrichedJavaScriptError(from: error)
        }

        guard let result = rawResult as? [String: Any],
              let ok = result["ok"] as? Bool else {
            throw FactorialClockingError.invalidResult
        }

        return ok
    }

    private func executeClockScript(_ script: String) async throws -> [String: Any] {
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw Self.enrichedJavaScriptError(from: error)
        }

        guard let result = rawResult as? [String: Any],
              result["ok"] is Bool else {
            throw FactorialClockingError.invalidResult
        }

        return result
    }

    private static func enrichedJavaScriptError(from error: Error) -> Error {
        let nsError = error as NSError
        guard let message = javaScriptExceptionMessage(from: nsError) else {
            return error
        }

        return FactorialClockingError.javascriptException(message)
    }

    private static func javaScriptExceptionMessage(from error: NSError) -> String? {
        let userInfo = error.userInfo
        let message = userInfo["WKJavaScriptExceptionMessage"] as? String
        let sourceURL = userInfo["WKJavaScriptExceptionSourceURL"] as? String
        let line = (userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber)?.intValue
        let column = (userInfo["WKJavaScriptExceptionColumnNumber"] as? NSNumber)?.intValue

        guard message != nil || sourceURL != nil || line != nil || column != nil else {
            return nil
        }

        var details = ["Excepcion JavaScript"]
        if let message, !message.isEmpty {
            details.append(message)
        }
        if let line {
            if let column {
                details.append("linea \(line), columna \(column)")
            } else {
                details.append("linea \(line)")
            }
        }
        if let sourceURL, !sourceURL.isEmpty {
            details.append(sourceURL)
        }

        return details.joined(separator: " - ")
    }

    private func statusCode(from result: [String: Any]) -> Int? {
        if let status = result["status"] as? Int {
            return status
        }

        if let status = result["status"] as? NSNumber {
            return status.intValue
        }

        return nil
    }

    private func shouldRefreshChallengeSession(_ statusCode: Int?) -> Bool {
        guard appliedChallengeSolverSettings.isEnabled,
              let statusCode else {
            return false
        }

        return [403, 429, 503].contains(statusCode)
    }

    private func configureWebKitProxy(_ settings: HTTPProxySettings) {
        guard let hostPort = settings.hostPort else {
            webView.configuration.websiteDataStore.proxyConfigurations = []
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostPort.host),
            port: NWEndpoint.Port(rawValue: hostPort.port)!
        )

        var proxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        proxyConfiguration.allowFailover = false
        webView.configuration.websiteDataStore.proxyConfigurations = [proxyConfiguration]
    }

    private func prepareChallengeSolverSessionIfNeeded(force: Bool) async throws {
        let settings = appliedChallengeSolverSettings
        guard settings.isEnabled else {
            return
        }

        guard let endpointURL = settings.endpointURL else {
            throw FactorialClockingError.challengeSolverError("El resolvedor local no tiene una URL valida.")
        }

        let solverKey = "\(settings.api.rawValue)|\(endpointURL.absoluteString)|\(baseURL.absoluteString)"
        if !force, preparedChallengeSolverKey == solverKey {
            return
        }

        let solution = try await requestChallengeSolver(settings: settings, endpointURL: endpointURL)
        if let userAgent = solution.userAgent, !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }

        for cookie in solution.cookies {
            guard let httpCookie = cookie.httpCookie(fallbackURL: baseURL) else {
                continue
            }

            await setCookie(httpCookie)
        }

        preparedChallengeSolverKey = solverKey
    }

    private func requestChallengeSolver(
        settings: ChallengeSolverSettings,
        endpointURL: URL
    ) async throws -> ChallengeSolverSolution {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(settings.clampedMaxTimeoutMilliseconds) / 1000
        request.httpBody = try JSONSerialization.data(withJSONObject: challengeSolverPayload(settings: settings))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FactorialClockingError.challengeSolverError("El resolvedor local respondio con HTTP \(status).")
        }

        return try ChallengeSolverSolution(data: data)
    }

    private func challengeSolverPayload(settings: ChallengeSolverSettings) -> [String: Any] {
        switch settings.api {
        case .flareSolverrV1:
            [
                "cmd": "request.get",
                "url": baseURL.absoluteString,
                "maxTimeout": settings.clampedMaxTimeoutMilliseconds
            ]
        case .trawlScrape:
            [
                "url": baseURL.absoluteString,
                "maxTimeout": settings.clampedMaxTimeoutMilliseconds
            ]
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private static func graphQLClockScript(kind: ClockEventKind, location: String) -> String {
        let operationName = kind.operationName
        let mutation = kind.graphQLMutation
        let locationType = location.factorialLocationType

        return """
        const pad = (value) => String(value).padStart(2, "0");
        const formatNow = (date) => {
          const offsetMinutes = -date.getTimezoneOffset();
          const sign = offsetMinutes >= 0 ? "+" : "-";
          const absoluteOffset = Math.abs(offsetMinutes);
          return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
            `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
            `${sign}${pad(Math.floor(absoluteOffset / 60))}:${pad(absoluteOffset % 60)}`;
        };
        const formatDate = (date) => {
          return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
        };
        const extractErrors = (payload) => {
          if (payload?.errors?.length) {
            return payload.errors.map((error) => error.message || String(error)).join("\\n");
          }

          const mutationRoot = payload?.data?.attendanceMutations;
          const mutationPayload = mutationRoot?.clockInAttendanceShift || mutationRoot?.forgotClockOutAttendanceShift;
          const errors = mutationPayload?.errors || [];
          if (!errors.length) {
            return "";
          }

          return errors.map((error) => {
            if (error.message) {
              return error.message;
            }
            if (Array.isArray(error.messages)) {
              return `${error.field || "Error"}: ${error.messages.join(", ")}`;
            }
            return JSON.stringify(error);
          }).join("\\n");
        };

        const nowDate = new Date();
        const variables = {
          now: formatNow(nowDate),
          date: formatDate(nowDate),
          source: "desktop"
        };

        if ("\(operationName)" === "ClockIn") {
          variables.locationType = "\(locationType)";
        }

        const controller = new AbortController();
        const timeoutID = setTimeout(() => controller.abort(), 30000);
        let response;

        try {
          response = await fetch("https://api.factorialhr.com/graphql?\(operationName)", {
            method: "POST",
            credentials: "include",
            signal: controller.signal,
            headers: {
              "accept": "*/*",
              "content-type": "application/json",
              "x-deployment-phase": "default",
              "x-factorial-bigint-support": "true",
              "x-factorial-origin": "web"
            },
            body: JSON.stringify({
              operationName: "\(operationName)",
              variables,
              query: "\(mutation.jsEscaped)"
            })
          });
        } catch (error) {
          return {
            ok: false,
            status: 0,
            message: `No se pudo ejecutar la llamada de fichaje: ${error?.message || String(error)}`
          };
        } finally {
          clearTimeout(timeoutID);
        }

        const payload = await response.json().catch(() => null);
        if (!response.ok) {
          return {
            ok: false,
            status: response.status,
            message: `Factorial respondio con HTTP ${response.status}`
          };
        }

        const errorMessage = extractErrors(payload);
        if (errorMessage) {
          return { ok: false, status: response.status, message: errorMessage };
        }

        return { ok: true, status: response.status };
        """
    }

    private static func visibleClockButtonScript(kind: ClockEventKind) -> String {
        let expectedLabels = kind.visibleActionLabels

        return """
        const normalize = (value) => (value || "")
          .normalize("NFD")
          .replace(/[\\u0300-\\u036f]/g, "")
          .toLowerCase()
          .replace(/\\s+/g, " ")
          .trim();

        if (normalize(window.location.href).includes("login")) {
          return { ok: false, authRequired: true, message: "La pagina de Factorial esta en login." };
        }

        const isVisible = (element) => {
          const style = window.getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.visibility !== "hidden" &&
            style.display !== "none" &&
            !element.disabled &&
            rect.width > 0 &&
            rect.height > 0;
        };

        const findClockingCard = (button) => {
          let node = button;
          for (let depth = 0; node && depth < 8; depth += 1, node = node.parentElement) {
            const text = normalize(node.innerText || node.textContent);
            if (text.includes("fichaje") || text.includes("attendance")) {
              return node;
            }
          }

          return button.parentElement || document.body;
        };

        const expectedLabels = \(expectedLabels.jsArrayLiteral);
        const clockButtonLabels = [
          "fichar",
          "entrada",
          "salida",
          "clock in",
          "clock out",
          "check in",
          "check out",
          ...expectedLabels
        ];
        const candidates = Array.from(document.querySelectorAll("button, a, [role='button']"))
          .filter(isVisible)
          .map((element) => ({
            element,
            text: normalize(element.innerText || element.textContent || element.getAttribute("aria-label"))
          }))
          .filter((candidate) => clockButtonLabels.some((label) => candidate.text.includes(label)));

        for (const candidate of candidates) {
          const card = findClockingCard(candidate.element);
          const cardText = normalize(card.innerText || card.textContent);
          const matchesExpectedAction = expectedLabels.some((label) =>
            cardText.includes(label) || candidate.text.includes(label)
          );

          if (!matchesExpectedAction) {
            continue;
          }

          candidate.element.click();
          await new Promise((resolve) => setTimeout(resolve, 1500));
          return { ok: true, clicked: true };
        }

        return {
          ok: false,
          actionMismatch: candidates.length > 0,
          message: "No se encontro un boton de fichaje visible que coincidiera con la accion esperada."
        };
        """
    }
}

extension FactorialClockingClient: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await refreshAuthState()
        }
    }
}

private extension String {
    var isFactorialDashboardURL: Bool {
        guard let url = URL(string: self),
              url.host?.lowercased() == "app.factorialhr.com" else {
            return false
        }

        return url.path.lowercased().hasPrefix("/dashboard")
    }

    var isFactorialLoginURL: Bool {
        let lowercased = lowercased()
        return lowercased.contains("login") ||
            lowercased.contains("signin") ||
            lowercased.contains("sign_in") ||
            lowercased.contains("oauth")
    }

    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    var jsArrayLiteral: String {
        let values = split(separator: "\n")
            .map { "\"\(String($0).jsEscaped)\"" }
            .joined(separator: ", ")

        return "[\(values)]"
    }

    var factorialLocationType: String {
        let normalized = folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("remot") || normalized.contains("casa") || normalized.contains("home") {
            return "remote"
        }

        if normalized.contains("viaj") || normalized.contains("travel") {
            return "business_trip"
        }

        return "office"
    }
}

private struct ChallengeSolverSolution {
    let cookies: [ChallengeSolverCookie]
    let userAgent: String?

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
}

private struct ChallengeSolverCookie {
    let name: String
    let value: String
    let domain: String?
    let path: String?
    let expires: TimeInterval?
    let httpOnly: Bool
    let secure: Bool

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
    }

    func httpCookie(fallbackURL: URL) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: normalizedDomain(fallbackURL: fallbackURL),
            .path: path?.isEmpty == false ? path! : "/",
            .secure: secure ? "TRUE" : "FALSE"
        ]

        if let expires {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }

        if httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        return HTTPCookie(properties: properties)
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

private extension ClockEventKind {
    var operationName: String {
        switch self {
        case .clockIn:
            "ClockIn"
        case .clockOut:
            "ForgotClockOut"
        }
    }

    var graphQLMutation: String {
        switch self {
        case .clockIn:
            """
            mutation ClockIn($locationType: AttendanceShiftLocationTypeEnum, $now: ISO8601DateTime!, $projectTaskId: ID, $projectWorkerId: ID, $source: AttendanceEnumsShiftSourceEnum, $subprojectId: ID, $timeSettingsBreakConfigurationId: ID) {
              attendanceMutations {
                clockInAttendanceShift(
                  locationType: $locationType
                  now: $now
                  projectTaskId: $projectTaskId
                  projectWorkerId: $projectWorkerId
                  source: $source
                  subprojectId: $subprojectId
                  timeSettingsBreakConfigurationId: $timeSettingsBreakConfigurationId
                ) {
                  errors {
                    ...ErrorDetails
                    __typename
                  }
                  shift {
                    id
                    clockIn
                    clockOut
                    date
                    locationType
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }

            fragment ErrorDetails on MutationError {
              ... on SimpleError {
                message
                type
                __typename
              }
              ... on StructuredError {
                field
                messages
                __typename
              }
              __typename
            }
            """
        case .clockOut:
            """
            mutation ForgotClockOut($now: ISO8601DateTime!, $source: AttendanceEnumsShiftSourceEnum) {
              attendanceMutations {
                forgotClockOutAttendanceShift(now: $now, source: $source) {
                  errors {
                    ...ErrorDetails
                    __typename
                  }
                  shift {
                    id
                    clockIn
                    clockOut
                    date
                    locationType
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }

            fragment ErrorDetails on MutationError {
              ... on SimpleError {
                message
                type
                __typename
              }
              ... on StructuredError {
                field
                messages
                __typename
              }
              __typename
            }
            """
        }
    }

    var visibleActionLabels: String {
        switch self {
        case .clockIn:
            """
            entrada
            fichar
            sin fichar
            clock in
            check in
            """
        case .clockOut:
            """
            salida
            salir
            clock out
            check out
            """
        }
    }
}
