// MenuCloak — hides the app menus (left side of the menu bar) behind an adaptive overlay.
// Right-side status items / clock stay visible. Move the mouse into the covered
// area to reveal the menus; they re-cover when you leave.
//
// Technique (same family as MacTools' notch mask, unlike TopNotch's wallpaper repaint):
// a borderless NSWindow at status-window level, click-through, spanning from
// the left screen edge to the leftmost status item. The cloak uses the native
// macOS 26 black surface and an appearance-adaptive semantic surface elsewhere.
//
// ponytail: primary display only; fullscreen Spaces stay uncovered (menu bar
// auto-hides there anyway). Upgrade path: one overlay per NSScreen.

import AppKit
import Carbon
import CryptoKit
import Darwin
import Foundation
import QuartzCore
import Security
import os.log

enum Fade {
    static let duration: TimeInterval = 0.15

    static func alpha(from: CGFloat, to: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let progress = CGFloat(min(max(elapsed / duration, 0), 1))
        return from + (to - from) * progress
    }
}

enum FocusText {
    static func displayText(_ raw: String) -> String {
        raw.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct CalendarReminder: Equatable {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let meetURL: URL?

    init(title: String, startDate: Date, endDate: Date, location: String? = nil,
         meetURL: URL? = nil) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.meetURL = meetURL
    }
}

enum CalendarLocation {
    static func displayText(eventLocation: String?, resourceNames: [String?]) -> String? {
        let explicitLocation = FocusText.displayText(eventLocation ?? "")
        if !explicitLocation.isEmpty {
            return explicitLocation
        }

        var seen = Set<String>()
        let rooms = resourceNames.compactMap { rawName -> String? in
            let room = FocusText.displayText(rawName ?? "")
            guard !room.isEmpty, seen.insert(room).inserted else { return nil }
            return room
        }
        return rooms.isEmpty ? nil : rooms.joined(separator: ", ")
    }
}

enum CalendarReminderLogic {
    static let leadTime: TimeInterval = 15 * 60
    static let noticeDurationAfterStart: TimeInterval = 3 * 60

    static func activeOrUpcoming(_ reminders: [CalendarReminder], now: Date) -> [CalendarReminder] {
        let horizon = now.addingTimeInterval(leadTime)
        return reminders
            .filter { !$0.title.isEmpty && $0.endDate > now && $0.startDate <= horizon }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    static func visible(_ reminders: [CalendarReminder], now: Date) -> [CalendarReminder] {
        activeOrUpcoming(reminders, now: now).filter {
            $0.startDate.addingTimeInterval(noticeDurationAfterStart) > now
        }
    }

    static func displayText(_ reminders: [CalendarReminder],
                            timeText: (Date) -> String) -> String {
        reminders.map { reminder in
            let locationText = reminder.location.map { " @ \($0)" } ?? ""
            return "\(timeText(reminder.startDate)) \(reminder.title)\(locationText)"
        }.joined(separator: "  ·  ")
    }

    static func meetURL(_ reminders: [CalendarReminder], now: Date) -> URL? {
        activeOrUpcoming(reminders, now: now).compactMap(\.meetURL).first
    }
}

enum GoogleMeetLink {
    static func validated(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "meet.google.com",
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }
}

private struct GoogleCalendarCredentials: Codable, Equatable {
    let clientID: String
    let clientSecret: String?
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case refreshToken = "refresh_token"
    }
}

private struct GoogleOAuthTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private enum GoogleCalendarCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not update Google Calendar login in Keychain (\(detail))"
        }
    }
}

private enum GoogleCalendarCredentialStore {
    static let service = "com.dans.menucloak.google-calendar"
    static let account = "oauth"
    static let ignoreLegacyDefaultsKey = "MenuCloakIgnoreLegacyGoogleCredentials"

    static func load() -> GoogleCalendarCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleCalendarCredentials.self, from: data)
    }

    static func save(_ credentials: GoogleCalendarCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw GoogleCalendarCredentialStoreError.keychain(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleCalendarCredentialStoreError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum GoogleCalendarCredentialSource {
    case keychain
    case legacyFile
}

private enum GoogleCalendarCredentialsLoader {
    static func credentialsURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["MENUCLOAK_GOOGLE_CREDENTIALS"],
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/menucloak/google-calendar.json")
    }

    static func legacyCredentials() -> GoogleCalendarCredentials? {
        guard let data = try? Data(contentsOf: credentialsURL()),
              let credentials = try? JSONDecoder().decode(GoogleCalendarCredentials.self, from: data),
              !credentials.clientID.isEmpty,
              !credentials.refreshToken.isEmpty else { return nil }
        return credentials
    }

    static func load() throws -> (GoogleCalendarCredentials, GoogleCalendarCredentialSource) {
        if let credentials = GoogleCalendarCredentialStore.load() {
            return (credentials, .keychain)
        }
        if !UserDefaults.standard.bool(forKey: GoogleCalendarCredentialStore.ignoreLegacyDefaultsKey),
           let credentials = legacyCredentials() {
            return (credentials, .legacyFile)
        }
        throw GoogleCalendarClientError.missingCredentials(credentialsURL().path)
    }

    static func oauthClientID() -> String? {
        if let configured = ProcessInfo.processInfo.environment["MENUCLOAK_GOOGLE_CLIENT_ID"],
           !configured.isEmpty { return configured }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "MenuCloakGoogleClientID") as? String,
           !bundled.isEmpty { return bundled }
        return nil
    }

    static func oauthClientSecret() -> String? {
        if let configured = ProcessInfo.processInfo.environment["MENUCLOAK_GOOGLE_CLIENT_SECRET"],
           !configured.isEmpty { return configured }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "MenuCloakGoogleClientSecret") as? String,
           !bundled.isEmpty { return bundled }
        return nil
    }
}

private enum GoogleCalendarConnectionState: Equatable {
    case disconnected
    case connecting
    case validating
    case connected
    case connectedLegacy
    case error(String)
}

private enum GoogleOAuthError: LocalizedError {
    case missingClientID
    case listener
    case cancelled
    case invalidCallback
    case stateMismatch
    case denied(String)
    case missingRefreshToken
    case missingScope
    case malformedResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "This build is missing its Google OAuth client ID"
        case .listener:
            return "MenuCloak could not start the local Google sign-in callback"
        case .cancelled:
            return "Google Calendar sign-in was cancelled"
        case .invalidCallback:
            return "Google returned an invalid sign-in callback"
        case .stateMismatch:
            return "Google sign-in could not be verified; please try again"
        case .denied(let reason):
            return reason == "access_denied"
                ? "Google Calendar access was not granted"
                : "Google sign-in failed (\(reason))"
        case .missingRefreshToken:
            return "Google did not return a reusable login; please try again"
        case .missingScope:
            return "Google Calendar read access was not granted"
        case .malformedResponse:
            return "Google returned an unreadable sign-in response"
        case .http(let status, let detail):
            return detail.isEmpty
                ? "Google sign-in failed with HTTP \(status)"
                : "Google sign-in failed: \(detail)"
        }
    }
}

private enum GoogleOAuthPKCE {
    static func randomURLSafeString(byteCount: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class GoogleOAuthLoopbackServer {
    private static let maximumRequestSize = 16_384
    private let queue = DispatchQueue(label: "com.dans.menucloak.google-oauth-loopback")
    private var listenerFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var completion: ((Result<URL, Error>) -> Void)?

    deinit { cancel() }

    func start(completion: @escaping (Result<URL, Error>) -> Void) throws -> URL {
        let listenerFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw GoogleOAuthError.listener }

        var reuse: Int32 = 1
        setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(listenerFD, 1) == 0 else {
            Darwin.close(listenerFD)
            throw GoogleOAuthError.listener
        }

        var actualAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actualAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenerFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listenerFD)
            throw GoogleOAuthError.listener
        }
        let port = UInt16(bigEndian: actualAddress.sin_port)
        guard let redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2callback") else {
            Darwin.close(listenerFD)
            throw GoogleOAuthError.listener
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptCallback() }
        source.setCancelHandler { Darwin.close(listenerFD) }
        queue.sync {
            self.listenerFD = listenerFD
            self.completion = completion
            self.source = source
        }
        source.resume()
        return redirectURL
    }

    func cancel() {
        queue.sync {
            completion = nil
            listenerFD = -1
            source?.cancel()
            source = nil
        }
    }

    private func acceptCallback() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(from: clientFD),
              let firstLine = request.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET "),
              let path = firstLine.split(separator: " ", maxSplits: 2).dropFirst().first,
              let callbackURL = URL(string: "http://127.0.0.1\(path)") else {
            respond(clientFD, success: false)
            complete(.failure(GoogleOAuthError.invalidCallback))
            return
        }
        respond(clientFD, success: true)
        complete(.success(callbackURL))
    }

    private func readRequest(from clientFD: Int32) -> String? {
        var requestData = Data()
        let headerTerminator = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while requestData.count < Self.maximumRequestSize {
            let remaining = Self.maximumRequestSize - requestData.count
            let count = recv(clientFD, &buffer, min(buffer.count, remaining), 0)
            guard count > 0 else { return nil }
            requestData.append(buffer, count: count)
            if requestData.range(of: headerTerminator) != nil {
                return String(data: requestData, encoding: .utf8)
            }
        }
        return nil
    }

    private func respond(_ clientFD: Int32, success: Bool) {
        let message = success
            ? "Google sign-in returned to MenuCloak. You can close this tab and return to the app."
            : "Google Calendar sign-in failed. Return to MenuCloak and try again."
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>MenuCloak</title></head>
        <body style="font:16px -apple-system;padding:48px;background:#111;color:#fff">
        <h1 style="font-size:24px">MenuCloak</h1><p>\(message)</p></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { send(clientFD, $0, strlen($0), 0) }
    }

    private func complete(_ result: Result<URL, Error>) {
        let callback = completion
        completion = nil
        listenerFD = -1
        source?.cancel()
        source = nil
        DispatchQueue.main.async { callback?(result) }
    }
}

