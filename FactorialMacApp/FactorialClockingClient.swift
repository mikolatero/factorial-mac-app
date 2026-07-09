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

    private let javaScriptLogMessageHandler: JavaScriptLogMessageHandler
    private let baseURL = URL(string: "https://app.factorialhr.com")!
    private let dashboardURL = URL(string: "https://app.factorialhr.com/dashboard")!
    private var appliedProxySettings = HTTPProxySettings.defaultSettings
    private var appliedChallengeSolverSettings = ChallengeSolverSettings.defaultSettings
    private var preparedChallengeSolverKey: String?
    private weak var logStore: AppLogStore?

    override init() {
        let messageHandler = JavaScriptLogMessageHandler()
        javaScriptLogMessageHandler = messageHandler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.javaScriptConsoleCaptureScript)
        configuration.userContentController.add(messageHandler, name: "factorialAppLog")

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func attachLogStore(_ logStore: AppLogStore) {
        self.logStore = logStore
        javaScriptLogMessageHandler.logStore = logStore
    }

    func openLogin() {
        Task { @MainActor in
            try? await refreshDashboardFromOrigin(reason: "Abriendo Factorial")
        }
    }

    func refreshDashboardFromOrigin(reason: String = "Refrescando dashboard") async throws {
        logStore?.info(reason, source: "WebKit")
        try await prepareChallengeSolverSessionIfNeeded(force: false)

        webView.stopLoading()
        let href = try? await currentURLString()
        if href?.isFactorialDashboardURL == true {
            logStore?.debug("Recargando dashboard desde origen", source: "WebKit")
            webView.reloadFromOrigin()
        } else {
            var request = URLRequest(url: dashboardURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            logStore?.debug(dashboardURL.absoluteString, source: "WebKit")
            webView.load(request)
        }

        try await waitForDashboardDocument(timeoutTicks: 160)
        authState = .authenticated
        await logVisibleDashboardClockButtons()
    }

    func refreshDashboardManually() {
        Task { @MainActor in
            do {
                try await refreshDashboardFromOrigin(reason: "Refresco manual del dashboard")
            } catch {
                logStore?.error(error.localizedDescription, source: "WebKit")
            }
        }
    }

    func applyProxySettings(_ settings: HTTPProxySettings) {
        guard settings != appliedProxySettings else {
            return
        }

        appliedProxySettings = settings
        logStore?.info(settings.statusText, source: "Proxy")
        configureWebKitProxy(settings)
    }

    func applyChallengeSolverSettings(_ settings: ChallengeSolverSettings) {
        guard settings != appliedChallengeSolverSettings else {
            return
        }

        appliedChallengeSolverSettings = settings
        preparedChallengeSolverKey = nil
        logStore?.info(settings.statusText, source: "Resolvedor")
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
            logStore?.debug("Estado de sesion: \(authState.logTitle)", source: "Auth")
        } catch {
            authState = .unknown
            logStore?.warning("No se pudo comprobar la sesion: \(error.localizedDescription)", source: "Auth")
        }
    }

    func clockIn(location: String) async throws {
        try await clock(.clockIn, location: location)
    }

    func clockOut(location: String) async throws {
        try await clock(.clockOut, location: location)
    }

    private func clock(_ kind: ClockEventKind, location: String) async throws {
        logStore?.info("Iniciando \(kind.title.lowercased())", source: "Fichaje")

        if webView.url == nil {
            try await prepareChallengeSolverSessionIfNeeded(force: false)
            try await refreshDashboardFromOrigin(reason: "Preparando dashboard para fichar")
            try await Task.sleep(for: .seconds(2))
        } else {
            try await refreshDashboardFromOrigin(reason: "Recargando dashboard antes de fichar")
        }

        try await refreshAuthBeforeClocking()

        let script = Self.graphQLClockScript(kind: kind, location: location)
        var result = try await executeClockScript(script)
        var ok = result["ok"] as? Bool ?? false

        if ok {
            try await finishGraphQLClock(kind, message: "\(kind.title) completada por GraphQL")
            return
        }

        if shouldRefreshChallengeSession(statusCode(from: result)) {
            logStore?.warning("Factorial respondio con HTTP \(statusCode(from: result) ?? 0). Refrescando sesion del resolvedor.", source: "Fichaje")
            try await prepareChallengeSolverSessionIfNeeded(force: true)
            result = try await executeClockScript(script)
            ok = result["ok"] as? Bool ?? false

            if ok {
                try await finishGraphQLClock(
                    kind,
                    message: "\(kind.title) completada despues de refrescar el resolvedor"
                )
                return
            }
        }

        let message = result["message"] as? String ?? "Factorial rechazo el fichaje."
        logStore?.warning(message, source: "Fichaje")
        if statusCode(from: result) == 401 || confirmationMissing(from: result) {
            if confirmationMissing(from: result) {
                do {
                    try await verifyVisibleClockState(kind, reloadDashboard: true)
                    authState = .authenticated
                    logStore?.info("\(kind.title) confirmada desde el dashboard", source: "Fichaje")
                    return
                } catch {
                    logStore?.warning(
                        "La UI todavia no confirmo \(kind.title.lowercased()): \(error.localizedDescription)",
                        source: "Fichaje"
                    )
                }
            }

            try await openDashboardBeforeVisibleClocking(kind)
            if try await clockUsingFactorialUI(kind) {
                authState = .authenticated
                logStore?.info("\(kind.title) completada desde la UI visible", source: "Fichaje")
                return
            }

            await refreshAuthState()
            throw FactorialClockingError.graphqlError(
                "\(message). La sesion web esta abierta, pero la llamada directa de fichaje ha caducado y no pude completar el fichaje desde el boton visible de Factorial. Vuelve a cargar Factorial en la pestana Login."
            )
        }

        throw FactorialClockingError.graphqlError(message)
    }

    private func finishGraphQLClock(_ kind: ClockEventKind, message: String) async throws {
        do {
            try await verifyVisibleClockState(kind, reloadDashboard: true)
        } catch {
            logStore?.warning(
                "GraphQL respondio correctamente, pero la UI de Factorial no confirmo el estado: \(error.localizedDescription)",
                source: "Fichaje"
            )

            do {
                try await openDashboardBeforeVisibleClocking(kind)
                if try await clockUsingFactorialUI(kind) {
                    authState = .authenticated
                    logStore?.info("\(kind.title) completada desde la UI visible", source: "Fichaje")
                    return
                }
            } catch {
                throw FactorialClockingError.graphqlError(
                    "Factorial no mostro el estado confirmado tras el fichaje. No se marca como OK para evitar un falso positivo."
                )
            }

            throw FactorialClockingError.graphqlError(
                "Factorial no mostro el estado confirmado tras el fichaje. No se marca como OK para evitar un falso positivo."
            )
        }

        authState = .authenticated
        logStore?.info(message, source: "Fichaje")
    }

    private func loadLogin() {
        logStore?.debug(baseURL.absoluteString, source: "WebKit")
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

    private func openDashboardBeforeVisibleClocking(_ kind: ClockEventKind) async throws {
        try await refreshDashboardFromOrigin(reason: "Recargando dashboard antes del fichaje visible")
        try await waitForDashboardClockButton(kind, timeoutTicks: 80)

        let updatedHref = try await currentURLString()
        if updatedHref.isFactorialLoginURL {
            authState = .loginRequired
            throw FactorialClockingError.notAuthenticated
        }
    }

    private func waitForDashboardClockButton(_ kind: ClockEventKind, timeoutTicks: Int) async throws {
        for _ in 0..<timeoutTicks {
            let href = try await currentURLString()

            if href.isFactorialLoginURL {
                authState = .loginRequired
                throw FactorialClockingError.notAuthenticated
            }

            if href.isFactorialDashboardURL {
                if try await isDashboardReady() {
                    let buttonState = try await visibleClockButtonState(kind)
                    if buttonState.ok {
                        logStore?.info("Veo el boton de \(kind.visibleButtonLogName)", source: "Fichaje")
                        return
                    }

                    logStore?.debug(
                        buttonState.message ?? "No veo el boton de \(kind.visibleButtonLogName) en el dashboard.",
                        source: "Fichaje"
                    )
                }
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        let href = (try? await currentURLString()) ?? "URL desconocida"
        let message = "No veo el boton de \(kind.visibleButtonLogName) en el dashboard de Factorial. URL actual: \(href)"
        logStore?.error(message, source: "Fichaje")
        throw FactorialClockingError.graphqlError(message)
    }

    private func currentURLString() async throws -> String {
        if let result = try? await webView.evaluateJavaScript("window.location.href") as? String,
           !result.isEmpty {
            return result
        }

        return webView.url?.absoluteString ?? ""
    }

    private func waitForDashboardDocument(timeoutTicks: Int) async throws {
        var stableDashboardTicks = 0

        for _ in 0..<timeoutTicks {
            let href = try await currentURLString()

            if href.isFactorialLoginURL {
                authState = .loginRequired
                throw FactorialClockingError.notAuthenticated
            }

            if href.isFactorialDashboardURL, try await isDashboardReady() {
                stableDashboardTicks += 1
                if stableDashboardTicks >= 3 {
                    return
                }
            } else {
                stableDashboardTicks = 0
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        let href = (try? await currentURLString()) ?? "URL desconocida"
        await logVisibleDashboardClockButtons()
        throw FactorialClockingError.graphqlError("No se pudo cargar el dashboard de Factorial. URL actual: \(href)")
    }

    private func isDashboardReady() async throws -> Bool {
        let readyState = (try? await webView.evaluateJavaScript("document.readyState")) as? String
        guard readyState == "interactive" || readyState == "complete" else {
            return false
        }

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.dashboardReadinessScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw Self.enrichedJavaScriptError(from: error)
        }

        guard let result = rawResult as? [String: Any],
              let isReady = result["ready"] as? Bool else {
            return false
        }

        return isReady
    }

    private func logVisibleDashboardClockButtons() async {
        let href = (try? await currentURLString()) ?? "URL desconocida"
        guard href.isFactorialDashboardURL else {
            logStore?.warning("No puedo inspeccionar botones: no estoy en dashboard. URL actual: \(href)", source: "Fichaje")
            return
        }

        await logVisibleDashboardClockButton(.clockIn)
        await logVisibleDashboardClockButton(.clockOut)
    }

    private func logVisibleDashboardClockButton(_ kind: ClockEventKind) async {
        do {
            let state = try await visibleClockButtonState(kind)
            if state.ok {
                logStore?.info("Veo el boton de \(kind.visibleButtonLogName)", source: "Fichaje")
            } else {
                let details = state.message ?? "Sin detalle adicional."
                let message = "No veo el boton de \(kind.visibleButtonLogName). \(details)"
                logStore?.warning(message, source: "Fichaje")
            }
        } catch {
            logStore?.warning(
                "Error buscando el boton de \(kind.visibleButtonLogName): \(error.localizedDescription)",
                source: "Fichaje"
            )
        }
    }

    private func clockUsingFactorialUI(_ kind: ClockEventKind) async throws -> Bool {
        let rawResult: Any?
        do {
            rawResult = try await callVisibleClockButtonScript(kind)
        } catch {
            guard Self.isJavaScriptCompletionHandlerLost(error) else {
                throw Self.enrichedJavaScriptError(from: error)
            }

            logStore?.warning("La pagina cambio durante el fichaje visible. Reintentando...", source: "Fichaje")
            try await openDashboardBeforeVisibleClocking(kind)
            do {
                rawResult = try await callVisibleClockButtonScript(kind)
            } catch {
                throw Self.enrichedJavaScriptError(from: error)
            }
        }

        guard let result = rawResult as? [String: Any],
              let ok = result["ok"] as? Bool else {
            throw FactorialClockingError.invalidResult
        }

        if ok {
            try await verifyVisibleClockState(kind, reloadDashboard: false)
        }

        return ok
    }

    private func verifyVisibleClockState(_ kind: ClockEventKind, reloadDashboard: Bool) async throws {
        logStore?.info("Verificando estado visible de \(kind.title.lowercased())", source: "Fichaje")

        let initialHref = try await currentURLString()
        if reloadDashboard || !initialHref.isFactorialDashboardURL {
            try await refreshDashboardFromOrigin(reason: "Recargando dashboard para confirmar \(kind.title.lowercased())")
        }

        var lastMessage: String?
        var didReloadDashboard = reloadDashboard

        for tick in 0..<80 {
            let href = try await currentURLString()
            if href.isFactorialLoginURL {
                authState = .loginRequired
                throw FactorialClockingError.notAuthenticated
            }

            if href.isFactorialDashboardURL {
                let readyState = (try? await webView.evaluateJavaScript("document.readyState")) as? String
                let isReady = readyState == "interactive" || readyState == "complete"

                if isReady {
                    let rawResult: Any?
                    do {
                        rawResult = try await webView.callAsyncJavaScript(
                            Self.visibleClockStateScript(kind: kind),
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

                    if ok {
                        switch kind {
                        case .clockIn:
                            logStore?.info("Veo el boton de salida", source: "Fichaje")
                        case .clockOut:
                            logStore?.info("Veo el boton de fichaje", source: "Fichaje")
                        }
                        return
                    }

                    lastMessage = result["message"] as? String
                }
            }

            if !didReloadDashboard, tick == 30 {
                try await refreshDashboardFromOrigin(reason: "Recargando dashboard para reintentar confirmacion")
                didReloadDashboard = true
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        let fallbackMessage = "No se pudo confirmar en Factorial que \(kind.confirmedStateDescription)."
        throw FactorialClockingError.graphqlError(lastMessage ?? fallbackMessage)
    }

    private func hasVisibleClockButton(_ kind: ClockEventKind) async throws -> Bool {
        let state = try await visibleClockButtonState(kind)
        return state.ok
    }

    private func visibleClockButtonState(_ kind: ClockEventKind) async throws -> VisibleClockButtonState {
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.visibleClockButtonScript(kind: kind, shouldClick: false),
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw Self.enrichedJavaScriptError(from: error)
        }

        guard let result = rawResult as? [String: Any],
              let ok = result["ok"] as? Bool else {
            return VisibleClockButtonState(ok: false, message: "Factorial devolvio un estado de boton inesperado.")
        }

        let message = result["message"] as? String
        return VisibleClockButtonState(ok: ok, message: message)
    }

    private func callVisibleClockButtonScript(_ kind: ClockEventKind) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            Self.visibleClockButtonScript(kind: kind, shouldClick: true),
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
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

    private static func isJavaScriptCompletionHandlerLost(_ error: Error) -> Bool {
        let nsError = error as NSError
        let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
        return message.localizedCaseInsensitiveContains("completion handler") &&
            message.localizedCaseInsensitiveContains("no longer reachable")
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

    private func confirmationMissing(from result: [String: Any]) -> Bool {
        result["confirmationMissing"] as? Bool ?? false
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
            logStore?.debug("Proxy desactivado en WebKit", source: "Proxy")
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostPort.host),
            port: NWEndpoint.Port(rawValue: hostPort.port)!
        )

        var proxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        proxyConfiguration.allowFailover = false
        webView.configuration.websiteDataStore.proxyConfigurations = [proxyConfiguration]
        logStore?.debug("Proxy aplicado en WebKit: \(hostPort.host):\(hostPort.port)", source: "Proxy")
    }

    private func prepareChallengeSolverSessionIfNeeded(force: Bool) async throws {
        let settings = appliedChallengeSolverSettings
        guard settings.isEnabled else {
            return
        }

        guard let endpointURL = settings.endpointURL else {
            logStore?.error("El resolvedor local no tiene una URL valida.", source: "Resolvedor")
            throw FactorialClockingError.challengeSolverError("El resolvedor local no tiene una URL valida.")
        }

        let solverKey = "\(settings.api.rawValue)|\(endpointURL.absoluteString)|\(baseURL.absoluteString)"
        if !force, preparedChallengeSolverKey == solverKey {
            return
        }

        logStore?.info("Preparando sesion con \(settings.api.title)", source: "Resolvedor")
        let solution = try await requestChallengeSolver(settings: settings, endpointURL: endpointURL)
        if let userAgent = solution.userAgent, !userAgent.isEmpty {
            webView.customUserAgent = userAgent
            logStore?.debug("User agent aplicado desde el resolvedor", source: "Resolvedor")
        }

        for cookie in solution.cookies {
            guard let httpCookie = cookie.httpCookie(fallbackURL: baseURL) else {
                continue
            }

            await setCookie(httpCookie)
        }

        preparedChallengeSolverKey = solverKey
        logStore?.info("Sesion del resolvedor preparada con \(solution.cookies.count) cookies", source: "Resolvedor")
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

        logStore?.debug("POST \(endpointURL.absoluteString)", source: "Resolvedor")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logStore?.error("El resolvedor local respondio con HTTP \(status).", source: "Resolvedor")
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

    private static let dashboardReadinessScript = """
    const normalize = (value) => (value || "")
      .normalize("NFD")
      .replace(/[\\u0300-\\u036f]/g, "")
      .toLowerCase()
      .replace(/\\s+/g, " ")
      .trim();

    const bodyText = normalize(document.body?.innerText || document.body?.textContent);
    const hasPageText = bodyText.length > 40;
    const hasClockingText = bodyText.includes("fichaje") ||
      bodyText.includes("sin fichar") ||
      bodyText.includes("salida") ||
      bodyText.includes("fichar") ||
      bodyText.includes("clock in") ||
      bodyText.includes("clock out") ||
      bodyText.includes("attendance");

    const hasInteractiveContent = Array.from(document.querySelectorAll("button, a, [role='button']"))
      .some((element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" &&
          style.display !== "none" &&
          rect.width > 0 &&
          rect.height > 0;
      });

    return {
      ready: hasPageText && hasInteractiveContent,
      hasPageText,
      hasClockingText,
      hasInteractiveContent,
      textSample: bodyText.slice(0, 240)
    };
    """

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
          const mutationPayloadName = "\(operationName)" === "ClockIn" ?
            "clockInAttendanceShift" :
            "forgotClockOutAttendanceShift";

          if (payload?.errors?.length) {
            return payload.errors.map((error) => error.message || String(error)).join("\\n");
          }

          const mutationRoot = payload?.data?.attendanceMutations;
          const mutationPayload = mutationRoot?.[mutationPayloadName];
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

        const mutationPayloadName = "\(operationName)" === "ClockIn" ?
          "clockInAttendanceShift" :
          "forgotClockOutAttendanceShift";
        const mutationPayload = payload?.data?.attendanceMutations?.[mutationPayloadName];
        const shift = mutationPayload?.shift || null;
        const clockIn = typeof shift?.clockIn === "string" ? shift.clockIn : "";
        const clockOut = typeof shift?.clockOut === "string" ? shift.clockOut : "";
        const hasClockIn = clockIn.length > 0;
        const hasClockOut = clockOut.length > 0;
        const isConfirmed = "\(operationName)" === "ClockIn" ?
          hasClockIn && !hasClockOut :
          hasClockIn && hasClockOut;

        if (!isConfirmed) {
          return {
            ok: false,
            status: response.status,
            confirmationMissing: true,
            message: "\(kind.missingGraphQLConfirmationMessage)",
            shift
          };
        }

        return { ok: true, status: response.status, clockIn, clockOut };
        """
    }

    private static func visibleClockButtonScript(kind: ClockEventKind, shouldClick: Bool) -> String {
        let expectedLabels = kind.visibleActionLabels
        let clickAction = shouldClick ? "candidate.element.click();" : ""

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

        const isDirectExpectedAction = (text) => {
          if ("\(kind.rawValue)" === "clockIn") {
            return text === "fichar" ||
              text === "entrada" ||
              text.includes("fichar entrada") ||
              text.includes("clock in") ||
              text.includes("check in");
          }

          return text === "salida" ||
            text.includes("fichar salida") ||
            text.includes("clock out") ||
            text.includes("check out");
        };

        const findClockingCard = (button) => {
          let node = button;
          for (let depth = 0; node && depth < 14; depth += 1, node = node.parentElement) {
            const text = normalize(node.innerText || node.textContent);
            if (text.includes("fichaje") || text.includes("attendance")) {
              return node;
            }
          }

          return null;
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
          const directMatch = isDirectExpectedAction(candidate.text);
          const cardText = card ? normalize(card.innerText || card.textContent) : "";
          const matchesExpectedAction = directMatch ||
            expectedLabels.some((label) => cardText.includes(label) || candidate.text.includes(label));

          if (!matchesExpectedAction || (!card && !directMatch)) {
            continue;
          }

          \(clickAction)
          return { ok: true, clicked: \(shouldClick ? "true" : "false") };
        }

        const visibleButtonTexts = candidates
          .map((candidate) => candidate.text)
          .filter(Boolean)
          .slice(0, 12)
          .join(", ");

        return {
          ok: false,
          actionMismatch: candidates.length > 0,
          message: visibleButtonTexts.length > 0 ?
            `No veo el boton esperado. Botones candidatos visibles: ${visibleButtonTexts}` :
            "No veo botones visibles de fichaje o salida."
        };
        """
    }

    private static func visibleClockStateScript(kind: ClockEventKind) -> String {
        let expectedState = kind == .clockIn ? "clockedIn" : "clockedOut"

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

        const textOf = (element) => normalize(
          element.innerText ||
            element.textContent ||
            element.getAttribute("aria-label") ||
            ""
        );

        const interactiveElements = Array.from(document.querySelectorAll("button, a, [role='button']"))
          .filter(isVisible);

        const findClockingCard = (element) => {
          let node = element;
          for (let depth = 0; node && depth < 8; depth += 1, node = node.parentElement) {
            const text = textOf(node);
            if (
              text.includes("fichaje") &&
              (
                text.includes("sin fichar") ||
                text.includes("fichar") ||
                text.includes("salida") ||
                text.includes("clock in") ||
                text.includes("clock out") ||
                text.includes("check in") ||
                text.includes("check out")
              )
            ) {
              return node;
            }
          }

          return null;
        };

        const unique = (values) => {
          const seen = new Set();
          return values.filter((value) => {
            if (!value || seen.has(value)) {
              return false;
            }
            seen.add(value);
            return true;
          });
        };

        const cardsFromButtons = interactiveElements
          .map(findClockingCard)
          .filter(Boolean);

        const cardsFromText = Array.from(document.querySelectorAll("section, article, aside, main, div"))
          .filter(isVisible)
          .filter((element) => {
            const text = textOf(element);
            return text.includes("fichaje") &&
              (
                text.includes("sin fichar") ||
                text.includes("fichar") ||
                text.includes("salida")
              );
          })
          .sort((left, right) => {
            const leftRect = left.getBoundingClientRect();
            const rightRect = right.getBoundingClientRect();
            return (leftRect.width * leftRect.height) - (rightRect.width * rightRect.height);
          })
          .slice(0, 6);

        const cards = unique([...cardsFromButtons, ...cardsFromText]);

        for (const card of cards) {
          const cardText = textOf(card);
          const cardButtons = interactiveElements
            .filter((element) => card.contains(element))
            .map(textOf);
          const hasInactiveText = cardText.includes("sin fichar");
          const hasClockInAction = cardButtons.some((text) =>
            text.includes("fichar") ||
            text.includes("entrada") ||
            text.includes("clock in") ||
            text.includes("check in")
          );
          const hasClockOutAction = cardButtons.some((text) =>
            text.includes("salida") ||
            text.includes("clock out") ||
            text.includes("check out")
          );

          if ("\(expectedState)" === "clockedIn") {
            if (!hasInactiveText && hasClockOutAction) {
              return { ok: true, state: "clockedIn" };
            }
          } else if (hasInactiveText || (hasClockInAction && !hasClockOutAction)) {
            return { ok: true, state: "clockedOut" };
          }
        }

        const pageText = textOf(document.body);
        return {
          ok: false,
          message: "\(kind.visibleConfirmationMissingMessage)",
          sawInactiveText: pageText.includes("sin fichar"),
          sawClockInAction: pageText.includes("fichar"),
          sawClockOutAction: pageText.includes("salida")
        };
        """
    }

    private static let javaScriptConsoleCaptureScript = WKUserScript(
        source: """
        (() => {
          if (window.__factorialMacLogInstalled) {
            return;
          }
          window.__factorialMacLogInstalled = true;

          const handler = window.webkit?.messageHandlers?.factorialAppLog;
          if (!handler) {
            return;
          }

          const stringify = (value) => {
            if (value instanceof Error) {
              return `${value.name}: ${value.message}${value.stack ? `\\n${value.stack}` : ""}`;
            }
            if (typeof value === "string") {
              return value;
            }
            try {
              return JSON.stringify(value);
            } catch {
              return String(value);
            }
          };

          const post = (level, source, values, extra = {}) => {
            try {
              handler.postMessage({
                level,
                source,
                message: values.map(stringify).join(" "),
                url: window.location.href,
                ...extra
              });
            } catch {}
          };

          const levels = {
            debug: "debug",
            log: "info",
            info: "info",
            warn: "warning",
            error: "error"
          };

          Object.keys(levels).forEach((method) => {
            const original = console[method]?.bind(console);
            console[method] = (...values) => {
              post(levels[method], "JavaScript console", values);
              original?.(...values);
            };
          });

          window.addEventListener("error", (event) => {
            post("error", "JavaScript error", [event.message], {
              url: event.filename || window.location.href,
              line: event.lineno,
              column: event.colno
            });
          });

          window.addEventListener("unhandledrejection", (event) => {
            post("error", "JavaScript promise", [event.reason]);
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}

extension FactorialClockingClient: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await refreshAuthState()
        }
    }
}

private extension FactorialAuthState {
    var logTitle: String {
        switch self {
        case .unknown:
            "desconocida"
        case .loginRequired:
            "login requerido"
        case .authenticated:
            "autenticada"
        }
    }
}

private struct VisibleClockButtonState {
    let ok: Bool
    let message: String?
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

    var visibleButtonLogName: String {
        switch self {
        case .clockIn:
            "fichaje"
        case .clockOut:
            "salida"
        }
    }

    var confirmedStateDescription: String {
        switch self {
        case .clockIn:
            "la entrada haya quedado activa"
        case .clockOut:
            "la salida haya quedado registrada"
        }
    }

    var missingGraphQLConfirmationMessage: String {
        switch self {
        case .clockIn:
            "Factorial respondio, pero no devolvio una entrada activa confirmada."
        case .clockOut:
            "Factorial respondio, pero no devolvio una salida confirmada."
        }
    }

    var visibleConfirmationMissingMessage: String {
        switch self {
        case .clockIn:
            "Factorial sigue sin mostrar el estado Fichaje activo."
        case .clockOut:
            "Factorial sigue sin mostrar la salida registrada."
        }
    }
}