private final class GoogleOAuthController {
    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"

    private let session = URLSession(configuration: .ephemeral)
    private var server: GoogleOAuthLoopbackServer?
    private var timeout: DispatchWorkItem?
    private var tokenTask: URLSessionDataTask?
    private var attemptID: UUID?
    private var completion: ((Result<GoogleCalendarCredentials, Error>) -> Void)?

    deinit {
        cancel(silently: true)
        session.invalidateAndCancel()
    }

    func connect(completion: @escaping (Result<GoogleCalendarCredentials, Error>) -> Void) {
        cancel(silently: true)
        guard let clientID = GoogleCalendarCredentialsLoader.oauthClientID() else {
            completion(.failure(GoogleOAuthError.missingClientID))
            return
        }
        let clientSecret = GoogleCalendarCredentialsLoader.oauthClientSecret()
        guard let verifier = GoogleOAuthPKCE.randomURLSafeString(byteCount: 48),
              let state = GoogleOAuthPKCE.randomURLSafeString(byteCount: 24) else {
            completion(.failure(GoogleOAuthError.listener))
            return
        }

        let attemptID = UUID()
        self.attemptID = attemptID
        self.completion = completion
        let server = GoogleOAuthLoopbackServer()
        do {
            var redirectURL: URL!
            redirectURL = try server.start { [weak self] result in
                self?.handleCallback(result, clientID: clientID, clientSecret: clientSecret,
                                     verifier: verifier,
                                     state: state, redirectURL: redirectURL,
                                     attemptID: attemptID)
            }
            self.server = server
            guard let authorizationURL = Self.authorizationURL(
                clientID: clientID,
                redirectURL: redirectURL,
                state: state,
                challenge: GoogleOAuthPKCE.challenge(for: verifier)
            ) else {
                finish(.failure(GoogleOAuthError.malformedResponse), attemptID: attemptID)
                return
            }
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(GoogleOAuthError.cancelled), attemptID: attemptID)
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: timeout)
            if !NSWorkspace.shared.open(authorizationURL) {
                finish(.failure(GoogleOAuthError.cancelled), attemptID: attemptID)
            }
        } catch {
            finish(.failure(error), attemptID: attemptID)
        }
    }

    func cancel(silently: Bool = false) {
        guard completion != nil || server != nil else { return }
        if silently {
            timeout?.cancel()
            timeout = nil
            tokenTask?.cancel()
            tokenTask = nil
            server?.cancel()
            server = nil
            attemptID = nil
            completion = nil
        } else {
            guard let attemptID else { return }
            finish(.failure(GoogleOAuthError.cancelled), attemptID: attemptID)
        }
    }

    static func authorizationURL(clientID: String, redirectURL: URL,
                                 state: String, challenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: calendarScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    static func uniqueQueryValues(_ queryItems: [URLQueryItem]?) -> [String: String]? {
        var values: [String: String] = [:]
        for item in queryItems ?? [] {
            guard values[item.name] == nil else { return nil }
            values[item.name] = item.value ?? ""
        }
        return values
    }

    private func handleCallback(_ result: Result<URL, Error>, clientID: String,
                                clientSecret: String?,
                                verifier: String, state: String, redirectURL: URL,
                                attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        switch result {
        case .failure(let error):
            finish(.failure(error), attemptID: attemptID)
        case .success(let url):
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                finish(.failure(GoogleOAuthError.invalidCallback), attemptID: attemptID)
                return
            }
            guard let values = Self.uniqueQueryValues(components.queryItems) else {
                finish(.failure(GoogleOAuthError.invalidCallback), attemptID: attemptID)
                return
            }
            guard values["state"] == state else {
                finish(.failure(GoogleOAuthError.stateMismatch), attemptID: attemptID)
                return
            }
            if let error = values["error"], !error.isEmpty {
                finish(.failure(GoogleOAuthError.denied(error)), attemptID: attemptID)
                return
            }
            guard let code = values["code"], !code.isEmpty else {
                finish(.failure(GoogleOAuthError.invalidCallback), attemptID: attemptID)
                return
            }
            exchange(code: code, clientID: clientID, clientSecret: clientSecret,
                     verifier: verifier,
                     redirectURL: redirectURL, attemptID: attemptID)
        }
    }

    static func tokenExchangeQueryItems(code: String, clientID: String,
                                        clientSecret: String?, verifier: String,
                                        redirectURL: URL) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString)
        ]
        if let clientSecret, !clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        return items
    }

    private func exchange(code: String, clientID: String, clientSecret: String?,
                          verifier: String,
                          redirectURL: URL, attemptID: UUID) {
        var form = URLComponents()
        form.queryItems = Self.tokenExchangeQueryItems(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            verifier: verifier,
            redirectURL: redirectURL
        )
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.attemptID == attemptID else { return }
                self.tokenTask = nil
                if let error {
                    self.finish(.failure(error), attemptID: attemptID)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.finish(.failure(GoogleOAuthError.malformedResponse), attemptID: attemptID)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let detail = data.flatMap {
                        (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["error_description"] as? String
                    } ?? ""
                    self.finish(.failure(GoogleOAuthError.http(http.statusCode, detail)),
                                attemptID: attemptID)
                    return
                }
                guard let data,
                      let token = try? JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data),
                      let refreshToken = token.refreshToken,
                      !refreshToken.isEmpty else {
                    self.finish(.failure(GoogleOAuthError.missingRefreshToken), attemptID: attemptID)
                    return
                }
                let scopes = Set((token.scope ?? "").split(separator: " ").map(String.init))
                guard scopes.contains(Self.calendarScope) else {
                    self.finish(.failure(GoogleOAuthError.missingScope), attemptID: attemptID)
                    return
                }
                self.finish(.success(GoogleCalendarCredentials(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    refreshToken: refreshToken
                )), attemptID: attemptID)
            }
        }
        tokenTask = task
        task.resume()
    }

    private func finish(_ result: Result<GoogleCalendarCredentials, Error>, attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        timeout?.cancel()
        timeout = nil
        tokenTask?.cancel()
        tokenTask = nil
        server?.cancel()
        server = nil
        let callback = completion
        completion = nil
        self.attemptID = nil
        callback?(result)
    }
}

private struct GoogleCalendarEventList: Decodable {
    let items: [GoogleCalendarEvent]?
}

private struct GoogleCalendarEvent: Decodable {
    struct DateValue: Decodable {
        let dateTime: String?
    }

    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        let displayName: String?
        let resource: Bool?

        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
            case displayName
            case resource
        }
    }

    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }

        let entryPoints: [EntryPoint]?
    }

    let id: String
    let summary: String?
    let location: String?
    let status: String?
    let start: DateValue
    let end: DateValue
    let attendees: [Attendee]?
    let hangoutLink: String?
    let conferenceData: ConferenceData?
}

private enum GoogleCalendarClientError: LocalizedError {
    case missingCredentials(String)
    case invalidCredentials
    case malformedResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let path):
            return "Google Calendar credentials not found at \(path)"
        case .invalidCredentials:
            return "Google Calendar credentials are incomplete"
        case .malformedResponse:
            return "Google Calendar returned an unreadable response"
        case .http(let status):
            return "Google Calendar request failed with HTTP \(status)"
        }
    }
}

private final class CalendarMonitor {
    var onChange: (([CalendarReminder]) -> Void)?
    var onConnectionStateChange: ((GoogleCalendarConnectionState) -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?
    private var isLoading = false
    private var refreshAfterLoad = false
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var lastFetchedReminders: [CalendarReminder] = []
    private var lastLoggedError = ""
    private var didLogConnection = false
    private var credentialGeneration = 0
    private(set) var connectionState: GoogleCalendarConnectionState = .disconnected {
        didSet {
            guard oldValue != connectionState else { return }
            onConnectionStateChange?(connectionState)
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit {
        timer?.invalidate()
        session.invalidateAndCancel()
    }

    func credentialsDidChange() {
        credentialGeneration += 1
        accessToken = nil
        accessTokenExpiry = .distantPast
        lastFetchedReminders = []
        didLogConnection = false
        refresh()
    }

    func setConnecting() {
        connectionState = .connecting
    }

    func setConnectionError(_ error: Error) {
        connectionState = .error(error.localizedDescription)
    }

    private func refresh() {
        let now = Date()
        onChange?(CalendarReminderLogic.activeOrUpcoming(lastFetchedReminders, now: now))
        if isLoading {
            refreshAfterLoad = true
            return
        }
        isLoading = true
        do {
            let (credentials, source) = try GoogleCalendarCredentialsLoader.load()
            let generation = credentialGeneration
            if connectionState != .connected && connectionState != .connectedLegacy {
                connectionState = .validating
            }
            ensureAccessToken(credentials: credentials, generation: generation) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let token):
                    self.fetchEvents(token: token, credentials: credentials, source: source,
                                     generation: generation, now: now, canRetry: true)
                case .failure(let error):
                    self.finish(error: error)
                }
            }
        } catch GoogleCalendarClientError.missingCredentials {
            connectionState = .disconnected
            lastFetchedReminders = []
            onChange?([])
            finishLoading()
        } catch {
            finish(error: error)
        }
    }

    private func ensureAccessToken(credentials: GoogleCalendarCredentials,
                                   generation: Int,
                                   completion: @escaping (Result<String, Error>) -> Void) {
        if let accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 {
            completion(.success(accessToken))
            return
        }

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        if let clientSecret = credentials.clientSecret, !clientSecret.isEmpty {
            form.queryItems?.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.credentialGeneration else {
                    self.finishLoading()
                    return
                }
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(GoogleCalendarClientError.malformedResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(GoogleCalendarClientError.http(http.statusCode)))
                    return
                }
                guard let data,
                      let token = try? JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data),
                      !token.accessToken.isEmpty else {
                    completion(.failure(GoogleCalendarClientError.malformedResponse))
                    return
                }
                self.accessToken = token.accessToken
                self.accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
                completion(.success(token.accessToken))
            }
        }.resume()
    }

    private func fetchEvents(token: String, credentials: GoogleCalendarCredentials,
                             source: GoogleCalendarCredentialSource,
                             generation: Int,
                             now: Date, canRetry: Bool) {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339(now.addingTimeInterval(-24 * 60 * 60))),
            // Google treats timeMax as exclusive; fetch one extra second so an event
            // exactly 15 minutes away survives the local inclusive boundary check.
            URLQueryItem(name: "timeMax", value: Self.rfc3339(
                now.addingTimeInterval(CalendarReminderLogic.leadTime + 1)
            )),
            URLQueryItem(name: "timeZone", value: TimeZone.current.identifier),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "2500")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.credentialGeneration else {
                    self.finishLoading()
                    return
                }
                if let error {
                    self.finish(error: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.finish(error: GoogleCalendarClientError.malformedResponse)
                    return
                }
                if http.statusCode == 401, canRetry {
                    self.accessToken = nil
                    self.accessTokenExpiry = .distantPast
                    self.ensureAccessToken(credentials: credentials, generation: generation) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success(let refreshedToken):
                            self.fetchEvents(token: refreshedToken, credentials: credentials,
                                             source: source, generation: generation,
                                             now: now, canRetry: false)
                        case .failure(let error):
                            self.finish(error: error)
                        }
                    }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    self.finish(error: GoogleCalendarClientError.http(http.statusCode))
                    return
                }
                guard let data,
                      let list = try? JSONDecoder().decode(GoogleCalendarEventList.self, from: data) else {
                    self.finish(error: GoogleCalendarClientError.malformedResponse)
                    return
                }
                self.finish(reminders: self.reminders(from: list.items ?? [], now: now),
                            source: source)
            }
        }.resume()
    }

    private func reminders(from events: [GoogleCalendarEvent], now: Date) -> [CalendarReminder] {
        var seen = Set<String>()
        let reminders = events.compactMap { event -> CalendarReminder? in
            guard event.status != "cancelled",
                  event.attendees?.contains(where: {
                      $0.isSelf == true && $0.responseStatus == "declined"
                  }) != true,
                  let startText = event.start.dateTime,
                  let endText = event.end.dateTime,
                  let startDate = Self.date(fromRFC3339: startText),
                  let endDate = Self.date(fromRFC3339: endText),
                  endDate > now,
                  startDate <= now.addingTimeInterval(CalendarReminderLogic.leadTime) else {
                return nil
            }
            let title = FocusText.displayText(event.summary ?? "")
            guard !title.isEmpty else { return nil }
            let key = "\(event.id)|\(startDate.timeIntervalSinceReferenceDate)"
            guard seen.insert(key).inserted else { return nil }
            let conferenceURL = event.conferenceData?.entryPoints?
                .first(where: { $0.entryPointType == "video" })
                .flatMap { GoogleMeetLink.validated($0.uri) }
            let meetURL = conferenceURL ?? GoogleMeetLink.validated(event.hangoutLink)
            let resourceNames = event.attendees?
                .filter { $0.resource == true }
                .map(\.displayName) ?? []
            let location = CalendarLocation.displayText(eventLocation: event.location,
                                                        resourceNames: resourceNames)
            return CalendarReminder(title: title, startDate: startDate, endDate: endDate,
                                    location: location, meetURL: meetURL)
        }
        return CalendarReminderLogic.activeOrUpcoming(reminders, now: now)
    }

    private func finish(reminders: [CalendarReminder], source: GoogleCalendarCredentialSource) {
        lastFetchedReminders = reminders
        lastLoggedError = ""
        connectionState = source == .keychain ? .connected : .connectedLegacy
        if !didLogConnection {
            NSLog("MenuCloak Google Calendar: connected")
            didLogConnection = true
        }
        onChange?(CalendarReminderLogic.activeOrUpcoming(reminders, now: Date()))
        finishLoading()
    }

    private func finish(error: Error) {
        let message = error.localizedDescription
        connectionState = .error(message)
        if message != lastLoggedError {
            NSLog("MenuCloak Google Calendar: %@", message)
            lastLoggedError = message
        }
        finishLoading()
    }

    private func finishLoading() {
        isLoading = false
        if refreshAfterLoad {
            refreshAfterLoad = false
            refresh()
        }
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func date(fromRFC3339 value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else { return nil }

        var registeredRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D436C6B), id: 1) // MClk
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &registeredRef
        )
        guard registerStatus == noErr, let registeredRef else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            return nil
        }
        hotKeyRef = registeredRef
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

enum CloakColorScheme: Equatable {
    case light
    case dark
}

enum CloakMenuBarSurface: Equatable {
    case black
    case appearanceAdaptive
}

struct CloakAppearanceInputs: Equatable {
    let colorScheme: CloakColorScheme
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let menuBarSurface: CloakMenuBarSurface
}

struct CloakAppearanceStyle: Equatable {
    let colorScheme: CloakColorScheme
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let textOpacity: CGFloat
}

enum CloakAppearance {
    private static func accessibleMenuBarBackground(
        colorScheme: CloakColorScheme,
        increaseContrast: Bool
    ) -> NSColor {
        // macOS 26 replaces the normal black Liquid Glass menu bar with an
        // opaque neutral surface when Reduce Transparency is enabled. These
        // are the compositor's observed sRGB values; Clear/Tinted glass and
        // desktop tinting do not change them in accessibility mode.
        let component: CGFloat
        switch (colorScheme, increaseContrast) {
        case (.light, false): component = 218 / 255
        case (.light, true): component = 230 / 255
        case (.dark, false): component = 32 / 255
        case (.dark, true): component = 45 / 255
        }
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }

    static func colorScheme(for appearance: NSAppearance) -> CloakColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    static func menuBarSurface(for version: OperatingSystemVersion) -> CloakMenuBarSurface {
        // macOS 26's normal Liquid Glass menu bar is a solid black surface in
        // both appearances; resolve() handles its opaque accessibility variants.
        // Other releases use the semantic fallback until verified.
        version.majorVersion == 26 ? .black : .appearanceAdaptive
    }

    static func resolve(_ inputs: CloakAppearanceInputs) -> CloakAppearanceStyle {
        if inputs.menuBarSurface == .black {
            let usesAccessibleSurface = inputs.reduceTransparency || inputs.increaseContrast
            return CloakAppearanceStyle(
                colorScheme: inputs.colorScheme,
                backgroundColor: usesAccessibleSurface
                    ? accessibleMenuBarBackground(
                        colorScheme: inputs.colorScheme,
                        increaseContrast: inputs.increaseContrast
                    )
                    : .black,
                foregroundColor: usesAccessibleSurface ? .labelColor : .selectedMenuItemTextColor,
                textOpacity: inputs.increaseContrast ? 1 : 0.92
            )
        }
        return CloakAppearanceStyle(
            colorScheme: inputs.colorScheme,
            // An opaque semantic surface is intentional: effect materials
            // tested here left seams or exposed the menu labels beneath them.
            backgroundColor: .windowBackgroundColor,
            foregroundColor: .labelColor,
            textOpacity: inputs.increaseContrast ? 1 : 0.92
        )
    }
}

final class CloakBackgroundView: NSVisualEffectView {
    var onEffectiveAppearanceChange: (() -> Void)?
    private let backgroundLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        state = .inactive
        wantsLayer = true
        layer?.addSublayer(backgroundLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    func apply(_ style: CloakAppearanceStyle) {
        var resolvedBackground = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedBackground = style.backgroundColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.backgroundColor = resolvedBackground
        CATransaction.commit()
    }
}

final class OverlayTextView: NSView {
    var text = "" {
        didSet {
            needsDisplay = true
            setAccessibilityValue(text)
        }
    }
    var showsAttentionSignal = false {
        didSet {
            guard showsAttentionSignal != oldValue else { return }
            updatePulsing()
            needsDisplay = true
        }
    }
    var textOpacity: CGFloat = 0.92 {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }
    private let signalLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        signalLayer.backgroundColor = NSColor.systemOrange.cgColor
        signalLayer.cornerRadius = 3
        signalLayer.isHidden = true
        layer?.addSublayer(signalLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("MenuCloak focus")
    }

    func refreshSemanticColors() {
        var signalColor = NSColor.systemOrange.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            signalColor = NSColor.systemOrange.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        signalLayer.backgroundColor = signalColor
        CATransaction.commit()
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let diameter: CGFloat = 6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        signalLayer.frame = CGRect(x: 0, y: floor((bounds.height - diameter) / 2),
                                   width: diameter, height: diameter)
        CATransaction.commit()
    }

    private func updatePulsing() {
        signalLayer.removeAnimation(forKey: "attentionPulse")
        signalLayer.opacity = 1
        signalLayer.isHidden = !showsAttentionSignal
        guard showsAttentionSignal else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.18
        pulse.duration = 1.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        signalLayer.add(pulse, forKey: "attentionPulse")
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributedText = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: textColor.withAlphaComponent(textOpacity),
            .paragraphStyle: paragraph,
        ])
        let textHeight = ceil(attributedText.boundingRect(
            with: .init(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let signalSpace: CGFloat = showsAttentionSignal ? 14 : 0
        let textRect = NSRect(x: signalSpace, y: floor((bounds.height - textHeight) / 2),
                              width: max(bounds.width - signalSpace, 0), height: textHeight)
        attributedText.draw(with: textRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

enum MenuCloakURLAction: Equatable {
    case toggle
    case turnOn
    case turnOff
    case openSettings
    case setFocus(String)

    static func parse(_ url: URL) -> MenuCloakURLAction? {
        guard url.scheme?.lowercased() == "menucloak" else { return nil }
        switch url.host?.lowercased() {
        case "toggle": return .toggle
        case "on": return .turnOn
        case "off": return .turnOff
        case "settings": return .openSettings
        case "set":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            return .setFocus(text)
        default: return nil
        }
    }
}

enum LegacyOneThing {
    // Raycast's Cache journal maps a key to the opaque file that stores its value:
    // `onething <filename> <byte-count>`.
    static func cacheFilename(inJournal journal: String) -> String? {
        for line in journal.split(whereSeparator: \Character.isNewline).reversed() {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2, fields[0] == "onething" else { continue }
            let filename = String(fields[1])
            guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else { continue }
            return filename
        }
        return nil
    }

}

enum MenuBarIcon {
    static func make() -> NSImage {
        let url = Bundle.main.url(
            forResource: "MenuCloakMenuTemplate",
            withExtension: "png"
        )
        let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: .init(width: 18, height: 18))
        image.size = .init(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "MenuCloak"
        return image
    }
}

final class LegacyOneThingStore {
    private let fileManager = FileManager.default
    private var valueURL: URL?

    func read() -> String? {
        if valueURL == nil || !fileManager.fileExists(atPath: valueURL!.path) {
            valueURL = discoverValueURL()
        }
        guard let url = valueURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = FocusText.displayText(raw)
        return text.isEmpty ? nil : text
    }

    private func discoverValueURL() -> URL? {
        let extensions = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.raycast.macos/extensions", isDirectory: true)
        guard let extensionDirs = try? fileManager.contentsOfDirectory(
            at: extensions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(date: Date, url: URL)] = []
        for extensionDir in extensionDirs {
            let cacheDir = extensionDir.appendingPathComponent("com.raycast.api.cache", isDirectory: true)
            let journalURL = cacheDir.appendingPathComponent("journal")
            guard let journal = try? String(contentsOf: journalURL, encoding: .utf8),
                  let filename = LegacyOneThing.cacheFilename(inJournal: journal) else { continue }
            let date = (try? journalURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((date, cacheDir.appendingPathComponent(filename)))
        }
        return candidates.max(by: { $0.date < $1.date })?.url
    }
}

final class FocusTextStore {
    private static let textKey = "MenuCloakFocusText"
    private static let legacyMigrationKey = "MenuCloakDidMigrateOneThing"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMigratingLegacyIfNeeded() -> String {
        if let saved = defaults.string(forKey: Self.textKey) {
            return FocusText.displayText(saved)
        }

        guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return "" }
        let imported = LegacyOneThingStore().read() ?? ""
        defaults.set(imported, forKey: Self.textKey)
        defaults.set(true, forKey: Self.legacyMigrationKey)
        return imported
    }

    @discardableResult
    func save(_ raw: String) -> String {
        let text = FocusText.displayText(raw)
        defaults.set(text, forKey: Self.textKey)
        return text
    }
}

// MARK: private CGS/SkyLight — pin the overlay into its own always-shown space
// at an absolute level above the managed desktops, so desktop-switch slide
// animations (which composite managed-space snapshots over normal windows)
// can never occlude it. Precedent: Übersicht, Pock. Symbols verified present
// on this OS via `dyld_info -exports` (CoreGraphics re-exports SLS* as CGS*).
typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate") func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: UnsafeMutableRawPointer?, _ options: CFDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy") func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel") func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int32)
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSRemoveWindowsFromSpaces") func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> CFArray?

enum Geometry {
    // Cover from the left edge up to the leftmost status item; fall back to 60%
    // of the screen when detection returns nothing sane.
    static func coverWidth(statusMinX: CGFloat?, screenWidth: CGFloat) -> CGFloat {
        guard let x = statusMinX, x > 100, x <= screenWidth else { return screenWidth * 0.6 }
        return x
    }

    // Fill the native menu-bar backdrop underneath the right-side status items.
    // Status items live one WindowServer level above this frame, so their icons
    // stay visible while the wallpaper-tinted seam is removed.
    static func statusBackdropFrame(screenFrame: CGRect, coverWidth: CGFloat,
                                    barHeight: CGFloat) -> CGRect {
        let minX = screenFrame.minX + coverWidth
        return CGRect(
            x: minX,
            y: screenFrame.maxY - barHeight,
            width: max(screenFrame.maxX - minX, 0),
            height: barHeight
        )
    }

    // Mouse inside the covered strip (global bottom-left coords), with a little slack.
    static func isInStrip(mouse: CGPoint, screenTopY: CGFloat, barHeight: CGFloat, coverWidth: CGFloat) -> Bool {
        mouse.y >= screenTopY - barHeight - 4 && mouse.x <= coverWidth + 12
    }

    static func isMenuBarBackdrop(frame: CGRect, screenWidth: CGFloat, nativeBarHeight: CGFloat) -> Bool {
        nativeBarHeight > 5 && frame.minY <= 0 && frame.width >= screenWidth - 1
            && abs(frame.height - nativeBarHeight) <= 1
    }

    // A menu-bar dropdown hangs off the bar itself: its top edge sits at the bar's
    // bottom edge (CGWindow bounds count down from the top of the screen, so
    // minY is the distance from the top). A right-click context menu is the same
    // kind of window at the same level, but it is anchored to the cursor, so it
    // starts further down — that gap is the only thing separating the two.
    //
    // Submenus need no rule of their own: macOS keeps the parent dropdown on
    // screen for as long as a submenu is open, so the parent keeps the cover
    // lifted by itself. The old extra allowance scaled with the popup's own
    // height, causing tall context menus to be mistaken for menu-bar dropdowns.
    static func isMenuBarDropdown(frame: CGRect, barHeight: CGFloat, coverWidth: CGFloat) -> Bool {
        frame.minX < coverWidth && frame.minY <= barHeight + 8
    }
}

enum SystemOverview {
    // Mission Control is rendered by Dock in a dedicated full-screen layer.
    // Checking the Dock bundle ID as well as the layer avoids confusing it
    // with normal full-screen app backdrops at other WindowServer levels.
    static let missionControlLayer = 18

    static func isMissionControlWindow(ownerBundleIdentifier: String?, layer: Int?,
                                       frame: CGRect?) -> Bool {
        guard ownerBundleIdentifier == "com.apple.dock",
              layer == missionControlLayer,
              let frame else { return false }
        return frame.minX == 0 && frame.minY == 0 && frame.width > 0 && frame.height > 0
    }
}

// --selftest: the one runnable check for the pure logic.
if CommandLine.arguments.contains("--selftest") {
    let lightAuto = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: false, increaseContrast: false,
        menuBarSurface: .appearanceAdaptive
    ))
    let darkAuto = CloakAppearance.resolve(.init(
        colorScheme: .dark, reduceTransparency: false, increaseContrast: false,
        menuBarSurface: .appearanceAdaptive
    ))
    precondition(lightAuto.colorScheme == .light && darkAuto.colorScheme == .dark)
    precondition(lightAuto.backgroundColor == .windowBackgroundColor)
    precondition(darkAuto.backgroundColor == .windowBackgroundColor)
    precondition(lightAuto.foregroundColor == .labelColor)
    let reducedTransparency = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: true, increaseContrast: false,
        menuBarSurface: .appearanceAdaptive
    ))
    precondition(reducedTransparency.backgroundColor == .windowBackgroundColor)
    precondition(reducedTransparency.textOpacity == 0.92)
    let increasedContrast = CloakAppearance.resolve(.init(
        colorScheme: .dark, reduceTransparency: false, increaseContrast: true,
        menuBarSurface: .appearanceAdaptive
    ))
    precondition(increasedContrast.textOpacity == 1)
    let bothAccessibilityOptions = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: true, increaseContrast: true,
        menuBarSurface: .appearanceAdaptive
    ))
    precondition(bothAccessibilityOptions.textOpacity == 1)
    let tahoeLight = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: false, increaseContrast: false,
        menuBarSurface: .black
    ))
    let tahoeAccessible = CloakAppearance.resolve(.init(
        colorScheme: .dark, reduceTransparency: true, increaseContrast: true,
        menuBarSurface: .black
    ))
    let tahoeLightAccessible = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: true, increaseContrast: true,
        menuBarSurface: .black
    ))
    let tahoeReducedTransparency = CloakAppearance.resolve(.init(
        colorScheme: .dark, reduceTransparency: true, increaseContrast: false,
        menuBarSurface: .black
    ))
    let tahoeLightReducedTransparency = CloakAppearance.resolve(.init(
        colorScheme: .light, reduceTransparency: true, increaseContrast: false,
        menuBarSurface: .black
    ))
    precondition(tahoeLight.backgroundColor == .black)
    precondition(tahoeLight.foregroundColor == .selectedMenuItemTextColor)
    func srgbComponent255(_ color: NSColor) -> Int {
        let srgb = color.usingColorSpace(.sRGB)!
        return Int((srgb.redComponent * 255).rounded())
    }
    precondition(srgbComponent255(tahoeLightReducedTransparency.backgroundColor) == 218)
    precondition(srgbComponent255(tahoeLightAccessible.backgroundColor) == 230)
    precondition(srgbComponent255(tahoeReducedTransparency.backgroundColor) == 32)
    precondition(srgbComponent255(tahoeAccessible.backgroundColor) == 45)
    precondition(tahoeAccessible.foregroundColor == .labelColor)
    precondition(tahoeAccessible.textOpacity == 1)
    precondition(tahoeReducedTransparency.foregroundColor == .labelColor)
    precondition(tahoeReducedTransparency.textOpacity == 0.92)
    precondition(CloakAppearance.menuBarSurface(for: .init(
        majorVersion: 15, minorVersion: 7, patchVersion: 0
    )) == .appearanceAdaptive)
    precondition(CloakAppearance.menuBarSurface(for: .init(
        majorVersion: 26, minorVersion: 0, patchVersion: 0
    )) == .black)
    precondition(CloakAppearance.menuBarSurface(for: .init(
        majorVersion: 27, minorVersion: 0, patchVersion: 0
    )) == .appearanceAdaptive)
    precondition(CloakAppearance.colorScheme(for: NSAppearance(named: .aqua)!) == .light)
    precondition(CloakAppearance.colorScheme(for: NSAppearance(named: .darkAqua)!) == .dark)
    precondition(Geometry.coverWidth(statusMinX: 900, screenWidth: 1512) == 900)
    precondition(Geometry.coverWidth(statusMinX: nil, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.coverWidth(statusMinX: 50, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.statusBackdropFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        coverWidth: 900,
        barHeight: 38
    ) == CGRect(x: 900, y: 944, width: 612, height: 38))
    precondition(Geometry.coverWidth(statusMinX: 2000, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.isInStrip(mouse: .init(x: 100, y: 978), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(!Geometry.isInStrip(mouse: .init(x: 100, y: 500), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(!Geometry.isInStrip(mouse: .init(x: 900, y: 978), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(Geometry.isMenuBarBackdrop(frame: .init(x: 0, y: 0, width: 1352, height: 30),
                                            screenWidth: 1352, nativeBarHeight: 30))
    precondition(!Geometry.isMenuBarBackdrop(frame: .init(x: 0, y: 0, width: 1352, height: 878),
                                             screenWidth: 1352, nativeBarHeight: 30))
    // dropdown flush with the bar reveals; anything anchored lower does not
    precondition(Geometry.isMenuBarDropdown(frame: .init(x: 100, y: 33, width: 111, height: 58), barHeight: 30, coverWidth: 869))
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 676, y: 434, width: 111, height: 58), barHeight: 30, coverWidth: 869))
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 968, y: 30, width: 320, height: 718), barHeight: 30, coverWidth: 869))
    // measured menu-bar dropdown and submenu. The parent remains on screen, so
    // matching the parent alone keeps the cloak revealed while the submenu is open.
    precondition(Geometry.isMenuBarDropdown(frame: .init(x: 29, y: 31, width: 308, height: 388), barHeight: 30, coverWidth: 926))
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 332, y: 208, width: 239, height: 261), barHeight: 30, coverWidth: 926))
    // measured 394pt-tall right-click context menus must never reveal the menu bar
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 301, y: 194, width: 128, height: 394), barHeight: 30, coverWidth: 926))
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 301, y: 314, width: 128, height: 394), barHeight: 30, coverWidth: 926))
    precondition(!Geometry.isMenuBarDropdown(frame: .init(x: 301, y: 445, width: 128, height: 394), barHeight: 30, coverWidth: 926))
    precondition(SystemOverview.isMissionControlWindow(
        ownerBundleIdentifier: "com.apple.dock", layer: 18,
        frame: .init(x: 0, y: 0, width: 1352, height: 878)
    ))
    precondition(!SystemOverview.isMissionControlWindow(
        ownerBundleIdentifier: "com.apple.dock", layer: 20,
        frame: .init(x: 0, y: 0, width: 1352, height: 878)
    ))
    precondition(!SystemOverview.isMissionControlWindow(
        ownerBundleIdentifier: "com.example.app", layer: 18,
        frame: .init(x: 0, y: 0, width: 1352, height: 878)
    ))
    precondition(!SystemOverview.isMissionControlWindow(
        ownerBundleIdentifier: "com.apple.dock", layer: 18,
        frame: .init(x: 40, y: 40, width: 600, height: 400)
    ))
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0) == 1)
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0.075) == 0.5)
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0.15) == 0)
    precondition(LegacyOneThing.cacheFilename(inJournal: "onething opaque-file 6\n") == "opaque-file")
    precondition(LegacyOneThing.cacheFilename(inJournal: "other abc 1\nonething newest 4\n") == "newest")
    precondition(LegacyOneThing.cacheFilename(inJournal: "onething ../escape 1\n") == nil)
    precondition(FocusText.displayText("  Finish the project  \n today ") == "Finish the project today")
    precondition(CalendarLocation.displayText(eventLocation: "  Room 602 \n East Wing ",
                                              resourceNames: ["Ignored room"])
        == "Room 602 East Wing")
    precondition(CalendarLocation.displayText(eventLocation: nil,
                                              resourceNames: [" Room 601 ", "Room 601", nil,
                                                              "Room 602"])
        == "Room 601, Room 602")
    precondition(CalendarLocation.displayText(eventLocation: "  ", resourceNames: [nil]) == nil)
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let upcoming = CalendarReminder(title: "Design review", startDate: now.addingTimeInterval(15 * 60),
                                    endDate: now.addingTimeInterval(45 * 60))
    let overlapping = CalendarReminder(title: "Team sync", startDate: now.addingTimeInterval(10 * 60),
                                       endDate: now.addingTimeInterval(40 * 60),
                                       location: "Room 602")
    let tooFar = CalendarReminder(title: "Later", startDate: now.addingTimeInterval(15 * 60 + 1),
                                  endDate: now.addingTimeInterval(60 * 60))
    let recentlyStarted = CalendarReminder(title: "In progress",
                                           startDate: now.addingTimeInterval(-3 * 60 + 1),
                                           endDate: now.addingTimeInterval(10 * 60))
    let noticeExpired = CalendarReminder(title: "Still in progress",
                                         startDate: now.addingTimeInterval(-3 * 60),
                                         endDate: now.addingTimeInterval(10 * 60))
    let ended = CalendarReminder(title: "Finished", startDate: now.addingTimeInterval(-30 * 60),
                                 endDate: now)
    let visibleReminders = CalendarReminderLogic.visible([upcoming, tooFar, overlapping], now: now)
    precondition(visibleReminders == [overlapping, upcoming])
    precondition(CalendarReminderLogic.visible([recentlyStarted], now: now) == [recentlyStarted])
    precondition(CalendarReminderLogic.visible([noticeExpired, ended, tooFar], now: now).isEmpty)
    precondition(CalendarReminderLogic.displayText(visibleReminders, timeText: { date in
        date == overlapping.startDate ? "10:10" : "10:15"
    }) == "10:10 Team sync @ Room 602  ·  10:15 Design review")
    let meetURL = URL(string: "https://meet.google.com/abc-defg-hij")!
    let upcomingMeet = CalendarReminder(title: "Meet", startDate: upcoming.startDate,
                                        endDate: upcoming.endDate, meetURL: meetURL)
    let activeMeet = CalendarReminder(title: noticeExpired.title,
                                      startDate: noticeExpired.startDate,
                                      endDate: noticeExpired.endDate, meetURL: meetURL)
    precondition(CalendarReminderLogic.meetURL([overlapping, upcomingMeet], now: now) == meetURL)
    precondition(CalendarReminderLogic.meetURL([activeMeet], now: now) == meetURL)
    precondition(GoogleMeetLink.validated("https://meet.google.com/abc-defg-hij") == meetURL)
    precondition(GoogleMeetLink.validated("http://meet.google.com/abc-defg-hij") == nil)
    precondition(GoogleMeetLink.validated("https://meet.google.com.evil.example/abc") == nil)
    let userInfoURL = "https://user" + "@meet.google.com/abc"
    precondition(GoogleMeetLink.validated(userInfoURL) == nil)
    let verifier = String(repeating: "a", count: 64)
    let challenge = GoogleOAuthPKCE.challenge(for: verifier)
    precondition(challenge.count == 43)
    precondition(!challenge.contains("="))
    let redirect = URL(string: "http://127.0.0.1:54321/oauth2callback")!
    let authorizationURL = GoogleOAuthController.authorizationURL(
        clientID: "test.apps.googleusercontent.com",
        redirectURL: redirect,
        state: "state",
        challenge: challenge
    )!
    let authorizationItems = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        .queryItems ?? []
    let authorizationValues = Dictionary(uniqueKeysWithValues: authorizationItems.map {
        ($0.name, $0.value ?? "")
    })
    precondition(authorizationValues["scope"] == GoogleOAuthController.calendarScope)
    let tokenItems = GoogleOAuthController.tokenExchangeQueryItems(
        code: "code",
        clientID: "client.apps.googleusercontent.com",
        clientSecret: "secret",
        verifier: "verifier",
        redirectURL: URL(string: "http://127.0.0.1:54321/")!
    )
    let tokenValues = GoogleOAuthController.uniqueQueryValues(tokenItems)!
    precondition(tokenValues["client_secret"] == "secret")
    precondition(tokenValues["redirect_uri"] == "http://127.0.0.1:54321/")
    let publicTokenItems = GoogleOAuthController.tokenExchangeQueryItems(
        code: "code",
        clientID: "client.apps.googleusercontent.com",
        clientSecret: nil,
        verifier: "verifier",
        redirectURL: URL(string: "http://127.0.0.1:54321/")!
    )
    precondition(GoogleOAuthController.uniqueQueryValues(publicTokenItems)?["client_secret"] == nil)
    precondition(authorizationValues["redirect_uri"] == redirect.absoluteString)
    precondition(authorizationValues["code_challenge_method"] == "S256")
    precondition(authorizationValues["access_type"] == "offline")
    precondition(authorizationValues["prompt"] == "consent")
    precondition(GoogleOAuthController.uniqueQueryValues([
        URLQueryItem(name: "state", value: "one"),
        URLQueryItem(name: "code", value: "two")
    ]) == ["state": "one", "code": "two"])
    precondition(GoogleOAuthController.uniqueQueryValues([
        URLQueryItem(name: "state", value: "one"),
        URLQueryItem(name: "state", value: "two")
    ]) == nil)
    precondition(GoogleCalendarCredentialsLoader.oauthClientID()?
        .hasSuffix(".apps.googleusercontent.com") == true)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://toggle")!) == .toggle)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://on")!) == .turnOn)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://off")!) == .turnOff)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://settings")!) == .openSettings)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://set?text=Build%20the%20thing")!) == .setFocus("Build the thing"))
    precondition(MenuCloakURLAction.parse(URL(string: "https://example.com")!) == nil)
    precondition(MenuBarIcon.make().isTemplate)
    precondition(MenuBarIcon.make().size == .init(width: 18, height: 18))
    print("selftest ok")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private static let enabledDefaultsKey = "MenuCloakEnabled"
    private var overlay: NSWindow!
    private var statusBackdrop: NSWindow!
    private var cloakBackground: CloakBackgroundView!
    private var statusBackdropBackground: CloakBackgroundView!
    private var focusLabel: OverlayTextView!
    private var statusItem: NSStatusItem!
    private var statusToggleItem: NSMenuItem!
    private var controlWindow: NSWindow?
    private var controlSwitch: NSSwitch?
    private var controlStateLabel: NSTextField?
    private var controlFocusField: NSTextField?
    private var googleCalendarStateLabel: NSTextField?
    private var googleCalendarButton: NSButton?
    private var timer: Timer?
    private var fadeTimer: Timer?
    // cover starts after the Apple-menu capsule so the  stays visible;
    // MENUCLOAK_LEFT overrides (0 = cover it too)
    private let leftInset = CGFloat(Double(ProcessInfo.processInfo.environment["MENUCLOAK_LEFT"] ?? "") ?? 46)
    private var enabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppDelegate.enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: AppDelegate.enabledDefaultsKey)
    }()
    private var covered = false
    private var coverWidth: CGFloat?
    private var menuBarH: CGFloat?
    private var tickCount = 0
    private var missSince: Date?   // when probes started not seeing the menu bar
    private var lastHold = Date.distantPast
    private var missionControlActive = false
    private let focusTextStore = FocusTextStore()
    private var focusText = ""
    private let calendarMonitor = CalendarMonitor()
    private let googleOAuthController = GoogleOAuthController()
    private var calendarReminders: [CalendarReminder] = []
    private var activeCalendarReminders: [CalendarReminder] = []
    private var openMeetHotKey: GlobalHotKey?

    private var screen: NSScreen? { NSScreen.screens.first }

    func applicationDidFinishLaunching(_ note: Notification) {
        let backgroundLaunch = CommandLine.arguments.contains("--background")
        NSApp.setActivationPolicy(backgroundLaunch ? .accessory : .regular)
        makeOverlay()
        makeStatusItem()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAndLayout() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyCloakAppearance() }
        // the instant a desktop switch lands, snap back covered — no fade, no blink
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.refreshAndLayout()
            if !self.missionControlActive, self.menuBarH != nil, self.coverWidth != nil {
                self.setCovered(true, animate: false)
            }
        }
        setFocusText(focusTextStore.loadMigratingLegacyIfNeeded(), persist: false)
        calendarMonitor.onChange = { [weak self] reminders in
            guard let self else { return }
            self.activeCalendarReminders = reminders
            self.setCalendarReminders(CalendarReminderLogic.visible(reminders, now: Date()))
        }
        calendarMonitor.onConnectionStateChange = { [weak self] _ in
            self?.updateGoogleCalendarControl()
        }
        if ProcessInfo.processInfo.environment["MENUCLOAK_DEBUG"] != nil,
           let debugReminderTitle = ProcessInfo.processInfo.environment["MENUCLOAK_DEBUG_REMINDER"],
           !debugReminderTitle.isEmpty {
            let now = Date()
            let reminder = CalendarReminder(
                title: debugReminderTitle,
                startDate: now.addingTimeInterval(10 * 60),
                endDate: now.addingTimeInterval(40 * 60),
                location: "Room 3A",
                meetURL: URL(string: "https://meet.google.com/abc-defg-hij")
            )
            activeCalendarReminders = [reminder]
            setCalendarReminders([reminder])
        } else {
            calendarMonitor.start()
        }
        openMeetHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(cmdKey | controlKey)
        ) { [weak self] in
            self?.openCurrentGoogleMeet()
        }
        if openMeetHotKey == nil {
            os_log("MenuCloak: could not register global shortcut Command-Control-J",
                   type: .error)
        } else {
            os_log("MenuCloak: registered global shortcut Command-Control-J",
                   type: .info)
        }
        refreshAndLayout()
        setCovered(enabled && !missionControlActive, animate: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if !backgroundLaunch { showControlWindow() }
        if ProcessInfo.processInfo.environment["MENUCLOAK_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                let btn = statusItem.button
                FileHandle.standardError.write(Data(
                    ("statusItem visible=\(statusItem.isVisible) length=\(statusItem.length) " +
                     "btnWindow=\(btn?.window?.frame ?? .zero) num=\(btn?.window?.windowNumber ?? -1) " +
                     "img=\(String(describing: btn?.image))\n").utf8))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DispatchQueue.main.async { [weak self] in self?.handle(url) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === controlWindow else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: setup

    private var cgsSpace: CGSSpaceID = 0

    private func makeOverlay() {
        let backdrop = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 24),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)))
        backdrop.backgroundColor = .clear
        backdrop.isOpaque = false
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.alphaValue = 0
        backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let backdropBackground = CloakBackgroundView(frame: backdrop.contentView?.bounds ?? .zero)
        backdropBackground.autoresizingMask = [.width, .height]
        backdrop.contentView = backdropBackground
        backdrop.orderFrontRegardless()

        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 24),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let background = CloakBackgroundView(frame: w.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        let label = OverlayTextView(frame: .zero)
        label.isHidden = true
        background.addSubview(label)
        w.contentView = background
        w.orderFrontRegardless()
        overlay = w
        statusBackdrop = backdrop
        cloakBackground = background
        statusBackdropBackground = backdropBackground
        focusLabel = label
        background.onEffectiveAppearanceChange = { [weak self] in
            self?.applyCloakAppearance()
        }
        applyCloakAppearance()
        bindToPrivateSpace(w)
    }

    private func applyCloakAppearance() {
        guard let cloakBackground, let focusLabel else { return }
        let workspace = NSWorkspace.shared
        let inputs = CloakAppearanceInputs(
            colorScheme: CloakAppearance.colorScheme(for: cloakBackground.effectiveAppearance),
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            menuBarSurface: CloakAppearance.menuBarSurface(
                for: ProcessInfo.processInfo.operatingSystemVersion
            )
        )
        let style = CloakAppearance.resolve(inputs)
        cloakBackground.apply(style)
        statusBackdropBackground.apply(style)
        focusLabel.textColor = style.foregroundColor
        focusLabel.textOpacity = style.textOpacity
        focusLabel.refreshSemanticColors()
    }

    private func bindToPrivateSpace(_ w: NSWindow) {
        let cid = CGSMainConnectionID()
        let space = CGSSpaceCreate(cid, UnsafeMutableRawPointer(bitPattern: 1), nil)
        guard space != 0 else { return }   // fallback: stay a canJoinAllSpaces window
        let levelEnv = ProcessInfo.processInfo.environment["MENUCLOAK_SPACE_LEVEL"]
        let level = Int32(levelEnv ?? "") ?? 100
        CGSSpaceSetAbsoluteLevel(cid, space, level)
        let wins = [CGWindowID(w.windowNumber)] as CFArray
        // move (not copy): pull it out of the managed desktops first, or the
        // slide animation still owns a copy of it
        if let owned = CGSCopySpacesForWindows(cid, 7, wins) as? [CGSSpaceID], !owned.isEmpty {
            CGSRemoveWindowsFromSpaces(cid, wins, owned as CFArray)
        }
        CGSAddWindowsToSpaces(cid, wins, [space] as CFArray)
        CGSShowSpaces(cid, [space] as CFArray)
        w.collectionBehavior = [.stationary, .ignoresCycle]   // AppKit must not re-tag it
        cgsSpace = space
    }

    func applicationWillTerminate(_ notification: Notification) {
        if cgsSpace != 0 { CGSSpaceDestroy(CGSMainConnectionID(), cgsSpace) }
    }

    private func makeStatusItem() {
        // A fixed one-unit slot avoids the extra-wide hover capsule that
        // squareLength can produce when a menu-bar manager is active.
        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        // Separate from the full-color app icon: template images are rendered
        // white on a dark menu bar and black on a light one, matching macOS.
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open MenuCloak…", action: #selector(openControlWindow(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "MenuCloak On", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        statusToggleItem = toggle
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuCloak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openControlWindow(_ sender: Any?) {
        showControlWindow()
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        setEnabled(!enabled)
    }

    @objc private func controlSwitchChanged(_ sender: NSSwitch) {
        setEnabled(sender.state == .on)
    }

    private func setEnabled(_ newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
        statusToggleItem?.state = newValue ? .on : .off
        updateControlState()
        if newValue {
            refreshAndLayout()
            setCovered(!missionControlActive, animate: false)
        } else {
            setCovered(false, animate: false)
            setStatusBackdropVisible(false)
        }
    }

    @objc private func googleCalendarButtonPressed(_ sender: NSButton) {
        switch calendarMonitor.connectionState {
        case .connected, .connectedLegacy:
            googleOAuthController.cancel(silently: true)
            do {
                try GoogleCalendarCredentialStore.delete()
                UserDefaults.standard.set(
                    true,
                    forKey: GoogleCalendarCredentialStore.ignoreLegacyDefaultsKey
                )
                calendarMonitor.credentialsDidChange()
            } catch {
                calendarMonitor.setConnectionError(error)
            }
        case .connecting:
            googleOAuthController.cancel()
            calendarMonitor.credentialsDidChange()
        case .validating:
            return
        case .disconnected, .error:
            calendarMonitor.setConnecting()
            googleOAuthController.connect { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let credentials):
                    do {
                        try GoogleCalendarCredentialStore.save(credentials)
                        UserDefaults.standard.set(
                            true,
                            forKey: GoogleCalendarCredentialStore.ignoreLegacyDefaultsKey
                        )
                        self.calendarMonitor.credentialsDidChange()
                    } catch {
                        self.calendarMonitor.setConnectionError(error)
                    }
                case .failure(let error):
                    self.calendarMonitor.setConnectionError(error)
                }
            }
        }
        updateGoogleCalendarControl()
    }

    private func handle(_ url: URL) {
        guard let action = MenuCloakURLAction.parse(url) else { return }
        switch action {
        case .toggle:
            setEnabled(!enabled)
        case .turnOn:
            setEnabled(true)
        case .turnOff:
            setEnabled(false)
        case .openSettings:
            showControlWindow()
        case let .setFocus(text):
            setFocusText(text, persist: true)
            controlFocusField?.stringValue = focusText
        }
    }

    private func openCurrentGoogleMeet() {
        guard let url = CalendarReminderLogic.meetURL(activeCalendarReminders, now: Date()) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showControlWindow() {
        if controlWindow == nil { makeControlWindow() }
        updateControlState()
        updateGoogleCalendarControl()
        NSApp.setActivationPolicy(.regular)
        controlWindow?.center()
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeControlWindow() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 390, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MenuCloak"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: .init(x: 0, y: 0, width: 390, height: 350))
        window.contentView = content

        let title = NSTextField(labelWithString: "MenuCloak")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = .init(x: 28, y: 297, width: 330, height: 29)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Keep one clear focus in the left side of your menu bar.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.frame = .init(x: 28, y: 264, width: 330, height: 34)
        content.addSubview(detail)

        let focusTitle = NSTextField(labelWithString: "Focus text")
        focusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        focusTitle.frame = .init(x: 28, y: 235, width: 330, height: 20)
        content.addSubview(focusTitle)

        let focusField = NSTextField(frame: .init(x: 28, y: 200, width: 334, height: 28))
        focusField.placeholderString = "What deserves your attention?"
        focusField.stringValue = focusText
        focusField.delegate = self
        focusField.setAccessibilityLabel("Focus text")
        content.addSubview(focusField)
        controlFocusField = focusField

        let toggle = NSSwitch(frame: .init(x: 28, y: 155, width: 42, height: 24))
        toggle.target = self
        toggle.action = #selector(controlSwitchChanged(_:))
        toggle.setAccessibilityLabel("Turn MenuCloak on or off")
        content.addSubview(toggle)
        controlSwitch = toggle

        let state = NSTextField(labelWithString: "")
        state.font = .systemFont(ofSize: 14, weight: .medium)
        state.frame = .init(x: 84, y: 157, width: 275, height: 22)
        content.addSubview(state)
        controlStateLabel = state

        let separator = NSBox(frame: .init(x: 28, y: 132, width: 334, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        let calendarTitle = NSTextField(labelWithString: "Google Calendar")
        calendarTitle.font = .systemFont(ofSize: 13, weight: .medium)
        calendarTitle.frame = .init(x: 28, y: 101, width: 200, height: 20)
        content.addSubview(calendarTitle)

        let calendarState = NSTextField(wrappingLabelWithString: "")
        calendarState.font = .systemFont(ofSize: 12)
        calendarState.textColor = .secondaryLabelColor
        calendarState.frame = .init(x: 28, y: 58, width: 210, height: 38)
        calendarState.setAccessibilityLabel("Google Calendar connection status")
        content.addSubview(calendarState)
        googleCalendarStateLabel = calendarState

        let calendarButton = NSButton(
            title: "Connect…",
            target: self,
            action: #selector(googleCalendarButtonPressed(_:))
        )
        calendarButton.bezelStyle = .rounded
        calendarButton.frame = .init(x: 242, y: 67, width: 120, height: 30)
        calendarButton.setAccessibilityLabel("Connect Google Calendar")
        content.addSubview(calendarButton)
        googleCalendarButton = calendarButton

        let quit = NSButton(title: "Quit MenuCloak", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.frame = .init(x: 242, y: 16, width: 120, height: 30)
        content.addSubview(quit)

        controlWindow = window
    }

    private func updateControlState() {
        controlSwitch?.state = enabled ? .on : .off
        controlStateLabel?.stringValue = enabled
            ? "On — menus are covered"
            : "Off — menus are visible"
    }

    private func updateGoogleCalendarControl() {
        guard let stateLabel = googleCalendarStateLabel,
              let button = googleCalendarButton else { return }
        switch calendarMonitor.connectionState {
        case .disconnected:
            stateLabel.stringValue = "Not connected"
            stateLabel.textColor = .secondaryLabelColor
            button.title = "Connect…"
            button.isEnabled = true
            button.setAccessibilityLabel("Connect Google Calendar")
        case .connecting:
            stateLabel.stringValue = "Waiting for Google sign-in…"
            stateLabel.textColor = .secondaryLabelColor
            button.title = "Cancel"
            button.isEnabled = true
            button.setAccessibilityLabel("Cancel Google Calendar sign-in")
        case .validating:
            stateLabel.stringValue = "Checking connection…"
            stateLabel.textColor = .secondaryLabelColor
            button.title = "Checking…"
            button.isEnabled = false
            button.setAccessibilityLabel("Checking Google Calendar connection")
        case .connected:
            stateLabel.stringValue = "Connected securely with read-only access"
            stateLabel.textColor = .secondaryLabelColor
            button.title = "Disconnect"
            button.isEnabled = true
            button.setAccessibilityLabel("Disconnect Google Calendar")
        case .connectedLegacy:
            stateLabel.stringValue = "Connected using the existing local login"
            stateLabel.textColor = .secondaryLabelColor
            button.title = "Disconnect"
            button.isEnabled = true
            button.setAccessibilityLabel("Disconnect Google Calendar")
        case .error(let message):
            stateLabel.stringValue = message
            stateLabel.textColor = .systemRed
            button.title = "Try Again…"
            button.isEnabled = true
            button.setAccessibilityLabel("Try connecting Google Calendar again")
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === controlFocusField,
              let field = controlFocusField else { return }
        setFocusText(field.stringValue, persist: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === controlFocusField else { return }
        controlFocusField?.stringValue = focusText
    }

    // MARK: window-list probes (no special permissions needed for layer/bounds/pid)

    private func windowInfos() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private func isMissionControlActive(in infos: [[String: Any]]) -> Bool {
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == SystemOverview.missionControlLayer,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            let bundleIdentifier = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            if SystemOverview.isMissionControlWindow(
                ownerBundleIdentifier: bundleIdentifier,
                layer: SystemOverview.missionControlLayer,
                frame: frame
            ) { return true }
        }
        return false
    }

    private func refreshCoverWidth(in infos: [[String: Any]]) {
        guard let s = screen else { coverWidth = nil; menuBarH = nil; return }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let nativeBarH = s.frame.maxY - s.visibleFrame.maxY
        var minX: CGFloat?
        var barH: CGFloat?
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == statusLevel || layer == barLevel,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if layer == barLevel {
                // the menu bar backdrop itself — full width at the top; gives the exact height
                if Geometry.isMenuBarBackdrop(frame: r, screenWidth: s.frame.width,
                                              nativeBarHeight: nativeBarH) { barH = r.height }
                continue
            }
            guard (info[kCGWindowOwnerPID as String] as? Int) != myPID else { continue }
            // status items in the top strip of the primary display only
            guard r.minY < 50, r.minX >= 0, r.maxX <= s.frame.width + 1,
                  r.width > 0, r.width < s.frame.width * 0.8 else { continue }
            minX = min(minX ?? .greatestFiniteMagnitude, r.minX)
        }
        // nil (menu bar / status items not visible) doubles as "fullscreen Space",
        // but it also happens transiently during space-switch animations
        menuBarH = barH
        coverWidth = minX.map { Geometry.coverWidth(statusMinX: $0, screenWidth: s.frame.width) }
        if barH == nil || coverWidth == nil {
            if missSince == nil { missSince = Date() }
        } else {
            missSince = nil
        }
    }

    // only dropdowns hanging off the covered part of the menu bar count —
    // right-click context menus (same window level, but anchored at the cursor)
    // must not lift the cover, and neither must submenus on their own
    private func menuBarMenuOpen(barH: CGFloat, coverWidth: CGFloat) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for info in windowInfos() {
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.05,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if Geometry.isMenuBarDropdown(frame: r, barHeight: barH, coverWidth: coverWidth) { return true }
        }
        return false
    }

    // MARK: layout & state

    private func refreshAndLayout() {
        let infos = windowInfos()
        missionControlActive = isMissionControlActive(in: infos)
        refreshCoverWidth(in: infos)
        guard let s = screen, let cw = coverWidth, let bh = menuBarH, bh > 5 else { return }
        overlay.setFrame(.init(x: s.frame.minX + leftInset, y: s.frame.maxY - bh,
                               width: max(cw - leftInset, 0), height: bh), display: true)
        statusBackdrop.setFrame(
            Geometry.statusBackdropFrame(screenFrame: s.frame, coverWidth: cw, barHeight: bh),
            display: true
        )
        setStatusBackdropVisible(enabled && !missionControlActive)
        layoutFocusText(on: s, barHeight: bh)
    }

    private func setStatusBackdropVisible(_ visible: Bool) {
        statusBackdrop.alphaValue = visible ? 1 : 0
    }

    private func layoutFocusText(on screen: NSScreen, barHeight: CGFloat) {
        let padding: CGFloat = 12
        let overlayFrame = overlay.frame
        // On a notched display, keep the text entirely in the usable top-left area.
        // Without a notch, the label can use the whole cloak.
        let safeMaxX: CGFloat
        if #available(macOS 12.0, *) {
            safeMaxX = screen.auxiliaryTopLeftArea?.maxX ?? overlayFrame.maxX
        } else {
            safeMaxX = overlayFrame.maxX
        }
        let maxX = min(overlayFrame.maxX - padding, safeMaxX - padding)
        let minX = overlayFrame.minX + padding
        focusLabel.frame = .init(
            x: padding,
            y: 0,
            width: max(maxX - minX, 0),
            height: barHeight
        )
    }

    private func setFocusText(_ raw: String, persist: Bool) {
        let text = persist ? focusTextStore.save(raw) : FocusText.displayText(raw)
        guard text != focusText else { return }
        focusText = text
        refreshDisplayedText()
    }

    private func setCalendarReminders(_ reminders: [CalendarReminder]) {
        guard reminders != calendarReminders else { return }
        calendarReminders = reminders
        refreshDisplayedText()
    }

    private func refreshDisplayedText() {
        let reminderText = CalendarReminderLogic.displayText(calendarReminders) {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        }
        let text = reminderText.isEmpty ? focusText : reminderText
        focusLabel.text = text
        focusLabel.toolTip = text.isEmpty ? nil : text
        focusLabel.isHidden = text.isEmpty
        focusLabel.showsAttentionSignal = !reminderText.isEmpty
    }

    private func setCovered(_ on: Bool, animate: Bool) {
        guard covered != on else { return }
        covered = on
        fadeTimer?.invalidate()
        let target: CGFloat = on ? 1 : 0
        guard animate else {
            overlay.alphaValue = target
            return
        }
        let startAlpha = overlay.alphaValue
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(startTime)
            self.overlay.alphaValue = Fade.alpha(from: startAlpha, to: target, elapsed: elapsed)
            if elapsed >= Fade.duration {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard enabled, let s = screen else {
            setCovered(false, animate: false)
            setStatusBackdropVisible(false)
            return
        }
        tickCount += 1
        if tickCount % 10 == 0 {
            setCalendarReminders(CalendarReminderLogic.visible(activeCalendarReminders, now: Date()))
        }
        if tickCount % 3 == 0 {
            refreshAndLayout()
        }   // 0.3s probe cadence
        if missionControlActive {
            setCovered(false, animate: false)
            setStatusBackdropVisible(false)
            return
        }
        guard let bh = menuBarH, bh > 5, let cw = coverWidth else {
            // stay covered through transient probe gaps
            // (space-switch animations flap the window list for ≤0.4s);
            // uncover only when the menu bar stays gone (real fullscreen Space)
            if let m = missSince, Date().timeIntervalSince(m) > 0.8 {
                setCovered(false, animate: false)
                setStatusBackdropVisible(false)
            }
            return
        }
        setStatusBackdropVisible(true)
        // menu-open probe: every tick while revealed, every 0.5s while covered
        // (catches keyboard-opened menus without a 10Hz window-list scan)
        let hold = Geometry.isInStrip(mouse: NSEvent.mouseLocation, screenTopY: s.frame.maxY,
                                      barHeight: bh, coverWidth: cw)
            || ((!covered || tickCount % 5 == 0) && menuBarMenuOpen(barH: bh, coverWidth: cw))
        if hold {
            lastHold = Date()
            setCovered(false, animate: true)
        } else if Date().timeIntervalSince(lastHold) > 0.6 {
            setCovered(true, animate: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
