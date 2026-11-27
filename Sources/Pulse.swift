import AppKit
@preconcurrency import ApplicationServices
import CryptoKit
import Combine
import Charts
import CoreText
import QuartzCore
import Sparkle
import SwiftUI
import UserNotifications

enum PulseType {
    static let displayName: String? = {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        guard let descriptor = descriptors?.first else { return nil }
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }()

    static func display(_ size: CGFloat) -> Font {
        displayName.map { .custom($0, size: size) } ?? .system(size: size, weight: .semibold)
    }
}

struct Bucket: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let remainingFraction: Double
    let resetTime: String?
    var durationMinutes: Double? = nil

    var isSession: Bool { id == "session" || id.hasSuffix("-5h") || durationMinutes == 300 }
    var isWeekly: Bool { id == "weekly" || id.hasSuffix("-weekly") || durationMinutes == 10080 }

    func timeRemaining(at now: Date) -> Double? {
        guard let reset, reset > now else { return nil }
        let duration = durationMinutes ?? (id.hasSuffix("-5h") ? 300 : id.hasSuffix("-weekly") ? 10080 : nil)
        guard let duration, duration > 0 else { return nil }
        return min(1, reset.timeIntervalSince(now) / (duration * 60))
    }

    var reset: Date? {
        guard let resetTime, let date = parseDate(resetTime),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

struct QuotaGroup: Codable, Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let buckets: [Bucket]

    func usableQuota(_ bucket: Bucket) -> Bucket {
        guard bucket.isSession,
              let weekly = buckets.first(where: { $0.isWeekly && $0.remainingFraction <= 0 }) else {
            return bucket
        }
        let blocker = if let weeklyReset = weekly.reset, let sessionReset = bucket.reset,
                         sessionReset > weeklyReset {
            bucket
        } else {
            weekly
        }
        return Bucket(id: bucket.id, name: bucket.name, remainingFraction: 0,
                      resetTime: blocker.resetTime, durationMinutes: blocker.durationMinutes)
    }
}

struct Snapshot: Codable, Sendable, Equatable {
    let email: String
    let captured: Date
    let groups: [QuotaGroup]
    var plan: String? = nil
}

struct CLIReport: Decodable {
    struct Command: Decodable {
        struct Payload: Decodable {
            let groups: [QuotaGroup]
        }
        let name: String
        let data: Payload
    }
    let status: String
    let command: Command
    let numTurns: Int
}

struct Profile: Identifiable, Sendable, Equatable {
    let id: String
    let driver: String
    let name: String
    let accent: String?
    let email: String?
    let plan: String?
    let credits: Int?
    let creditExpiresAt: Date?
    let codexConfig: T3.Config.Codex?
    let usesDefaultMuseCLI: Bool
    let reading: Snapshot?

    var accountTint: Color {
        if let hex = accent,
           let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) {
            return Color(red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        return .teal
    }

    var tokenFile: URL { Self.antigravityTokenFile(id) }

    static func antigravityTokenFile(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/providers/antigravity")
            .appendingPathComponent(hash)
            .appendingPathComponent("antigravity-acp/antigravity-oauth-token")
    }
}

enum QuotaCLI {
    private struct Identity: Decodable {
        let idTokenEmail: String
    }

    static func read(_ profile: Profile) throws -> Snapshot {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure("Antigravity CLI is missing. Install agy and sign in first.")
        }
        let files = FileManager.default
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let token = try? Data(contentsOf: profile.tokenFile),
              let identity = try? decoder.decode(Identity.self, from: token),
              !identity.idTokenEmail.isEmpty,
              profile.email.map({ $0.caseInsensitiveCompare(identity.idTokenEmail) == .orderedSame }) != false else {
            throw Failure("No readable T3 Google sign-in found.")
        }

        let directory = files.temporaryDirectory.appendingPathComponent("antigravity-usage-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let cliData = directory.appendingPathComponent("antigravity-cli")
        try files.createDirectory(at: cliData, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cleanWork = directory.appendingPathComponent("work")
        try files.createDirectory(at: cleanWork, withIntermediateDirectories: false)
        let cliToken = cliData.appendingPathComponent("antigravity-oauth-token")
        guard files.createFile(atPath: cliToken.path, contents: token, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Couldn’t prepare the isolated CLI profile.")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--gemini_dir", directory.path, "--app_data_dir", "antigravity-cli",
            "--print", "/usage", "--output-format", "json", "--print-timeout", "12s",
        ]
        process.currentDirectoryURL = cleanWork
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["AGY_CLI_FORCE_FILE_TOKEN_STORAGE"] = "1"
        for key in ["GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("agy couldn’t read quota using this T3 sign-in.")
        }
        guard let report = try? decoder.decode(CLIReport.self, from: data),
              report.status == "SUCCESS", report.command.name == "usage", report.numTurns == 0,
              !report.command.data.groups.flatMap(\.buckets).isEmpty,
              report.command.data.groups.flatMap(\.buckets).allSatisfy({ (0...1).contains($0.remainingFraction) }) else {
            throw Failure("agy didn’t return a recognized quota report.")
        }
        return Snapshot(email: identity.idTokenEmail, captured: Date(), groups: report.command.data.groups)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

private enum MuseQuotaCLI {
    private struct Usage: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetsAtMs: Double
            let windowDurationMins: Double?
        }

        let observedAtMs: Double
        let window: Window
        let weekly: Window
    }

    static func read(email: String?) -> Snapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let paths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let binary = paths.map({ $0 + "/muse" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["usage", "--json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let usage = try? JSONDecoder().decode(Usage.self, from: data),
              usage.observedAtMs > 0 else { return nil }
        let windows = [("session", "Session", usage.window), ("weekly", "Weekly", usage.weekly)]
        let buckets = windows.compactMap { id, name, window -> Bucket? in
            guard window.usedPercent >= 0, window.resetsAtMs > 0 else { return nil }
            let reset = Date(timeIntervalSince1970: window.resetsAtMs / 1000)
            return Bucket(id: id, name: name, remainingFraction: max(0, 1 - window.usedPercent / 100),
                          resetTime: ISO8601DateFormatter().string(from: reset),
                          durationMinutes: id == "weekly" ? 10080 : window.windowDurationMins)
        }
        guard !buckets.isEmpty else { return nil }
        return Snapshot(email: email ?? "", captured: Date(timeIntervalSince1970: usage.observedAtMs / 1000),
                        groups: [QuotaGroup(name: "Subscription", buckets: buckets)])
    }
}

enum T3 {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")

    private struct Runtime: Decodable {
        let port: Int
    }

    private struct RefreshReply: Decodable {
        struct Exit: Decodable {
            let _tag: String
        }

        let _tag: String
        let requestId: String?
        let exit: Exit?
    }

    static func refreshProviders() async -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("userdata/server-runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data),
              (1...65535).contains(runtime.port),
              let url = URL(string: "ws://127.0.0.1:\(runtime.port)/ws?orchestrationProtocol=2") else {
            return false
        }

        let cli = root.appendingPathComponent("bin/t3")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return false }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["auth", "session", "issue", "--base-dir", root.path,
                             "--scope", "orchestration:read", "--ttl", "5m",
                             "--label", "Pulse quota refresh", "--token-only"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0,
              let token = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            session.invalidateAndCancel()
        }
        socket.resume()
        do {
            try await socket.send(.string(#"{"_tag":"Request","id":"0","tag":"server.refreshProviders","payload":{},"headers":[]}"#))
            while case .string(let message) = try await socket.receive() {
                if let reply = try? JSONDecoder().decode(RefreshReply.self, from: Data(message.utf8)),
                   reply._tag == "Exit", reply.requestId == "0" {
                    return reply.exit?._tag == "Success"
                }
            }
        } catch {
            return false
        }
        return false
    }

    struct Config: Decodable {
        struct Codex: Decodable, Sendable, Equatable {
            let binaryPath: String?
            let homePath: String?
            let shadowHomePath: String?
            let launchArgs: String?
        }
        let config: Codex?
        let usesDefaultMuseCLI: Bool
        let driver: String
        let enabled: Bool?
        let displayName: String?
        let accentColor: String?

        private enum MuseKeys: String, CodingKey { case binaryPath }

        private enum CodingKeys: String, CodingKey {
            case config, driver, enabled, displayName, accentColor
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            driver = try values.decode(String.self, forKey: .driver)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
            displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            accentColor = try values.decodeIfPresent(String.self, forKey: .accentColor)
            config = driver == "codex" ? try values.decodeIfPresent(Codex.self, forKey: .config) : nil
            if driver == "muse" {
                let settings = try? values.nestedContainer(keyedBy: MuseKeys.self, forKey: .config)
                let binary = try? settings?.decodeIfPresent(String.self, forKey: .binaryPath)
                usesDefaultMuseCLI = binary == nil || binary == "" || binary == "muse"
            } else {
                usesDefaultMuseCLI = false
            }
        }
    }

    struct Settings: Decodable {
        let providerInstances: [String: Config]
    }

    struct Cache: Decodable {
        struct Auth: Decodable {
            let email: String?
            let label: String?
        }
        struct Limits: Decodable {
            struct Window: Decodable {
                let id: String
                let kind: String
                let label: String
                let usedPercent: Double
                let resetsAt: String?
                let windowDurationMins: Double?
            }
            struct Credits: Decodable {
                let availableCount: Int
                let nextExpiresAt: String?
            }
            let checkedAt: String
            let windows: [Window]?
            let resetCredits: Credits?
        }
        let instanceId: String?
        let displayName: String?
        let accentColor: String?
        let enabled: Bool?
        let auth: Auth?
        let usageLimits: Limits?
    }

    private struct GoogleIdentity: Decodable {
        let id_token_email: String?
    }

    static func profiles() throws -> [Profile] {
        let decoder = JSONDecoder()
        let settings = try decoder.decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("userdata/settings.json")))
        return settings.providerInstances.compactMap { id, config in
            guard config.enabled != false, !id.contains("/"), id != ".", id != ".." else { return nil }
            let url = root.appendingPathComponent("caches").appendingPathComponent(id + ".json")
            let candidate = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Cache.self, from: $0) }
            let cache = candidate?.instanceId == id ? candidate : nil
            guard config.enabled == true || cache?.enabled != false else { return nil }
            let limits = cache?.usageLimits
            let buckets = (limits?.windows ?? []).compactMap { window -> Bucket? in
                guard (0...100).contains(window.usedPercent) else { return nil }
                let name = switch window.kind {
                case "session": "Session"
                case "weekly": "Weekly"
                default: window.label
                }
                return Bucket(id: window.kind == "session" || window.kind == "weekly" ? window.kind : window.id,
                              name: name, remainingFraction: 1 - window.usedPercent / 100, resetTime: window.resetsAt,
                              durationMinutes: window.windowDurationMins)
            }
            let reading = limits.flatMap { limits -> Snapshot? in
                guard !buckets.isEmpty, let date = parseDate(limits.checkedAt) else { return nil }
                return Snapshot(email: cache?.auth?.email ?? "", captured: date,
                                groups: [QuotaGroup(name: "Subscription", buckets: buckets)])
            }
            let googleEmail: String?
            if config.driver == "antigravity",
               let credentials = try? Data(contentsOf: Profile.antigravityTokenFile(id)) {
                googleEmail = (try? decoder.decode(GoogleIdentity.self, from: credentials))?.id_token_email
            } else {
                googleEmail = nil
            }
            return Profile(id: id, driver: config.driver, name: config.displayName ?? cache?.displayName ?? providerName(config.driver),
                           accent: config.accentColor ?? cache?.accentColor, email: googleEmail ?? cache?.auth?.email,
                           plan: cache?.auth?.label, credits: limits?.resetCredits?.availableCount,
                           creditExpiresAt: limits?.resetCredits?.nextExpiresAt.flatMap(parseDate),
                           codexConfig: config.config, usesDefaultMuseCLI: id == "muse" && config.usesDefaultMuseCLI,
                           reading: reading)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func providerName(_ driver: String) -> String {
        switch driver {
        case "codex": "Codex"
        case "claudeAgent": "Claude"
        case "cursor": "Cursor"
        case "opencode": "OpenCode"
        case "muse": "Muse Code"
        case "pi": "Pi"
        case "antigravity": "Antigravity"
        case "grok": "Grok"
        case "fx": "fx"
        case "kiro": "Kiro"
        default: driver.prefix(1).uppercased() + driver.dropFirst()
        }
    }
}

private let fractionalISODate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let standardISODate = Date.ISO8601FormatStyle()

func parseDate(_ value: String) -> Date? {
    (try? fractionalISODate.parse(value)) ?? (try? standardISODate.parse(value))
}

@MainActor
private enum PulseArtwork {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ name: String, extension type: String = "png") -> NSImage? {
        let key = name + "." + type
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        guard let url = Bundle.main.url(forResource: name, withExtension: type),
              let image = NSImage(contentsOf: url) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }
}

struct QuotaWindowKey: Codable, Hashable {
    let profileID: String
    let group: String
    let windowID: String
}

struct QuotaAlertRule: Codable {
    enum Event: String { case low, restored }

    var lastReading: Date?
    var belowThreshold = false
    var reset: Date?
    var balance: Double?
    var restorationEligible: Bool?

    mutating func evaluate(_ bucket: Bucket, captured: Date) -> [Event] {
        guard lastReading.map({ captured > $0 }) ?? true else { return [] }
        lastReading = captured
        let previousReset = reset
        let wasEligible = restorationEligible ?? (belowThreshold || balance == 0)
        var events: [Event] = []
        if bucket.reset.map({ $0 > captured }) ?? true {
            let isLow = bucket.remainingFraction <= 0.10 + 1e-9
            if isLow && !belowThreshold { events.append(.low) }
            belowThreshold = isLow
        }

        if let reset, captured >= reset {
            if wasEligible, let balance, bucket.remainingFraction > balance + 1e-9 {
                events.append(.restored)
            }
            // Consume a completed window when its replacement is reported.
            if bucket.reset != reset || events.contains(.restored) {
                self.reset = bucket.reset.flatMap { $0 > captured ? $0 : nil }
                balance = bucket.remainingFraction
            }
        } else {
            reset = bucket.reset.flatMap { $0 > captured ? $0 : nil }
            balance = bucket.remainingFraction
        }
        if reset == nil {
            restorationEligible = false
        } else {
            let reachedLow = events.contains(.low) || bucket.remainingFraction == 0
            restorationEligible = reachedLow || (reset == previousReset && wasEligible)
        }
        return events
    }
}

@MainActor
final class QuotaAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var rules: [QuotaWindowKey: QuotaAlertRule] = {
        guard let data = UserDefaults.standard.data(forKey: "pulseQuotaAlerts") else { return [:] }
        return (try? JSONDecoder().decode([QuotaWindowKey: QuotaAlertRule].self, from: data)) ?? [:]
    }()
    private var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var destination: QuotaWindowKey?
    var openDashboard: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var requestingPermission = false

    override init() {
        super.init()
        center.delegate = self
    }

    func updateAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        if authorization != status { authorization = status }
    }

    func requestPermissionIfNeeded() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        await updateAuthorization()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await updateAuthorization()
        }
    }

    func removeMissingAccounts(_ ids: Set<String>) {
        let removed = rules.keys.filter { !ids.contains($0.profileID) }
        guard !removed.isEmpty else { return }
        for key in removed { rules.removeValue(forKey: key) }
        center.removeDeliveredNotifications(withIdentifiers: removed.flatMap {
            [identifier($0, .low), identifier($0, .restored)]
        })
        save()
    }

    func evaluate(_ profile: Profile, snapshot: Snapshot, now: Date) {
        guard authorization == .authorized || authorization == .provisional,
              (0...600).contains(now.timeIntervalSince(snapshot.captured)) else { return }
        for group in snapshot.groups {
            for bucket in group.buckets {
                let key = QuotaWindowKey(profileID: profile.id, group: group.name, windowID: bucket.id)
                var rule = rules[key] ?? QuotaAlertRule()
                guard rule.lastReading.map({ snapshot.captured > $0 }) ?? true else { continue }
                let events = rule.evaluate(bucket, captured: snapshot.captured)
                rules[key] = rule
                save()
                for event in events { deliver(event, key: key, profile: profile, bucket: bucket, now: now) }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "pulseQuotaAlerts")
        }
    }

    private func identifier(_ key: QuotaWindowKey, _ event: QuotaAlertRule.Event) -> String {
        let data = (try? JSONEncoder().encode([key.profileID, key.group, key.windowID, event.rawValue])) ?? Data()
        return data.base64EncodedString()
    }

    private func deliver(_ event: QuotaAlertRule.Event, key: QuotaWindowKey, profile: Profile, bucket: Bucket, now: Date) {
        let content = UNMutableNotificationContent()
        content.title = profile.name + (event == .low ? " · Quota low" : " · Quota restored")
        content.subtitle = key.group == "Subscription" ? bucket.name : "\(key.group) · \(bucket.name)"
        content.body = percent(bucket.remainingFraction) + (event == .low ? " left" : " available")
        if event == .low, let reset = bucket.reset, reset > now {
            content.body += " · Resets in " + countdown(reset, now)
        }
        content.sound = .default
        content.userInfo = ["profile": key.profileID, "group": key.group, "window": key.windowID]
        center.add(UNNotificationRequest(identifier: identifier(key, event), content: content, trigger: nil))
    }

    func consumeDestination(_ key: QuotaWindowKey) {
        if destination == key { destination = nil }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let profile = info["profile"] as? String, let group = info["group"] as? String,
              let window = info["window"] as? String else { return }
        await MainActor.run {
            destination = QuotaWindowKey(profileID: profile, group: group, windowID: window)
            openDashboard?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct QuotaHistoryPoint: Codable, Identifiable {
    let id: Date
    let remaining: Double
    let reset: Date?
    let blockedByWeekly: Bool
}

struct QuotaHistorySeries: Codable {
    var name: String
    var durationMinutes: Double?
    var points: [QuotaHistoryPoint] = []
}

@MainActor
final class QuotaHistory: ObservableObject {
    static let retention: TimeInterval = 30 * 86_400
    static let maximumGap: TimeInterval = 20 * 60

    private struct Archive: Codable {
        var clearedAt: Date?
        var series: [QuotaWindowKey: QuotaHistorySeries] = [:]
    }

    @Published private var archive: Archive
    @Published private(set) var storageError = false
    private let file: URL
    private var needsSave = false

    init(file: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Pulse", isDirectory: true).appendingPathComponent("QuotaHistory.json")) {
        self.file = file
        archive = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }

    var isEmpty: Bool { archive.series.isEmpty }

    func windows(for profileID: String) -> [QuotaWindowKey: QuotaHistorySeries] {
        archive.series.filter { $0.key.profileID == profileID }
    }

    func collect(_ snapshots: [(String, Snapshot)], now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var updated = archive
        for key in Array(updated.series.keys) {
            guard let series = updated.series[key], let first = series.points.first, first.id < cutoff else { continue }
            updated.series[key]?.points.removeAll { $0.id < cutoff }
            if updated.series[key]?.points.isEmpty == true { updated.series.removeValue(forKey: key) }
            needsSave = true
        }
        for (profileID, snapshot) in snapshots {
            guard snapshot.captured > (updated.clearedAt ?? .distantPast),
                  (0...600).contains(now.timeIntervalSince(snapshot.captured)) else { continue }
            for group in snapshot.groups {
                for bucket in group.buckets {
                    let key = QuotaWindowKey(profileID: profileID, group: group.name, windowID: bucket.id)
                    var series = updated.series[key] ?? QuotaHistorySeries(name: bucket.name)
                    guard series.points.last.map({ $0.id < snapshot.captured }) ?? true else { continue }
                    let usable = group.usableQuota(bucket)
                    series.name = bucket.name
                    series.durationMinutes = bucket.durationMinutes
                    series.points.append(QuotaHistoryPoint(id: snapshot.captured, remaining: bucket.remainingFraction,
                        reset: bucket.reset, blockedByWeekly: bucket.isSession && usable.remainingFraction < bucket.remainingFraction))
                    updated.series[key] = series
                    needsSave = true
                }
            }
        }
        if needsSave { save(updated) }
    }

    func clear() {
        save(Archive(clearedAt: .now))
    }

    private func save(_ updated: Archive) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            archive = updated
            needsSave = false
            storageError = false
        } catch {
            storageError = true
        }
    }
}

private struct LocalUsageEvent: Sendable {
    let date: Date
    let provider: String
    let model: String
    let session: Int
    let input: Int
    let cached: Int
    let written: Int
    let output: Int
    let cost: Double?

    var tokens: Int { input + cached + written + output }
}

private enum LocalUsage {
    private struct Rates: Decodable {
        let input_cost_per_token: Double?
        let cache_read_input_token_cost: Double?
        let cache_creation_input_token_cost: Double?
        let output_cost_per_token: Double?

        func estimate(input: Int, cached: Int, written: Int, output: Int) -> Double? {
            let quantities = [input, cached, written, output]
            let rates = [input_cost_per_token, cache_read_input_token_cost,
                         cache_creation_input_token_cost, output_cost_per_token]
            var total = 0.0
            for (quantity, rate) in zip(quantities, rates) where quantity > 0 {
                guard let rate, rate.isFinite, rate >= 0 else { return nil }
                total += Double(quantity) * rate
            }
            return total
        }
    }

    private struct Catalog: Decodable { let document: [String: Rates] }

    private struct Cache: Decodable {
        let version: Int
        let models: [String]
        let files: [String: File]
    }

    private struct File: Decodable {
        let p: String
        let r: [Row]
    }

    private struct Row: Decodable {
        let timestamp: Double
        let model: Int
        let session: Int
        let input: Int
        let cached: Int
        let written: Int
        let output: Int
        let identity: String?

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            timestamp = try values.decode(Double.self)
            model = try values.decode(Int.self)
            session = try values.decode(Int.self)
            input = try values.decode(Int.self)
            cached = try values.decode(Int.self)
            written = try values.decode(Int.self)
            output = try values.decode(Int.self)
            _ = try values.decode(Int.self) // Reasoning tokens are included in output.
            identity = try values.decodeIfPresent(String.self)
        }
    }

    static func read(from directory: URL) throws -> [LocalUsageEvent] {
        let decoder = JSONDecoder()
        let file = directory.appendingPathComponent("usage-scan-cache-v17.json")
        let cache = try decoder.decode(Cache.self, from: Data(contentsOf: file))
        guard cache.version == 17 else { throw CocoaError(.fileReadCorruptFile) }
        let ratesFile = directory.appendingPathComponent("usage-model-rates.json")
        let rates = (try? decoder.decode(Catalog.self, from: Data(contentsOf: ratesFile)))?.document ?? [:]
        let cutoff = Date().addingTimeInterval(-91 * 86_400).timeIntervalSince1970 * 1000
        var seen: Set<String> = []
        var events: [LocalUsageEvent] = []
        for path in cache.files.keys.sorted() {
            guard let entry = cache.files[path] else { continue }
            let provider = entry.p == "claude" ? "claudeAgent" : entry.p
            for row in entry.r where row.timestamp >= cutoff {
                if let id = row.identity, !id.isEmpty, !seen.insert(provider + ":" + id).inserted { continue }
                let model = cache.models.indices.contains(row.model) ? cache.models[row.model] : "Unknown model"
                let estimate = rates[model]?.estimate(input: row.input, cached: row.cached,
                                                       written: row.written, output: row.output)
                events.append(LocalUsageEvent(date: Date(timeIntervalSince1970: row.timestamp / 1000),
                    provider: provider, model: model, session: row.session, input: row.input, cached: row.cached,
                    written: row.written, output: row.output, cost: estimate))
            }
        }
        return events
    }
}

private struct PulseDockSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color.white.opacity(0.25) : Color.white.opacity(0.07))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.19), lineWidth: 1) }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color.white : Color.secondary)
                            .frame(width: 12, height: 12)
                            .padding(3)
                    }
                    .frame(width: 32, height: 18)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private struct PulseToolbarHover: ViewModifier {
    var isEnabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering && isEnabled ? Color.white : Color.white.opacity(isEnabled ? 0.78 : 0.35))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(hovering && isEnabled ? 0.10 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct PulsePopoverRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                .white.opacity(selected ? 0.11 : hovering ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PulseDropdownButton<Label: View>: View {
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    init(isDisabled: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isDisabled = isDisabled
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                label()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                .white.opacity(hovering && !isDisabled ? 0.11 : 0.06),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
    }
}

private struct ProviderSelector: View {
    let drivers: [String]
    @Binding var selection: String?
    @State private var showingProviderPicker = false

    var body: some View {
        let selection = drivers.contains(self.selection ?? "") ? self.selection : nil
        return PulseDropdownButton {
            showingProviderPicker.toggle()
        } label: {
            if let selection {
                ProviderMark(driver: selection, size: 12)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(selection.map(T3.providerName) ?? "All providers")
                .lineLimit(1)
        }
        .accessibilityLabel("Filter by provider")
        .accessibilityValue(selection.map(T3.providerName) ?? "All providers")
        .popover(isPresented: $showingProviderPicker, arrowEdge: .bottom) {
            VStack(spacing: 3) {
                providerOption(nil, selection: selection)
                ForEach(drivers, id: \.self) { driver in
                    providerOption(driver, selection: selection)
                }
            }
            .padding(8)
            .frame(width: 160)
            .background(dashboardSurface)
        }
    }

    private func providerOption(_ driver: String?, selection: String?) -> some View {
        PulsePopoverRow(selected: driver == selection) {
            self.selection = driver
            showingProviderPicker = false
        } label: {
            Group {
                if let driver {
                    ProviderMark(driver: driver, size: 13)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 13, height: 13)
            Text(driver.map(T3.providerName) ?? "All")
                .lineLimit(1)
                .accessibilityLabel(driver.map(T3.providerName) ?? "All providers")
        }
    }
}

private struct PulseSegments<Option: Hashable>: View {
    let label: String
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @State private var hovered: Option?

    init(_ label: String, options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.label = label
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                let isHovered = hovered == option
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : (isHovered ? Color.white.opacity(0.84) : Color.secondary))
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.11))
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.045))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hovered = hovering ? option : (hovered == option ? nil : hovered)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct UsageDashboard: View {
    private enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "API cost", limits = "Limits"
        var id: Self { self }
    }

    private enum Period: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, quarter = 90
        var id: Self { self }
        var title: String { self == .day ? "24 hours" : "\(rawValue) days" }
    }

    private struct Totals {
        var tokens = 0
        var input = 0
        var cached = 0
        var written = 0
        var output = 0
        var estimatedCost = 0.0
        var pricedTokens = 0
        var sessions: Set<Int> = []

        mutating func add(_ event: LocalUsageEvent) {
            tokens += event.tokens
            input += event.input
            cached += event.cached
            written += event.written
            output += event.output
            sessions.insert(event.session)
            if let cost = event.cost {
                estimatedCost += cost
                pricedTokens += event.tokens
            }
        }

        func value(for metric: Metric) -> Double {
            metric == .cost ? estimatedCost : Double(tokens)
        }
    }

    private struct ModelKey: Hashable {
        let provider: String
        let name: String
    }

    private struct Bar: Identifiable {
        let date: Date
        let provider: String
        let value: Double
        var id: String { "\(date.timeIntervalSince1970):\(provider)" }
    }

    private struct Summary {
        var total = Totals()
        var providers: [String: Totals] = [:]
        var models: [ModelKey: Totals] = [:]
        var intervals: [Date: [String: Double]] = [:]

        var bars: [Bar] {
            intervals.keys.sorted().flatMap { date in
                (intervals[date] ?? [:]).sorted { $0.key < $1.key }
                    .map { Bar(date: date, provider: $0.key, value: $0.value) }
            }
        }
    }

    @ObservedObject var state: DashboardState
    @Environment(\.dismiss) private var dismiss
    @State private var events: [LocalUsageEvent] = []
    @State private var metric = Metric.tokens
    @State private var period = Period.month
    @State private var provider = ""
    @State private var summary = Summary()
    @State private var activeDate: Date?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var showAllModels = false
    @State private var now = Date()
    @State private var hoveringShowAll = false

    private var providerOptions: [String] { Set(events.map(\.provider)).sorted() }
    private var chartUnit: Calendar.Component { period == .day ? .hour : .day }
    private var chartTitle: String {
        (period == .day ? "Hourly " : "Daily ") + (metric == .cost ? "estimated API cost" : "token activity")
    }

    var body: some View {
        ZStack(alignment: .top) {
            if metric == .limits {
                QuotaHistoryDialog(history: state.history, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !events.isEmpty { filters }
                        if loading {
                            ProgressView("Reading local usage…")
                                .padding(56)
                                .frame(maxWidth: .infinity)
                        } else if loadFailed {
                            emptyCard(
                                title: "Local usage unavailable",
                                systemImage: "externaldrive",
                                description: "Open Usage in T3 Code to update its local cache, then refresh here."
                            )
                        } else if summary.total.tokens == 0 || (metric == .cost && summary.total.pricedTokens == 0) {
                            emptyCard(
                                title: metric == .cost && summary.total.tokens > 0 ? "No pricing for these models" : "No activity in this range",
                                systemImage: "chart.bar.xaxis",
                                description: metric == .cost && summary.total.tokens > 0
                                    ? "Switch to Tokens to see the recorded activity."
                                    : "Try a longer date range or choose All providers."
                            )
                        } else {
                            overview
                            breakdown
                        }
                    }
                    .padding(.horizontal, dashboardInset)
                    .padding(.top, dashboardToolbarHeight + 12)
                    .padding(.bottom, dashboardInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            dashboardHeaderFade
                .frame(height: dashboardToolbarHeight + 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            header
        }
        .frame(width: 900, height: 640)
        .background(dashboardSurface)
        .presentationBackground(dashboardSurface)
        .task { await load() }
        .onChange(of: period) { summarize() }
        .onChange(of: provider) { summarize() }
        .onChange(of: metric) { summarize() }
    }

    private func emptyCard(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 10) {
                Text("Usage")
                    .font(PulseType.display(17).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .modifier(PulseToolbarHover(isEnabled: !loading))
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .accessibilityLabel("Reload local usage")
                    .help("Reload the local T3 Code usage cache")

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12.5, weight: .semibold))
                            .modifier(PulseToolbarHover())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close Usage")
                }
            }
            PulseSegments("Usage view", options: Metric.allCases, selection: $metric) { $0.rawValue }
        }
        .padding(.horizontal, dashboardInset)
        .frame(height: dashboardToolbarHeight)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            ProviderSelector(drivers: providerOptions, selection: Binding(
                get: { provider.isEmpty ? nil : provider },
                set: { provider = $0 ?? "" }
            ))
            Spacer()
            PulseSegments("Range", options: Period.allCases, selection: $period) { $0.title }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric == .cost ? "Estimated API cost" : "Processed tokens")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(formatted(summary.total.value(for: metric)))
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-0.6)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(summary.total.sessions.count.formatted()) sessions")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    if metric == .cost {
                        Text("Standard model rates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Estimated from token counts and the local T3 Code rate catalog. Your subscription bill can differ.")
                    } else {
                        Text("Recorded on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 3)
            }

            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 22) {
                providerSummary
                    .frame(width: 210, alignment: .leading)
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(width: 1)
                    .padding(.vertical, 2)
                activityChart
                    .frame(maxWidth: .infinity)
            }

            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            if metric == .tokens {
                HStack(spacing: 0) {
                    stat("Cached input", value: compact(Double(summary.total.cached)))
                    statDivider
                    stat("New input", value: compact(Double(summary.total.input)))
                    statDivider
                    stat("Cache write", value: compact(Double(summary.total.written)))
                    statDivider
                    stat("Output", value: compact(Double(summary.total.output)))
                }
            } else {
                let coverage = Double(summary.total.pricedTokens) / Double(max(1, summary.total.tokens))
                Text("\(percent(coverage)) of tokens priced · Estimates use standard model rates available on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 16)
    }

    private var providerSummary: some View {
        let selected = activeDate.map { summary.intervals[$0, default: [:]] }
        let providers = summary.providers.keys.sorted {
            summary.providers[$0, default: Totals()].value(for: metric)
                > summary.providers[$1, default: Totals()].value(for: metric)
        }
        let selectedTotal = selected?.values.reduce(0, +)
        let denominator = max(selectedTotal ?? summary.total.value(for: metric), 0.0001)
        return VStack(alignment: .leading, spacing: 14) {
            Text(activeDate?.formatted(date: .abbreviated, time: period == .day ? .shortened : .omitted) ?? "By provider")
                .font(.caption.weight(.semibold))
                .foregroundStyle(activeDate == nil ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(providers, id: \.self) { driver in
                    let totals = summary.providers[driver, default: Totals()]
                    let value = selected.map { $0[driver, default: 0] } ?? totals.value(for: metric)
                    let share = min(1, max(0, value / denominator))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(driver))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(T3.providerName(driver))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(metric == .cost && totals.pricedTokens == 0 ? "Unpriced" : formatted(value))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.07))
                                Capsule()
                                    .fill(color(driver).opacity(0.85))
                                    .frame(width: max(value > 0 ? 4 : 0, geo.size.width * share))
                            }
                        }
                        .frame(height: 3.5)
                    }
                }
            }
            if let selectedTotal {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.top, 2)
                HStack {
                    Text("Total")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatted(selectedTotal))
                        .monospacedDigit()
                }
                .font(.callout.weight(.semibold))
            }
        }
    }

    private var activityChart: some View {
        let calendar = Calendar.current
        let start = period == .day ? now.addingTimeInterval(-86_400)
            : (calendar.date(byAdding: .day, value: 1 - period.rawValue, to: calendar.startOfDay(for: now)) ?? now)
        let end = calendar.dateInterval(of: chartUnit, for: now)?.end ?? now
        return VStack(alignment: .leading, spacing: 12) {
            Text(chartTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart {
                if let activeDate {
                    RuleMark(x: .value("Selected", activeDate, unit: chartUnit))
                        .foregroundStyle(.white.opacity(0.14))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(summary.bars) { bar in
                    BarMark(x: .value("Time", bar.date, unit: chartUnit), y: .value(metric.rawValue, bar.value))
                        .foregroundStyle(by: .value("Provider", bar.provider))
                        .cornerRadius(3)
                        .opacity(activeDate == nil || activeDate == bar.date ? 1 : 0.28)
                }
            }
            .chartForegroundStyleScale(domain: providerOptions, range: providerOptions.map(color))
            .chartLegend(.hidden)
            .chartXScale(domain: start...end)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.16))
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel {
                        if let value = mark.as(Double.self) {
                            Text(axisFormatted(value))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location),
                                      let date: Date = proxy.value(atX: location.x - frame.minX) else {
                                    activeDate = nil
                                    return
                                }
                                activeDate = calendar.dateInterval(of: chartUnit, for: date)?.start
                            case .ended:
                                activeDate = nil
                            }
                        }
                }
            }
            .accessibilityLabel(chartTitle)
            .frame(height: 190)
        }
    }

    private var breakdown: some View {
        let rows = summary.models.sorted {
            let left = $0.value.value(for: metric)
            let right = $1.value.value(for: metric)
            return left == right ? $0.key.name < $1.key.name : left > right
        }
        let visibleRows = Array(rows.prefix(showAllModels ? rows.count : 6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                Spacer()
                if rows.count > 6 {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            showAllModels.toggle()
                        }
                    } label: {
                        Text(showAllModels ? "Show top 6" : "Show all \(rows.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(hoveringShowAll ? Color.white : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(hoveringShowAll ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringShowAll = $0 }
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens")
                        .frame(width: 96, alignment: .trailing)
                    Text("API estimate")
                        .frame(width: 112, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ForEach(Array(visibleRows.enumerated()), id: \.element.key) { index, row in
                    let (key, totals) = row
                    Rectangle()
                        .fill(.white.opacity(index == 0 ? 0.07 : 0.05))
                        .frame(height: 1)
                    HStack(spacing: 16) {
                        HStack(spacing: 9) {
                            ProviderMark(driver: key.provider, size: 14)
                            Text(key.name)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(compact(Double(totals.tokens)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 96, alignment: .trailing)
                        Text(totals.pricedTokens == 0 ? "Unpriced" : money(totals.estimatedCost))
                            .monospacedDigit()
                            .frame(width: 112, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
            Text("Source: T3 Code’s local usage cache")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }

    private func stat(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ driver: String) -> Color {
        switch driver {
        case "codex": Color(red: 0.42, green: 0.72, blue: 1.0)
        case "claudeAgent": Color(red: 0.96, green: 0.60, blue: 0.36)
        case "antigravity": Color(red: 0.67, green: 0.56, blue: 1.0)
        default: .mint
        }
    }

    private func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(Locale(identifier: "en_US")))
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    private func axisFormatted(_ value: Double) -> String {
        if metric == .cost {
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        }
        return compact(value)
    }

    private func formatted(_ value: Double) -> String {
        metric == .cost ? money(value) : compact(value)
    }

    private func load() async {
        loading = true
        let directory = T3.root.appendingPathComponent("userdata", isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { Result { try LocalUsage.read(from: directory) } }.value
        switch result {
        case .success(let records):
            events = records
            if !providerOptions.contains(provider) { provider = "" }
            loadFailed = false
        case .failure:
            loadFailed = events.isEmpty
        }
        now = Date()
        summarize()
        loading = false
    }

    private func summarize() {
        activeDate = nil
        showAllModels = false
        guard metric != .limits else { return }
        let calendar = Calendar.current
        let start = period == .day ? now.addingTimeInterval(-86_400)
            : (calendar.date(byAdding: .day, value: 1 - period.rawValue, to: calendar.startOfDay(for: now)) ?? now)
        var result = Summary()
        for event in events where event.date >= start && event.date <= now && (provider.isEmpty || event.provider == provider) {
            result.total.add(event)
            result.providers[event.provider, default: Totals()].add(event)
            result.models[ModelKey(provider: event.provider, name: event.model), default: Totals()].add(event)
            let date = calendar.dateInterval(of: chartUnit, for: event.date)?.start ?? event.date
            result.intervals[date, default: [:]][event.provider, default: 0]
                += metric == .cost ? (event.cost ?? 0) : Double(event.tokens)
        }
        summary = result
    }
}

private struct QuotaHistoryDialog: View {
    enum Range: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30
        var id: Int { rawValue }
        var title: String { self == .day ? "24 hours" : "\(rawValue) days" }
    }

    private enum Session: CaseIterable {
        case short, weekly
    }

    private struct ChartSample: Identifiable {
        let id: Date
        let remaining: Double
        let segment: Int
        let reset: Bool
    }

    private struct ChartSeries: Identifiable {
        let id: String
        let label: String
        let tint: Color
        let samples: [ChartSample]
    }

    @ObservedObject var history: QuotaHistory
    @ObservedObject var state: DashboardState
    @State private var hiddenAccounts: Set<String> = []
    @State private var session = Session.short
    @State private var hidden: Set<String> = []
    @State private var range = Range.week
    @State private var selectedDate: Date?
    @State private var confirmingClear = false
    @State private var showingAccountPicker = false
    @State private var showingModelPicker = false
    @State private var hoveringClear = false

    private var profiles: [Profile] {
        state.orderedDrivers.flatMap { driver in state.profiles.filter { $0.driver == driver } }
    }

    private var selectedProfiles: [Profile] {
        profiles.filter { !hiddenAccounts.contains($0.id) }
    }

    private var series: [QuotaWindowKey: QuotaHistorySeries] {
        selectedProfiles.reduce(into: [:]) { result, profile in
            result.merge(history.windows(for: profile.id), uniquingKeysWith: { current, _ in current })
        }
    }

    private var groups: [String] { Set(series.keys.map(\.group)).sorted() }

    private var sessions: [Session] {
        let available = Set(series.compactMap { session(for: $0.key, reading: $0.value) })
        return Session.allCases.filter(available.contains)
    }

    private var activeSession: Session? {
        sessions.contains(session) ? session : sessions.first
    }

    private func sessionTitle(_ option: Session) -> String {
        if option == .weekly { return "Weekly" }
        return selectedProfiles.allSatisfy { $0.driver == "antigravity" } ? "5-hour session" : "Session"
    }

    private func session(for key: QuotaWindowKey, reading: QuotaHistorySeries) -> Session? {
        let bucket = Bucket(id: key.windowID, name: reading.name, remainingFraction: 0,
                            resetTime: nil, durationMinutes: reading.durationMinutes)
        let name = bucket.name.lowercased()
        if bucket.isWeekly || name.hasPrefix("weekly") { return .weekly }
        if bucket.isSession || name.hasPrefix("five hour") || name.hasPrefix("5 hours") { return .short }
        return nil
    }

    private func tint(for group: String, groups: [String]) -> Color {
        let colors: [Color] = [.cyan, .purple, .mint, .orange, .blue, .pink, .teal]
        return colors[(groups.firstIndex(of: group) ?? 0) % colors.count]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    accountPicker
                    modelPicker
                    if sessions.count > 1 {
                        PulseSegments("Quota session", options: sessions, selection: $session, title: sessionTitle)
                    } else if let activeSession {
                        Text(sessionTitle(activeSession))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PulseSegments("Range", options: Range.allCases, selection: $range) { $0.title }
                        .disabled(profiles.isEmpty)
                }

                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    chart(end: timeline.date)
                }

                HStack(spacing: 12) {
                    if history.storageError {
                        Text("Pulse couldn’t save history.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Stored on this Mac for 30 days.")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        confirmingClear = true
                    } label: {
                        Text("Clear history…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(history.isEmpty ? Color.secondary.opacity(0.45) : (hoveringClear ? Color.white : Color.secondary))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                .white.opacity(!history.isEmpty && hoveringClear ? 0.10 : 0.05),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(history.isEmpty)
                    .onHover { hoveringClear = $0 }
                }
                .font(.caption)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, dashboardInset)
            .padding(.top, dashboardToolbarHeight + 12)
            .padding(.bottom, dashboardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: hiddenAccounts) { selectedDate = nil }
        .onChange(of: session) { selectedDate = nil }
        .onChange(of: hidden) { selectedDate = nil }
        .onChange(of: range) { selectedDate = nil }
        .confirmationDialog("Clear all usage history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pulse will start a new history with the next reading.")
        }
    }

    private var accountPicker: some View {
        PulseDropdownButton(isDisabled: profiles.isEmpty) {
            showingAccountPicker.toggle()
        } label: {
            if selectedProfiles.count == 1, let profile = selectedProfiles.first {
                Circle()
                    .fill(profile.accountTint)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(profile.name)
                    .lineLimit(1)
                Text("· \(T3.providerName(profile.driver))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(selectedProfiles.isEmpty ? "No accounts" : selectedProfiles.count == profiles.count ? "All accounts" : "\(selectedProfiles.count) accounts")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Accounts")
        .accessibilityValue("\(selectedProfiles.count) of \(profiles.count) shown")
        .popover(isPresented: $showingAccountPicker, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(profiles) { profile in
                        PulsePopoverRow(selected: !hiddenAccounts.contains(profile.id)) {
                            if !hiddenAccounts.insert(profile.id).inserted { hiddenAccounts.remove(profile.id) }
                        } label: {
                            Circle()
                                .fill(profile.accountTint)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(profile.name)
                                .lineLimit(1)
                            Text(T3.providerName(profile.driver))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: 240)
            .frame(maxHeight: 280)
            .background(dashboardSurface)
        }
    }

    private var modelPicker: some View {
        PulseDropdownButton(isDisabled: groups.isEmpty) {
            showingModelPicker.toggle()
        } label: {
            let visibleCount = groups.count - groups.filter { hidden.contains($0) }.count
            Text(groups.isEmpty ? "No models" : visibleCount == groups.count ? "All models" : "\(visibleCount) selected")
                .lineLimit(1)
        }
        .accessibilityLabel("Model groups")
        .accessibilityValue("\(groups.filter { !hidden.contains($0) }.count) of \(groups.count) shown")
        .popover(isPresented: $showingModelPicker, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(groups, id: \.self) { group in
                        PulsePopoverRow(selected: !hidden.contains(group)) {
                            if hidden.contains(group) {
                                hidden.remove(group)
                            } else {
                                hidden.insert(group)
                            }
                        } label: {
                            Circle().fill(tint(for: group, groups: groups)).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(group)
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: 240)
            .frame(maxHeight: 280)
            .background(dashboardSurface)
        }
    }

    private func combinedSamples(
        _ windows: [QuotaWindowKey: QuotaHistorySeries], in dates: ClosedRange<Date>
    ) -> [ChartSample] {
        let readings = windows.flatMap { key, series in
            series.points
                .filter { $0.id >= dates.lowerBound.addingTimeInterval(-QuotaHistory.maximumGap) && $0.id <= dates.upperBound }
                .map { (key: key, point: $0) }
        }
        let timeline = Dictionary(grouping: readings, by: { $0.point.id })
        var latest: [QuotaWindowKey: QuotaHistoryPoint] = [:]
        var previousKeys: Set<QuotaWindowKey> = []
        var previousDate: Date?
        var segment = 0

        return timeline.keys.sorted().compactMap { date in
            let updates = timeline[date, default: []]
            let reset = updates.contains { update in
                guard let previous = latest[update.key], let resetAt = previous.reset else { return false }
                return previous.id < resetAt && date >= resetAt && update.point.remaining > previous.remaining + 1e-9
            }
            for update in updates { latest[update.key] = update.point }
            guard dates.contains(date) else { return nil }
            latest = latest.filter { date.timeIntervalSince($0.value.id) <= QuotaHistory.maximumGap }
            let keys = Set(latest.keys)
            if let previousDate, date.timeIntervalSince(previousDate) > QuotaHistory.maximumGap || keys != previousKeys {
                segment += 1
            }
            previousDate = date
            previousKeys = keys

            let accounts = Dictionary(grouping: latest, by: { $0.key.profileID })
            let averages = accounts.values.map { windows in
                windows.reduce(0) { $0 + $1.value.remaining } / Double(windows.count)
            }
            let remaining = averages.reduce(0, +) / Double(averages.count)
            return ChartSample(id: date, remaining: remaining, segment: segment, reset: reset)
        }
    }

    private func providerTint(_ driver: String) -> Color {
        switch driver {
        case "codex": .cyan
        case "antigravity": .purple
        case "claudeAgent": .orange
        default: profiles.first { $0.driver == driver }?.accountTint ?? .mint
        }
    }

    private func chart(end: Date) -> some View {
        let dates = end.addingTimeInterval(-Double(range.rawValue) * 86_400)...end
        let activeSession = activeSession
        let groups = groups
        let selected = selectedProfiles
        let windows = series.filter { key, reading in
            !hidden.contains(key.group) && (session(for: key, reading: reading).map { $0 == activeSession } ?? true)
        }
        let charts = state.orderedDrivers.compactMap { driver -> ChartSeries? in
            let accounts = Set(selected.filter { $0.driver == driver }.map(\.id))
            guard !accounts.isEmpty else { return nil }
            let samples = combinedSamples(windows.filter { accounts.contains($0.key.profileID) }, in: dates)
            guard !samples.isEmpty else { return nil }
            return ChartSeries(id: driver, label: T3.providerName(driver), tint: providerTint(driver), samples: samples)
        }
        let emptyTitle: String
        let emptyMessage: String
        if selected.isEmpty && !profiles.isEmpty {
            emptyTitle = "No accounts selected"
            emptyMessage = "Open Accounts to show readings."
        } else if !groups.isEmpty && groups.allSatisfy(hidden.contains) {
            emptyTitle = "No models selected"
            emptyMessage = "Open Model groups to show readings."
        } else {
            emptyTitle = "No readings in this range"
            emptyMessage = "Pulse records quota readings while it’s running."
        }
        let samples = charts.flatMap(\.samples)
        return VStack(alignment: .leading, spacing: 18) {
            if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(emptyTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 88)
                .frame(maxWidth: .infinity)
            } else {
                quotaSummary(charts)

                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)

                Chart {
                    ForEach(Array(charts.enumerated()), id: \.element.id) { index, entry in
                        let segmentSizes = Dictionary(grouping: entry.samples, by: \.segment).mapValues(\.count)
                        let featured = featuredSample(in: entry)
                        ForEach(entry.samples) { sample in
                            LineMark(x: .value("Reading time", sample.id), y: .value("Remaining", sample.remaining),
                                     series: .value("Continuous readings", "\(index)-\(sample.segment)"))
                                .foregroundStyle(entry.tint)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            if sample.reset || segmentSizes[sample.segment] == 1 || (selectedDate != nil && featured?.id == sample.id) {
                                PointMark(x: .value("Reading time", sample.id), y: .value("Remaining", sample.remaining))
                                    .foregroundStyle(sample.reset ? Color.mint : entry.tint)
                                    .symbolSize(selectedDate != nil && featured?.id == sample.id ? 60 : 24)
                            }
                        }
                    }
                    if let selectedDate {
                        RuleMark(x: .value("Selected reading", selectedDate))
                            .foregroundStyle(.white.opacity(0.16))
                    }
                }
                .chartXScale(domain: dates)
                .chartYScale(domain: 0...1)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.16))
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.07))
                        AxisValueLabel {
                            if let fraction = value.as(Double.self) {
                                Text(percent(fraction))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let frame = proxy.plotFrame.map({ geometry[$0] }),
                                          frame.contains(location) else {
                                        selectedDate = nil
                                        return
                                    }
                                    selectedDate = proxy.value(atX: location.x - frame.minX)
                                case .ended:
                                    selectedDate = nil
                                }
                            }
                    }
                }
                .frame(height: 270)
                .accessibilityLabel("Quota remaining over time")

                if samples.contains(where: \.reset) {
                    Label("Account quota reset", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
    }
    private func featuredSample(in entry: ChartSeries) -> ChartSample? {
        guard let selectedDate else { return entry.samples.last }
        let closest = entry.samples.min {
            abs($0.id.timeIntervalSince(selectedDate)) < abs($1.id.timeIntervalSince(selectedDate))
        }
        return closest.flatMap { abs($0.id.timeIntervalSince(selectedDate)) <= QuotaHistory.maximumGap ? $0 : nil }
    }

    private func quotaSummary(_ charts: [ChartSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDate == nil ? "Latest average quota remaining" : "Average quota remaining")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let selectedDate {
                    Text(selectedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 12) {
                ForEach(charts) { entry in
                    let sample = featuredSample(in: entry)
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(entry.label)
                                .font(.caption.weight(.medium))
                        } icon: {
                            Circle().fill(entry.tint).frame(width: 7, height: 7)
                        }
                        Text(sample.map { percent($0.remaining) } ?? "—")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

}

@MainActor
final class DashboardState: ObservableObject {
    let alerts = QuotaAlerts()
    let history = QuotaHistory()
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var snapshots: [String: Snapshot] = {
        guard let data = UserDefaults.standard.data(forKey: "pulseAntigravityReadings") else { return [:] }
        return (try? JSONDecoder().decode([String: Snapshot].self, from: data)) ?? [:]
    }()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var nextRefresh: Date?
    @Published private(set) var inventoryError = false
    @Published private(set) var initialScanFinished = false
    @Published private(set) var initialScanIDs: Set<String> = []

    @Published private(set) var providerOrder = UserDefaults.standard.stringArray(forKey: "pulseProviderOrder") ?? []

    var orderedDrivers: [String] {
        let enabled = Set(profiles.map(\.driver))
        return providerOrder.filter { enabled.contains($0) }
            + enabled.subtracting(providerOrder).sorted()
    }

    @discardableResult
    func moveProvider(_ driver: String, to destination: String) -> Bool {
        var displayed = orderedDrivers
        guard driver != destination, let from = displayed.firstIndex(of: driver),
              let to = displayed.firstIndex(of: destination) else { return false }
        displayed.remove(at: from)
        displayed.insert(driver, at: to)

        let enabled = Set(displayed)
        let fullOrder = providerOrder + displayed.filter { !providerOrder.contains($0) }
        var reordered = displayed.makeIterator()
        saveProviderOrder(fullOrder.map { enabled.contains($0) ? (reordered.next() ?? $0) : $0 })
        return true
    }

    func resetProviderOrder() {
        saveProviderOrder([])
    }

    private func saveProviderOrder(_ order: [String]) {
        providerOrder = order
        UserDefaults.standard.set(order, forKey: "pulseProviderOrder")
    }

    private var lastLoad = Date.distantPast
    private var lastCodexAttempt = Date.distantPast
    private var monitorTask: Task<Void, Never>?
    private var fileVersions: [URL: Date] = [:]
    private var watchedFiles = [T3.root.appendingPathComponent("userdata/settings.json")]
    private var refreshingT3Providers = false
    private var antigravityReadingsDirty = false

    func startMonitoring() {
        guard monitorTask == nil else { return }
        Task { await alerts.requestPermissionIfNeeded() }
        monitorTask = Task { await monitor() }
    }

    private func inventoryChanged() -> Bool {
        let versions = Dictionary(uniqueKeysWithValues: watchedFiles.map { url in
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url, modified ?? .distantPast)
        })
        guard versions != fileVersions else { return false }
        fileVersions = versions
        return true
    }

    func readInventory() {
        guard let inventory = try? T3.profiles() else {
            if !inventoryError { inventoryError = true }
            return
        }
        if inventoryError { inventoryError = false }
        alerts.removeMissingAccounts(Set(inventory.map(\.id)))
        guard inventory != profiles else { return }
        if inventory.map(\.id) != profiles.map(\.id) {
            watchedFiles = [T3.root.appendingPathComponent("userdata/settings.json")] + inventory.map {
                T3.root.appendingPathComponent("caches").appendingPathComponent($0.id + ".json")
            } + inventory.filter { $0.driver == "antigravity" }.map(\.tokenFile)
        }
        profiles = inventory
    }

    func menuSummary(at now: Date) -> [MenuQuota] {
        orderedDrivers.map { driver in
            let accounts = profiles.filter { $0.driver == driver }
            @MainActor func average(weekly: Bool) -> Double? {
                var seen: Set<String> = []
                let values = accounts.compactMap { profile -> Double? in
                    guard errors[profile.id] == nil, let snapshot = reading(profile) else { return nil }
                    let groups = snapshot.groups.filter {
                        driver != "antigravity" || $0.name == "Subscription"
                            || $0.name.localizedCaseInsensitiveContains("Gemini")
                    }
                    let bucket = groups.lazy.flatMap { group in
                        group.buckets.filter { weekly ? $0.isWeekly : $0.isSession }.map(group.usableQuota)
                    }.first { $0.reset.map { $0 > now } ?? true }
                    guard let bucket else { return nil }
                    let identity = snapshot.email.isEmpty ? profile.id : snapshot.email.lowercased()
                    guard seen.insert(identity).inserted else { return nil }
                    return bucket.remainingFraction
                }
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / Double(values.count)
            }
            return MenuQuota(id: driver, name: T3.providerName(driver),
                             session: average(weekly: false), weekly: average(weekly: true))
        }
    }

    func reading(_ profile: Profile) -> Snapshot? {
        guard let live = snapshots[profile.id],
              let email = profile.email ?? (profile.usesDefaultMuseCLI ? "" : nil),
              email.caseInsensitiveCompare(live.email) == .orderedSame else {
            return profile.reading
        }
        if let cached = profile.reading, cached.captured >= live.captured { return cached }
        return live
    }

    func readingSource(_ profile: Profile, snapshot: Snapshot) -> String {
        if profile.reading == snapshot { return "T3 Code cache" }
        return T3.providerName(profile.driver) + " CLI"
    }

    private func monitor() async {
        while !Task.isCancelled {
            if inventoryChanged() || inventoryError { readInventory() }
            let now = Date()
            let missing = profiles.contains { $0.driver == "antigravity" && reading($0) == nil && errors[$0.id] == nil }
            let staleCodex = now.timeIntervalSince(lastCodexAttempt) >= 600 && profiles.contains {
                guard $0.driver == "codex", $0.email != nil else { return false }
                return now.timeIntervalSince(reading($0)?.captured ?? .distantPast) >= 600
            }
            if lastLoad == .distantPast || now >= (nextRefresh ?? .distantFuture) || missing || staleCodex {
                await refresh(reloadInventory: false, includeCodex: lastLoad == .distantPast || staleCodex)
            }
            if !profiles.isEmpty { await alerts.updateAuthorization() }
            let checkedAt = Date()
            let readings = profiles.compactMap { profile -> (Profile, Snapshot)? in
                guard !pending.contains(profile.id), errors[profile.id] == nil,
                      refreshOutcomes[profile.id] == nil, let snapshot = reading(profile) else { return nil }
                return (profile, snapshot)
            }
            history.collect(readings.map { ($0.0.id, $0.1) }, now: checkedAt)
            for (profile, snapshot) in readings {
                alerts.evaluate(profile, snapshot: snapshot, now: checkedAt)
            }
            let visible = NSApp.isActive && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
            let idleDelay: TimeInterval = visible ? 10 : 30
            let untilRefresh = nextRefresh.map { max(1, $0.timeIntervalSinceNow) } ?? idleDelay
            do { try await Task.sleep(for: .seconds(min(idleDelay, untilRefresh)), tolerance: .seconds(2)) }
            catch { return }
        }
    }

    func refresh(reloadInventory: Bool = true, includeCodex: Bool = true) async {
        guard pending.isEmpty, !refreshingT3Providers else { return }
        if reloadInventory { readInventory() }
        let cliProfiles = profiles.filter { $0.driver == "antigravity" && $0.reading == nil }
        let codexProfiles = includeCodex ? profiles.filter { $0.driver == "codex" && $0.email != nil } : []
        if !codexProfiles.isEmpty { lastCodexAttempt = .now }
        let t3Profiles = profiles.filter { $0.driver != "codex" && $0.driver != "antigravity" }
        let t3IDs = Set(t3Profiles.map(\.id))
        refreshingT3Providers = !t3IDs.isEmpty
        pending = Set((cliProfiles + codexProfiles).map(\.id)).union(t3IDs)
        if !initialScanFinished { initialScanIDs = pending }
        lastLoad = .now
        nextRefresh = nil
        await withTaskGroup(of: Void.self) { group in
            if !t3IDs.isEmpty {
                group.addTask { [weak self] in
                    var fallback = t3IDs
                    if let muse = t3Profiles.first(where: \.usesDefaultMuseCLI),
                       let reading = MuseQuotaCLI.read(email: muse.email) {
                        await self?.record(muse.id, result: .success(reading))
                        fallback.remove(muse.id)
                    }
                    let refreshed = fallback.isEmpty ? false : await T3.refreshProviders()
                    await self?.finishT3Refresh(ids: fallback, refreshed: refreshed)
                }
            }
            if !cliProfiles.isEmpty {
                group.addTask { [weak self] in
                    for profile in cliProfiles {
                        let result = Result { try QuotaCLI.read(profile) }
                        await self?.record(profile.id, result: result)
                    }
                }
            }
            for lane in 0..<min(2, codexProfiles.count) {
                group.addTask { [weak self] in
                    for index in stride(from: lane, to: codexProfiles.count, by: 2) {
                        let profile = codexProfiles[index]
                        let result = Result { try CodexReset.readQuota(profile) }
                        await self?.record(profile.id, result: result)
                    }
                }
            }
        }
        if antigravityReadingsDirty {
            let ids = Set(profiles.filter { $0.driver == "antigravity" }.map(\.id))
            if let data = try? JSONEncoder().encode(snapshots.filter { ids.contains($0.key) }) {
                UserDefaults.standard.set(data, forKey: "pulseAntigravityReadings")
            }
            antigravityReadingsDirty = false
        }
        if !cliProfiles.isEmpty || !t3IDs.isEmpty { nextRefresh = Date().addingTimeInterval(300) }
        if !initialScanFinished { initialScanFinished = true }
    }

    @Published private(set) var refreshOutcomes: [String: String] = [:]

    private func finishT3Refresh(ids: Set<String>, refreshed: Bool) {
        let previous = profiles
        if refreshed { readInventory() }
        for id in ids {
            let before = previous.first { $0.id == id }?.reading?.captured ?? .distantPast
            let after = profiles.first { $0.id == id }?.reading?.captured ?? .distantPast
            refreshOutcomes[id] = !refreshed ? "T3 Code refresh could not complete."
                : after > before ? nil : "T3 Code returned no newer quota reading."
        }
        pending.subtract(ids)
        refreshingT3Providers = false
    }

    private func record(_ id: String, result: Result<Snapshot, Error>) {
        switch result {
        case .success(let reading):
            snapshots[id] = reading
            refreshOutcomes[id] = nil
            errors[id] = nil
            if profiles.contains(where: { $0.id == id && $0.driver == "antigravity" }) {
                antigravityReadingsDirty = true
            }
        case .failure(let error):
            errors[id] = error.localizedDescription
        }
        pending.remove(id)
    }
}

struct QuotaRows: Layout {
    private let minimumWidth: CGFloat = 144
    private let maximumColumns = 5
    private let spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealColumns = min(subviews.count, maximumColumns)
        let idealWidth = minimumWidth * CGFloat(idealColumns) + spacing * CGFloat(max(0, idealColumns - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let rows = rowCount(width: width, count: subviews.count)
        let height = subviews.first?.sizeThatFits(.unspecified).height ?? 0
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let rows = rowCount(width: bounds.width, count: subviews.count)
        let cardsPerRow = subviews.count / rows
        let extraCards = subviews.count % rows
        let balancedColumns = cardsPerRow + (extraCards > 0 ? 1 : 0)
        let capacity = columnCapacity(width: bounds.width)
        let columns = rows > 2 ? capacity : balancedColumns
        let width = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = subviews.first?.sizeThatFits(.unspecified).height ?? 0
        var index = subviews.startIndex
        var remaining = subviews.count
        for row in 0..<rows {
            // Keep earlier rows full where possible, while leaving at least three cards per row.
            let count = rows > 2
                ? min(columns, remaining - (rows - row - 1) * min(3, cardsPerRow))
                : cardsPerRow + (row < extraCards ? 1 : 0)
            remaining -= count
            let rowWidth = CGFloat(count) * width + CGFloat(count - 1) * spacing
            let startX = bounds.midX - rowWidth / 2
            let y = bounds.minY + CGFloat(row) * (height + spacing)
            for column in 0..<count {
                let x = startX + CGFloat(column) * (width + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: width, height: height))
                subviews.formIndex(after: &index)
            }
        }
    }

    private func rowCount(width: CGFloat, count: Int) -> Int {
        let columns = columnCapacity(width: width)
        return (count + columns - 1) / columns
    }

    private func columnCapacity(width: CGFloat) -> Int {
        let fittingColumns = (width + spacing) / (minimumWidth + spacing)
        return max(1, Int(min(CGFloat(maximumColumns), fittingColumns)))
    }
}

private enum AccountPlan {
    static func codex(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "free": "ChatGPT Free"
        case "go": "ChatGPT Go"
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro"
        case "team", "business": "ChatGPT Business"
        case "enterprise": "ChatGPT Enterprise"
        case "edu": "ChatGPT Edu"
        default: nil
        }
    }

    static func cached(_ label: String?, driver: String) -> String? {
        guard let label, !label.isEmpty else { return nil }
        if driver == "codex", label.hasPrefix("ChatGPT "), label != "ChatGPT Subscription" {
            return label.replacingOccurrences(of: " Subscription", with: "")
        }
        if driver == "antigravity", ["Google AI Pro", "Google AI Ultra", "Google AI Plus"].contains(label) {
            return label
        }
        return nil
    }
}

private enum QuotaRecommendation {
    struct Candidate {
        let profile: Profile
        let snapshot: Snapshot
        let buckets: [Bucket]
        let group: String

        func priority(at now: Date) -> [Double] {
            let headroom = rank()
            // Keep a usable buffer in every window before prioritizing quota about to reset.
            guard headroom[0] >= 0.10 - 1e-9 else { return [0, 0] + headroom }
            let expiring = buckets.compactMap { bucket -> Double? in
                guard let reset = bucket.reset else { return nil }
                let seconds = reset.timeIntervalSince(now)
                let weekly = bucket.id == "weekly" || bucket.id.hasSuffix("-weekly")
                    || bucket.durationMinutes == 10080
                let horizon: Double = weekly ? 3 * 3600 : 3600
                return seconds > 0 && seconds <= horizon ? seconds : nil
            }.min()
            return [expiring == nil ? 0 : 1, -(expiring ?? 0)] + headroom
        }

        func rank(after date: Date? = nil) -> [Double] {
            let remaining = buckets.map { bucket in
                if let date, let reset = bucket.reset, reset <= date { return 1.0 }
                return bucket.remainingFraction
            }
            return [remaining.min() ?? 0] + remaining.reversed()
        }
    }


}

struct QuotaTile: View {
    @ObservedObject var alerts: QuotaAlerts
    let alertKey: QuotaWindowKey?
    let profile: Profile
    let snapshot: Snapshot?
    let bucket: Bucket?
    let now: Date
    let error: String?
    let showsResetBadge: Bool
    let isRecommended: Bool
    @State private var details = false
    @State private var confirmReset = false
    @State private var resetBusy = false
    @State private var resetStatus: String?
    @State private var spentAt: Date?

    private var subscriptionPlan: String? {
        snapshot?.plan ?? AccountPlan.cached(profile.plan, driver: profile.driver)
    }

    private var creditCount: Int { profile.credits ?? 0 }
    private var creditText: String { creditCount == 1 ? "1 reset credit" : "\(creditCount) reset credits" }
    private let creditTint = Color(red: 1, green: 0.85, blue: 0.57)

    private var tint: Color { profile.accountTint }

    var body: some View {
        Button {
            details.toggle()
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(tint.opacity(0.13))
                    Rectangle().fill(tint.opacity(0.37))
                        .frame(width: geometry.size.width * (bucket?.remainingFraction ?? 0))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(tint).frame(width: 7, height: 7)
                            Text(profile.name).font(.caption.weight(.semibold)).lineLimit(1)
                                .layoutPriority(1)
                            if isRecommended {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.80))
                                    .accessibilityHidden(true)
                            }
                            if showsResetBadge && creditCount > 0 {
                                Spacer(minLength: 2)
                                HStack(spacing: 3) {
                                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .semibold))
                                    Text(creditCount, format: .number)
                                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                }
                                .foregroundStyle(creditTint)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(.black.opacity(0.36), in: Capsule())
                                .fixedSize()
                                .accessibilityHidden(true)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(bucket.map { percent($0.remainingFraction) } ?? "—")
                                .font(.system(size: 15, weight: .bold)).monospacedDigit()
                            Spacer(minLength: 0)
                            if let fraction = bucket?.timeRemaining(at: now) {
                                ZStack {
                                    Circle().strokeBorder(.white.opacity(0.19), lineWidth: 1.5)
                                    Circle()
                                        .trim(from: 0, to: fraction)
                                        .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .padding(0.75)
                                }
                                .frame(width: 12, height: 12)
                                .accessibilityHidden(true)
                            }
                            Text(error != nil && bucket != nil ? "Last reading"
                                 : bucket?.reset.map { $0 > now ? countdown($0, now) : "Reset passed" }
                                 ?? (bucket == nil ? "Unavailable" : "No reset"))
                                .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 11)
                }
                .clipShape(.rect(cornerRadius: 9))
            }
            .frame(height: 53)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(bucket.map { percent($0.remainingFraction) + " left" } ?? "quota unavailable")")
        .accessibilityValue(isRecommended ? "Recommended" : "")
        .help(isRecommended ? "Recommended now" : "Open account details")
        .accessibilityHint(showsResetBadge && creditCount > 0 ? creditText + " available. Open account details for options." : "Open account details.")
        .popover(isPresented: $details, arrowEdge: .bottom) { detailsView }
        .onChange(of: alerts.destination, initial: true) { _, destination in
            guard let destination, destination == alertKey else { return }
            details = true
            alerts.consumeDestination(destination)
        }
    }

    private var detailsView: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(profile.name).font(.headline)
                }
                if let email = profile.email ?? snapshot?.email, !email.isEmpty {
                    Text(email).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let plan = subscriptionPlan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.07), in: Capsule())
                        .padding(.top, 3)
                }
            }
            if isRecommended {
                Label("Recommended now", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let bucket {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quota reset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reset = bucket.reset {
                        Text(reset.formatted(date: .abbreviated, time: .shortened))
                            .fontWeight(.semibold)
                    } else {
                        Text("No reset time reported")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if creditCount > 0 { resetFooter }
            if let resetStatus { Text(resetStatus).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .presentationBackground(Color(red: 0.11, green: 0.12, blue: 0.14))
        .confirmationDialog("Use one reset credit for " + profile.name + "?", isPresented: $confirmReset) {
            Button("Use reset credit", role: .destructive) {
                resetBusy = true
                resetStatus = nil
                Task {
                    defer { resetBusy = false }
                    do {
                        let outcome = try await CodexReset.shared.redeem(profile)
                        spentAt = snapshot?.captured
                        resetStatus = outcome
                    } catch {
                        resetStatus = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((profile.email ?? profile.name) + " · This spends one banked credit if a quota window can be reset.")
        }
    }

    private var resetFooter: some View {
        let waitingForCache = spentAt.map { $0 == snapshot?.captured } ?? false
        return VStack(alignment: .leading, spacing: 11) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(creditText, systemImage: "bolt.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(creditTint)
                    if let expiry = profile.creditExpiresAt {
                        Text("Expires " + expiry.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if profile.driver == "codex", profile.email != nil {
                    Button(resetBusy ? "Using reset…" : "Use reset") { confirmReset = true }
                        .disabled(resetBusy || waitingForCache)
                }
            }
        }
    }

}

func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
}

func countdown(_ date: Date, _ now: Date) -> String {
    let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}

private let dashboardWidth: CGFloat = 980
private let dashboardInset: CGFloat = 22
private let dashboardToolbarHeight: CGFloat = 44
private let dashboardSurface = Color(white: 0.06)

private let dashboardHeaderFade = LinearGradient(stops: [
    .init(color: dashboardSurface.opacity(0.96), location: 0),
    .init(color: dashboardSurface.opacity(0.94), location: 0.60),
    .init(color: dashboardSurface.opacity(0.55), location: 0.83),
    .init(color: .clear, location: 1),
], startPoint: .top, endPoint: .bottom)

struct Dashboard: View {
    @ObservedObject private var updates = PulseUpdates.shared
    @State private var showingRefreshDetails = false
    @State private var hoveringRefreshStatus = false
    @State private var showingAbout = false
    @State private var showingHistory = false
    @State private var showingRotation = false
    @ObservedObject var state: DashboardState
    var playsInitialReveal = false
    var isEmbeddedOverlay = false
    var dismissOverlay: (() -> Void)?
    @AppStorage("showAntigravitySharedModels") private var sharedModelsExpanded = false
    @State private var layoutOptions = false


    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ZStack(alignment: .top) {
                dashboardScroll(now: timeline.date)
                dashboardHeaderFade
                    .frame(height: dashboardToolbarHeight + 20)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                dashboardHeader(now: timeline.date)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(dashboardSurface)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(width: isEmbeddedOverlay ? nil : dashboardWidth)
        .frame(maxWidth: isEmbeddedOverlay ? .infinity : nil,
               minHeight: isEmbeddedOverlay ? 0 : 430, maxHeight: .infinity)
    }

    private func dashboardScroll(now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    ForEach(Array(state.orderedDrivers.enumerated()), id: \.element) { index, driver in
                        provider(driver, now: now)
                            .modifier(ProviderEntrance(enabled: playsInitialReveal, index: index))
                            .id(driver)
                    }
                    if state.profiles.isEmpty && !state.inventoryError {
                        Text("No enabled T3 Code providers found.").foregroundStyle(.secondary)
                    }
                }
                .padding(dashboardInset)
                .padding(.top, dashboardToolbarHeight)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .onReceive(state.alerts.$destination) { destination in
                guard let destination,
                      let profile = state.profiles.first(where: { $0.id == destination.profileID }) else { return }
                if groupRank(destination.group, driver: profile.driver) == 2 { sharedModelsExpanded = true }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(destination, anchor: .center)
                }
            }
        }
    }

    private var aboutPulse: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About Pulse")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Pulse brings quota balances and reset times for your T3 Code accounts into one dashboard and menu bar summary.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Supported providers")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                let providers = ["codex", "claudeAgent", "cursor", "opencode",
                                 "muse", "pi", "antigravity", "grok"]
                let border = Color.white.opacity(0.16)
                VStack(spacing: 0) {
                    ForEach(0..<2) { row in
                        if row > 0 { Rectangle().fill(border).frame(height: 1) }
                        HStack(spacing: 0) {
                            ForEach(0..<4) { column in
                                if column > 0 { Rectangle().fill(border).frame(width: 1) }
                                let driver = providers[row * 4 + column]
                                VStack(spacing: 6) {
                                    ProviderMark(driver: driver, size: 20, monochrome: true)
                                    Text(T3.providerName(driver))
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .padding(.top, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(height: 66)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(border)
                }
                Text("Other enabled providers can appear when T3 Code supplies quota data.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Enable accounts in T3 Code to see them in Pulse. Codex, Antigravity, and the default Muse Code account can refresh through their command-line tools. For other accounts, keep T3 Code running so Pulse can ask it for updates. Some tools only show usage during a session or report token totals. Pulse shows quota balances when it can get them.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { showingAbout = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380, alignment: .leading)
        .presentationBackground(dashboardSurface)
    }

    private func dashboardHeader(now: Date) -> some View {
        let checking = !state.pending.isEmpty
        return HStack(spacing: 10) {
            PulseWordmark()
            if updates.isUpdateAvailable {
                Button {
                    updates.controller.checkForUpdates(nil)
                } label: {
                    Label("New update", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the Pulse update")
            }
            Spacer()
            Button {
                showingRefreshDetails.toggle()
            } label: {
                Group {
                    if state.inventoryError {
                        Label("T3 settings unavailable", systemImage: "exclamationmark.circle")
                    } else if checking {
                        Text("Checking limits…")
                    } else if let next = state.nextRefresh {
                        Text("Next check in " + countdown(next, now)).monospacedDigit()
                    } else {
                        Text("Refresh details")
                    }
                }
                .foregroundStyle(state.inventoryError ? Color.orange
                    : hoveringRefreshStatus ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hoveringRefreshStatus = $0 }
            .help("View refresh details")
            .accessibilityHint("Opens refresh details")
            .popover(isPresented: $showingRefreshDetails, arrowEdge: .bottom) {
                RefreshDetails(state: state)
            }
            Button {
                Task { await state.refresh() }
            } label: {
                Group {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .modifier(PulseToolbarHover(isEnabled: !checking))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .disabled(checking)
            .accessibilityLabel(checking ? "Refreshing quota" : "Refresh quota")
            .help("Refresh quota (⌘R)")
            if let rotation = overallRotation(now: now) {
                rotationButton(rotation, now: now)
            }
            Button {
                showingHistory = true
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 13, weight: .semibold))
                    .modifier(PulseToolbarHover())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Usage")
            .help("Usage")
            .sheet(isPresented: $showingHistory) {
                UsageDashboard(state: state)
            }
            Button {
                layoutOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .modifier(PulseToolbarHover())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Customize layout")
            .help("Customize layout")
            .popover(isPresented: $layoutOptions, arrowEdge: .bottom) {
                ProviderLayoutOptions(state: state)
            }
            Button {
                showingAbout = true
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .modifier(PulseToolbarHover())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Pulse")
            .help("About Pulse and supported providers")
            .sheet(isPresented: $showingAbout) {
                aboutPulse
            }
            if isEmbeddedOverlay {
                Button {
                    dismissOverlay?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .modifier(PulseToolbarHover())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Usage")
                .help("Close Usage (Escape)")
            }
        }
        .font(.caption)
        .padding(.leading, isEmbeddedOverlay ? dashboardInset : 96)
        .padding(.trailing, dashboardInset)
        .frame(height: dashboardToolbarHeight)
    }

    private func provider(_ driver: String, now: Date) -> some View {
        let profiles = state.profiles.filter { $0.driver == driver }
        let groups = Set(profiles.flatMap { state.reading($0)?.groups.map(\.name) ?? [] }).sorted {
            (groupRank($0, driver: driver), $0) < (groupRank($1, driver: driver), $1)
        }
        let geminiGroups = groups.filter { groupRank($0, driver: driver) == 0 }
        let inlineGroup = geminiGroups.count == 1 ? geminiGroups.first : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(driver: driver, size: 18)
                    .frame(width: 22, height: 22)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(T3.providerName(driver)).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text("\(profiles.count)").font(.caption).foregroundStyle(.secondary)
                    if let inlineGroup {
                        Text("·").accessibilityHidden(true)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(inlineGroup).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 2)
            if groups.isEmpty {
                row("Quota", profiles: profiles, group: "", window: nil, now: now)
            }
            ForEach(groups, id: \.self) { group in
                if driver == "antigravity" && groupRank(group, driver: driver) == 2 {
                    Button {
                        sharedModelsExpanded.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Text("Claude & GPT models").font(.subheadline.weight(.medium))
                            Rectangle()
                                .fill(Color.white.opacity(0.10))
                                .frame(height: 1)
                                .accessibilityHidden(true)
                            Image(systemName: sharedModelsExpanded
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(sharedModelsExpanded ? "Expanded" : "Collapsed")
                    if sharedModelsExpanded {
                        quotaWindows(for: group, profiles: profiles, now: now, showsResetBadge: group == groups.first)
                    }
                } else {
                    if group != "Subscription" && group != inlineGroup {
                        Text(group).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    quotaWindows(for: group, profiles: profiles, now: now, showsResetBadge: group == groups.first)
                }
            }
        }
    }

    private func groupRank(_ group: String, driver: String) -> Int {
        guard driver == "antigravity" else { return 1 }
        let name = group.lowercased()
        if name.contains("gemini") { return 0 }
        if name.contains("claude") && name.contains("gpt") { return 2 }
        return 1
    }

    private func quotaWindows(for group: String, profiles: [Profile], now: Date, showsResetBadge: Bool) -> some View {
        let limits = windows(for: group, profiles: profiles)
        let recommendedID = recommendedAccount(for: group, profiles: profiles, windows: limits, now: now)
        return ForEach(limits) { window in
            row(window.name.replacingOccurrences(of: "Five Hour Limit Remaining", with: "5 hours")
                .replacingOccurrences(of: "Weekly Limit Remaining", with: "Weekly"),
                profiles: profiles, group: group, window: window.id, now: now,
                showsResetBadge: showsResetBadge && window.id == limits.first?.id,
                recommendedID: window.id == limits.first?.id ? recommendedID : nil)
        }
    }

    private func candidates(for group: String, profiles: [Profile], windows: [Bucket], now: Date) -> [QuotaRecommendation.Candidate] {
        guard !windows.isEmpty else { return [] }
        var seen: Set<String> = []
        return profiles.compactMap { profile -> QuotaRecommendation.Candidate? in
            guard state.errors[profile.id] == nil, let snapshot = state.reading(profile),
                  let buckets = snapshot.groups.first(where: { $0.name == group })?.buckets else { return nil }
            let current = windows.compactMap { window in
                buckets.first { $0.id == window.id && ($0.reset.map { $0 > now } ?? true) }
            }
            guard current.count == windows.count else { return nil }
            return .init(profile: profile, snapshot: snapshot, buckets: current, group: group)
        }.sorted { $0.snapshot.captured > $1.snapshot.captured }.filter { candidate in
            let email = candidate.snapshot.email
            return seen.insert(email.isEmpty ? candidate.profile.id : email.lowercased()).inserted
        }
    }

    private func recommendedAccount(for group: String, profiles: [Profile], windows: [Bucket], now: Date) -> String? {
        let eligible = candidates(for: group, profiles: profiles, windows: windows, now: now)
            .filter { $0.rank()[0] > 0 }
        guard eligible.count > 1 else { return nil }
        return eligible.max {
            $0.priority(at: now).lexicographicallyPrecedes($1.priority(at: now))
        }?.profile.id
    }

    private struct OverallRotation {
        let accounts: [QuotaRecommendation.Candidate]
        let recheck: QuotaRecommendation.Candidate?
        let recheckAt: Date?
    }

    private func overallRotation(now: Date) -> OverallRotation? {
        let all = state.orderedDrivers.flatMap { driver in
            let profiles = state.profiles.filter { $0.driver == driver }
            let groups = Set(profiles.flatMap { state.reading($0)?.groups.map(\.name) ?? [] }).sorted()
            return groups.flatMap { group -> [QuotaRecommendation.Candidate] in
                let limits = windows(for: group, profiles: profiles)
                guard let session = limits.first(where: \.isSession),
                      let weekly = limits.first(where: \.isWeekly),
                      session.id != weekly.id else { return [] }
                return candidates(for: group, profiles: profiles, windows: [session, weekly], now: now)
            }
        }
        func ordered(at date: Date? = nil) -> [QuotaRecommendation.Candidate] {
            all.sorted { left, right in
                let lhs = date.map { left.rank(after: $0) } ?? left.priority(at: now)
                let rhs = date.map { right.rank(after: $0) } ?? right.priority(at: now)
                if lhs != rhs { return rhs.lexicographicallyPrecedes(lhs) }
                let leftReset = left.buckets.compactMap(\.reset).filter { $0 > (date ?? now) }.min() ?? .distantFuture
                let rightReset = right.buckets.compactMap(\.reset).filter { $0 > (date ?? now) }.min() ?? .distantFuture
                if leftReset != rightReset { return leftReset < rightReset }
                return left.snapshot.captured > right.snapshot.captured
            }
        }
        var identities: Set<String> = []
        let options = ordered().filter { option in
            let email = option.snapshot.email.lowercased()
            let identity = email.isEmpty ? option.profile.id : email
            return option.rank()[0] > 0 && identities.insert(option.profile.driver + ":" + identity).inserted
        }
        guard let first = options.first,
              Set(all.map { $0.profile.driver }).count > 1 else { return nil }
        let checkpoints = Set(all.flatMap { $0.buckets.compactMap(\.reset) }).sorted()
        let next = checkpoints.lazy.compactMap { date -> (QuotaRecommendation.Candidate, Date)? in
            guard let pick = ordered(at: date).first,
                  pick.profile.id != first.profile.id,
                  first.rank(after: date).lexicographicallyPrecedes(pick.rank(after: date)) else { return nil }
            return (pick, date)
        }.first
        return OverallRotation(accounts: Array(options.prefix(3)), recheck: next?.0, recheckAt: next?.1)
    }

    private func rotationButton(_ rotation: OverallRotation, now: Date) -> some View {
        Button {
            showingRotation.toggle()
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .modifier(PulseToolbarHover())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Best overall")
        .accessibilityValue(rotation.accounts[0].profile.name)
        .help("Best overall: \(rotation.accounts[0].profile.name)")
        .popover(isPresented: $showingRotation, arrowEdge: .bottom) {
            rotationDetails(rotation, now: now)
        }
    }

    private func rotationDetails(_ rotation: OverallRotation, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested rotation")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    Text("Account")
                    Text("Session").gridColumnAlignment(.trailing)
                    Text("Weekly").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(Array(rotation.accounts.enumerated()), id: \.offset) { _, account in
                    let provider = T3.providerName(account.profile.driver)
                    GridRow {
                        HStack(spacing: 7) {
                            Circle().fill(account.profile.accountTint)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(account.profile.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("\(account.profile.name) · \(provider) · \(account.group)")
                        .accessibilityLabel("\(account.profile.name), \(provider), \(account.group)")

                        ForEach(Array(account.buckets.enumerated()), id: \.offset) { index, bucket in
                            let window = index == 0 ? "Session" : "Weekly"
                            Text(percent(bucket.remainingFraction))
                                .monospacedDigit()
                                .accessibilityLabel("\(window): \(percent(bucket.remainingFraction)) left")
                                .help(bucket.reset.map { "\(window) resets in \(countdown($0, now))" } ?? window)
                        }
                    }
                }
            }
            if let pick = rotation.recheck, let date = rotation.recheckAt {
                Divider()
                Text("Recheck in \(countdown(date, now)) · \(pick.profile.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .background(dashboardSurface)
    }

    private func windows(for group: String, profiles: [Profile]) -> [Bucket] {
        var seen: Set<String> = []
        return profiles.flatMap { state.reading($0)?.groups.first { $0.name == group }?.buckets ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.name == "Weekly" || $0.name.hasPrefix("Weekly") ? 1 : 0, $0.name)
                    < ($1.name == "Weekly" || $1.name.hasPrefix("Weekly") ? 1 : 0, $1.name) }
    }

    private func row(_ title: String, profiles: [Profile], group: String, window: String?, now: Date, showsResetBadge: Bool = true,
                     recommendedID: String? = nil) -> some View {
        let readings = profiles.map { profile in
            let snapshot = state.reading(profile)
            let quotaGroup = snapshot?.groups.first { $0.name == group }
            let bucket = quotaGroup.flatMap { quotas in
                quotas.buckets.first { $0.id == window }.map(quotas.usableQuota)
            }
            return (profile, snapshot, bucket)
        }
        let newestFirst = readings.sorted { ($0.1?.captured ?? .distantPast) > ($1.1?.captured ?? .distantPast) }
        let expected = Set(profiles.map { $0.email?.lowercased() ?? $0.id }).count
        var seen: Set<String> = []
        let available = newestFirst.compactMap { profile, snapshot, bucket -> Bucket? in
            guard state.errors[profile.id] == nil, let bucket, bucket.reset.map({ $0 > now }) != false else { return nil }
            let email = snapshot?.email.lowercased() ?? ""
            return seen.insert(email.isEmpty ? profile.id : email).inserted ? bucket : nil
        }
        let total: Double? = available.isEmpty ? nil : available.map(\.remainingFraction).reduce(0, +) / Double(available.count)
        let next = available.filter { $0.remainingFraction < 1 }.compactMap(\.reset).min()
        let gain = next.map { reset in available.filter { $0.reset == reset }.map { 1 - $0.remainingFraction }.reduce(0,+) / Double(available.count) }
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                if let total {
                    Text(percent(total) + " left").font(.system(size: 23, weight: .semibold)).monospacedDigit()
                    if available.count < expected {
                        Text("\(available.count) of \(expected) reporting").foregroundStyle(.orange)
                    } else if let next, let gain {
                        Text("+\(percent(gain)) in \(countdown(next, now))")
                    }
                } else {
                    Text("Unavailable")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: 132, alignment: .leading)
            .help("Equal-weight average across \(available.count) reporting accounts. Matching emails count once. Windows past their reported reset are excluded.")
            QuotaRows {
                ForEach(readings, id: \.0.id) { profile, snapshot, bucket in
                    let alertKey = QuotaWindowKey(profileID: profile.id, group: group, windowID: window ?? "")
                    QuotaTile(alerts: state.alerts,
                              alertKey: alertKey,
                              profile: profile, snapshot: snapshot, bucket: bucket, now: now, error: state.errors[profile.id],
                              showsResetBadge: showsResetBadge,
                              isRecommended: recommendedID == profile.id)
                    .id(alertKey)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
    }
}

private struct WindowDefaults: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SizingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class SizingView: NSView {
        private weak var configuredWindow: NSWindow?
        private var chromeObservers: [NSObjectProtocol] = []
        private var alignmentQueued = false

        override func layout() {
            super.layout()
            queueTrafficLightAlignment()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard configuredWindow !== window else { return }
            for observer in chromeObservers { NotificationCenter.default.removeObserver(observer) }
            chromeObservers = []
            configuredWindow = window
            guard let window else { return }
            PulseScreenPrivacy.applySaved(to: window)
            window.isRestorable = false
            let visibleHeight = window.screen?.visibleFrame.height ?? 740
            let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            window.setContentSize(NSSize(width: dashboardWidth, height: min(700, visibleHeight - titleBarHeight)))
            chromeObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                               NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.queueTrafficLightAlignment() }
                }
            }
            queueTrafficLightAlignment()
        }

        private func queueTrafficLightAlignment() {
            guard !alignmentQueued, window != nil else { return }
            alignmentQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.alignmentQueued = false
                if let window = self.window { self.alignTrafficLights(in: window) }
            }
        }

        private func alignTrafficLights(in window: NSWindow) {
            guard let close = window.standardWindowButton(.closeButton) else { return }
            let center = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            let delta = CGPoint(x: dashboardInset - center.x,
                                y: window.frame.height - dashboardToolbarHeight / 2 - center.y)
            guard abs(delta.x) > 0.25 || abs(delta.y) > 0.25 else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let origin = parent.convert(button.frame.origin, to: nil)
                button.setFrameOrigin(parent.convert(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), from: nil))
            }
        }
    }
}

struct MenuQuota: Identifiable {
    let id: String
    let name: String
    let session: Double?
    let weekly: Double?
}

private struct ProviderMark: View {
    let driver: String
    let size: CGFloat
    var monochrome = false

    var body: some View {
        Group {
            if let image = PulseArtwork.image(driver) ?? PulseArtwork.image(driver, extension: "svg") {
                Image(nsImage: image)
                    .renderingMode(monochrome && driver != "opencode" ? .template : .original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "square.stack.3d.up")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: size * 0.8))
            }
        }
        .foregroundStyle(monochrome ? Color.white : Color.primary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct RefreshDetails: View {
    @ObservedObject var state: DashboardState
    @State private var selectedProvider: String?
    @State private var listBounds = CGRect.zero
    @Namespace private var listSpace

    var body: some View {
        let drivers = state.orderedDrivers
        let selection = selectedProvider.flatMap { drivers.contains($0) ? $0 : nil }
        let visibleDrivers = selection.map { [$0] } ?? drivers
        let accountCount = state.profiles.filter { visibleDrivers.contains($0.driver) }.count
        return TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Refresh details").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if drivers.count > 1 {
                        ProviderSelector(drivers: drivers, selection: $selectedProvider)
                    }
                }
                if state.profiles.isEmpty {
                    Text(state.inventoryError ? "T3 Code settings are unavailable." : "No enabled accounts.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleDrivers, id: \.self) { driver in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) {
                                        ProviderMark(driver: driver, size: 12, monochrome: true)
                                        Text(T3.providerName(driver)).font(.caption.weight(.semibold))
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                    .foregroundStyle(.white)
                                    .opacity(0.55)
                                    .padding(.leading, 6)
                                    .padding(.bottom, 1)
                                    ForEach(state.profiles.filter { $0.driver == driver }) { profile in
                                        account(profile, now: timeline.date)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .named(listSpace))
                        } action: { bounds in
                            listBounds = bounds
                        }
                    }
                    .coordinateSpace(name: listSpace)
                    .id(selection)
                    .frame(idealHeight: min(340, CGFloat(accountCount * 64 + visibleDrivers.count * 22)),
                           maxHeight: 340)
                    .mask {
                        GeometryReader { geometry in
                            let height = max(1, geometry.size.height)
                            let fade = min(28 / height, 0.5)
                            let top = min(1, max(0, -listBounds.minY) / 8)
                            let bottom = min(1, max(0, listBounds.maxY - height) / 8)
                            LinearGradient(stops: [
                                .init(color: .black.opacity(1 - 0.94 * top), location: 0),
                                .init(color: .black.opacity(1 - 0.53 * top), location: fade * 0.35),
                                .init(color: .black.opacity(1 - 0.17 * top), location: fade * 0.70),
                                .init(color: .black, location: fade),
                                .init(color: .black, location: 1 - fade),
                                .init(color: .black.opacity(1 - 0.17 * bottom), location: 1 - fade * 0.70),
                                .init(color: .black.opacity(1 - 0.53 * bottom), location: 1 - fade * 0.35),
                                .init(color: .black.opacity(1 - 0.94 * bottom), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(dashboardSurface)
        }
    }

    private func account(_ profile: Profile, now: Date) -> some View {
        let snapshot = state.reading(profile)
        let error = state.errors[profile.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(profile.accountTint).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(profile.name).font(.callout.weight(.semibold))
            }
            if let snapshot {
                let age = now.timeIntervalSince(snapshot.captured)
                let time = age < 60 ? "Just now" : countdown(now, snapshot.captured) + " ago"
                Text(time + " · " + state.readingSource(profile, snapshot: snapshot))
                    .foregroundStyle(.secondary)
                if error == nil {
                    let expired = snapshot.groups.flatMap(\.buckets).filter { $0.reset.map { $0 <= now } == true }
                    if !expired.isEmpty {
                        Text(expired.map(\.name).joined(separator: ", ") + " excluded · Reset time passed")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("No quota reading yet").foregroundStyle(.secondary)
            }
            if state.pending.contains(profile.id) {
                Text("Checking…").foregroundStyle(.secondary)
            } else if let error {
                Text("Excluded from averages · " + error).foregroundStyle(.orange)
            } else if let outcome = state.refreshOutcomes[profile.id] {
                Text(outcome).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProviderLayoutOptions: View {
    @ObservedObject var state: DashboardState
    @AppStorage(PulseDock.preferenceKey) private var showsDockIcon = false
    @AppStorage(PulseScreenPrivacy.preferenceKey) private var hideFromScreenShare = false
    @AppStorage("pulseAttachToT3Usage") private var attachToT3Usage = false
    private struct Drag {
        let driver: String
        let translation: CGFloat
    }

    @GestureState private var drag: Drag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rowHeight: CGFloat = 34
    private let rowSpacing: CGFloat = 8

    private var rowStride: CGFloat { rowHeight + rowSpacing }

    private func destination(from source: Int, translation: CGFloat, count: Int) -> Int {
        let offset = Int((translation / rowStride).rounded())
        return min(max(source + offset, 0), count - 1)
    }

    var body: some View {
        let drivers = state.orderedDrivers
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack {
                Text("Provider order").font(.headline)
                Spacer()
                if !state.providerOrder.isEmpty {
                    Button {
                        state.resetProviderOrder()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Restore default order")
                    .accessibilityLabel("Restore default order")
                }
            }
            .frame(minHeight: 24)
            if drivers.isEmpty {
                Text("No enabled providers").foregroundStyle(.secondary)
            }
            ForEach(Array(drivers.enumerated()), id: \.element) { index, driver in
                providerRow(driver, index: index, drivers: drivers)
            }
            Divider().padding(.top, 3)
            Toggle("Show in Dock", isOn: $showsDockIcon)
                .toggleStyle(PulseDockSwitch())
                .onChange(of: showsDockIcon) { _, visible in PulseDock.apply(visible) }
                .padding(.horizontal, 1)
            Toggle("Hide from screen sharing", isOn: $hideFromScreenShare)
                .toggleStyle(PulseDockSwitch())
                .help("Full-display capture with ScreenCaptureKit may still show Pulse.")
                .onChange(of: hideFromScreenShare) { _, hidden in PulseScreenPrivacy.apply(hidden) }
            Toggle("Show inside T3 Code", isOn: Binding(
                get: { attachToT3Usage },
                set: { enabled in
                    attachToT3Usage = enabled
                    T3OverlayController.shared.setEnabled(enabled, promptIfNeeded: enabled)
                }
            ))
            .toggleStyle(PulseDockSwitch())
            if attachToT3Usage {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if !AXIsProcessTrusted() {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Accessibility Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(13)
        .frame(width: 235, alignment: .leading)
        .presentationBackground(dashboardSurface)
    }

    private func providerRow(_ driver: String, index: Int, drivers: [String]) -> some View {
        let dragging = drag?.driver == driver
        let shift = neighboringShift(index: index, drivers: drivers)
        let minOffset = -CGFloat(index) * rowStride
        let maxOffset = CGFloat(drivers.count - 1 - index) * rowStride
        let draggedOffset = dragging ? min(max(drag?.translation ?? 0, minOffset), maxOffset) : 0
        return HStack(spacing: 9) {
            ProviderMark(driver: driver, size: 17)
            Text(T3.providerName(driver)).fontWeight(.medium)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 9)
        .frame(height: rowHeight)
        .background(.white.opacity(dragging ? 0.14 : 0.05), in: .rect(cornerRadius: 7))
        .shadow(color: dragging ? .black.opacity(0.28) : .clear, radius: 5, y: 2)
        .offset(y: shift)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86), value: shift)
        .offset(y: draggedOffset)
        .zIndex(dragging ? 1 : 0)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($drag) { value, current, transaction in
                transaction.animation = nil
                current = Drag(driver: driver, translation: value.translation.height)
            }
            .onEnded { value in
                let target = destination(from: index, translation: value.translation.height, count: drivers.count)
                if target != index { state.moveProvider(driver, to: drivers[target]) }
            })
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move up") {
            if index > 0 { state.moveProvider(driver, to: drivers[index - 1]) }
        }
        .accessibilityAction(named: "Move down") {
            if index + 1 < drivers.count { state.moveProvider(driver, to: drivers[index + 1]) }
        }
    }

    private func neighboringShift(index: Int, drivers: [String]) -> CGFloat {
        guard let drag, let source = drivers.firstIndex(of: drag.driver), source != index else { return 0 }
        let target = destination(from: source, translation: drag.translation, count: drivers.count)
        if source < index && index <= target { return -rowStride }
        if target <= index && index < source { return rowStride }
        return 0
    }
}

private struct PulseWordmark: View {
    var body: some View {
        HStack(spacing: 5) {
            if let mark = PulseArtwork.image("PulseMenu@2x") {
                Image(nsImage: mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            }
            Text("Pulse")
                .font(PulseType.display(17).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct PulseMenu: View {
    @ObservedObject var state: DashboardState
    let openDashboard: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let summary = state.menuSummary(at: timeline.date)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    PulseWordmark().foregroundStyle(.white)
                    Spacer()
                    if !state.pending.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking quota")
                    }
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Quit Pulse")
                    .help("Quit Pulse")
                }
                if summary.isEmpty {
                    Text(state.inventoryError ? "T3 settings unavailable" : "No quota readings yet")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Average left").foregroundStyle(.secondary)
                            Text("Session").gridColumnAlignment(.leading)
                            Text("Weekly").gridColumnAlignment(.leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(summary) { entry in
                            GridRow {
                                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                                meter(entry.session, tint: entry.id == "antigravity" ? .cyan : .mint)
                                meter(entry.weekly, tint: entry.id == "antigravity" ? .cyan : .mint)
                            }
                        }
                    }
                }
                Divider()
                Button(action: openDashboard) {
                    HStack {
                        Text("Open Pulse").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "arrow.up.right").accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(13)
            .frame(width: 282)
            .background(dashboardSurface)
            .preferredColorScheme(.dark)
        }
    }

    private func meter(_ fraction: Double?, tint: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.08))
            GeometryReader { geometry in
                Capsule().fill(tint.opacity(0.30))
                    .frame(width: geometry.size.width * (fraction ?? 0))
            }
            Text(fraction.map(percent) ?? "—")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 19)
        .accessibilityLabel(fraction.map { percent($0) + " remaining" } ?? "Unavailable")
    }
}

@MainActor
final class PulseStatusController: NSObject, ObservableObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private weak var dashboardState: DashboardState?
    private let popover = NSPopover()
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var activation: AnyCancellable?
    private var openDashboard: (() -> Void)?

    func install(state: DashboardState, open: @escaping () -> Void) {
        openDashboard = open
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        item = statusItem
        button.target = self
        button.action = #selector(togglePopover)
        if let url = Bundle.main.url(forResource: "PulseMenu", withExtension: "png"),
           let marker = NSImage(contentsOf: url) {
            if let retina = Bundle.main.url(forResource: "PulseMenu@2x", withExtension: "png"),
               let data = try? Data(contentsOf: retina),
               let representation = NSBitmapImageRep(data: data) {
                representation.size = marker.size
                marker.addRepresentation(representation)
            }
            marker.isTemplate = true
            marker.accessibilityDescription = "Pulse"
            button.image = marker
        } else {
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Pulse")
        }
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Pulse quota summary")
        button.toolTip = "Pulse"
        popover.behavior = .transient
        popover.delegate = self
        dashboardState = state
    }

    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            guard let state = dashboardState else { return }
            popover.contentViewController = NSHostingController(rootView: PulseMenu(state: state) { [weak self] in
                self?.popover.close()
                self?.openDashboard?()
                NSApp.activate(ignoringOtherApps: true)
            })
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if popover.isShown {
                if let window = popover.contentViewController?.view.window {
                    PulseScreenPrivacy.applySaved(to: window)
                }
                observeDismissal()
            } else {
                popover.contentViewController = nil
            }
        }
    }

    private func observeDismissal() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.popover.close()
                return nil
            }
            if event.type != .keyDown, event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.item?.button?.window {
                self.popover.close()
            }
            return event
        }
        activation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
                Task { @MainActor in self?.popover.close() }
            }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
        activation = nil
        popover.contentViewController = nil
    }
}

@MainActor
private enum PulseDock {
    static let preferenceKey = "pulseShowDockIcon"

    static func apply(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

@MainActor
private enum PulseScreenPrivacy {
    static let preferenceKey = "pulseHideFromScreenShare"

    static func apply(_ hidden: Bool) {
        for window in NSApp.windows {
            window.sharingType = hidden ? .none : .readOnly
        }
    }

    static func applySaved(to window: NSWindow) {
        window.sharingType = UserDefaults.standard.bool(forKey: preferenceKey) ? .none : .readOnly
    }
}

@MainActor
private final class T3OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(state: DashboardState, frame: NSRect, dismiss: @escaping () -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: Dashboard(state: state, isEmbeddedOverlay: true,
                                                     dismissOverlay: dismiss))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
        host.layer?.cornerRadius = 12
        host.layer?.borderWidth = 1 / backingScaleFactor
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        host.layer?.masksToBounds = true
        contentView = host
        PulseScreenPrivacy.applySaved(to: self)
    }

    func syncFrame(_ frame: NSRect) {
        let current = self.frame
        let resized = abs(current.width - frame.width) > 0.5 ||
            abs(current.height - frame.height) > 0.5
        let moved = abs(current.minX - frame.minX) > 0.5 ||
            abs(current.minY - frame.minY) > 0.5
        guard resized || moved else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if resized {
            setFrame(frame, display: false, animate: false)
        } else {
            setFrameOrigin(frame.origin)
        }
    }
}

@MainActor
private final class T3OverlayController {
    static let shared = T3OverlayController()

    private var state: DashboardState?
    private var enabled = false
    private var panel: T3OverlayPanel?
    private var suppression: (generation: UInt64, until: TimeInterval)?
    private var openPopovers = Set<ObjectIdentifier>()
    private var popoverObservers: [NSObjectProtocol] = []
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?
    private var localEscapeMonitor: Any?
    private lazy var tracker = T3UsageTracker { [weak self] dialog, frame in
        self?.update(dialog: dialog, frame: frame)
    }
    private var visibleDialog: AXUIElement?

    func install(state: DashboardState) {
        self.state = state
        setEnabled(UserDefaults.standard.bool(forKey: "pulseAttachToT3Usage"))
    }

    func setEnabled(_ enabled: Bool, promptIfNeeded: Bool = false) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            if promptIfNeeded && !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
            preparePanel()
            tracker.start()
        } else {
            tracker.stop()
            suppression = nil
            hidePanel()
            panel = nil
        }
    }

    private func preparePanel() {
        guard panel == nil, let state else { return }
        panel = T3OverlayPanel(state: state, frame: NSRect(x: 0, y: 0, width: 480, height: 640)) { [weak self] in
            self?.closeUsageDialog()
        }
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    private func update(dialog: AXUIElement?, frame: NSRect?) {
        if dialog == nil {
            suppression = nil
            hidePanel()
            return
        }
        if let suppression, suppression.generation == tracker.generation,
           ProcessInfo.processInfo.systemUptime < suppression.until { return }
        suppression = nil
        guard enabled, let dialog, let frame else {
            hidePanel()
            return
        }
        visibleDialog = dialog
        preparePanel()
        guard let panel else { return }
        panel.syncFrame(frame)
        guard !panel.isVisible else { return }
        PulseScreenPrivacy.applySaved(to: panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        popoverObservers = [NSPopover.willShowNotification, NSPopover.didCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let popover = note.object as? NSPopover else { return }
                    let id = ObjectIdentifier(popover)
                    if note.name == NSPopover.willShowNotification {
                        self.openPopovers.insert(id)
                    } else {
                        self.openPopovers.remove(id)
                    }
                }
            }
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isEscape(event) else { return }
            Task { @MainActor in
                guard let self, self.panel?.isVisible == true, self.tracker.isFrontmost,
                      self.openPopovers.isEmpty else { return }
                self.suppression = (self.tracker.generation, ProcessInfo.processInfo.systemUptime + 0.8)
                self.hidePanel()
                self.tracker.rescanAfterEscape()
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible, self.tracker.isFrontmost,
                      self.openPopovers.isEmpty else { return }
                let location = NSEvent.mouseLocation
                guard !panel.frame.contains(location) else { return }
                self.suppression = (self.tracker.generation, ProcessInfo.processInfo.systemUptime + 0.8)
                self.hidePanel()
                self.tracker.rescanAfterEscape()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isEscape(event), let self, let panel = self.panel, event.window === panel,
                  panel.attachedSheet == nil, self.openPopovers.isEmpty else { return event }
            self.closeUsageDialog()
            return nil
        }
    }

    private nonisolated static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty
    }

    private func closeUsageDialog() {
        guard let visibleDialog else { return }
        suppression = (tracker.generation, ProcessInfo.processInfo.systemUptime + 1)
        hidePanel()
        tracker.close(visibleDialog)
    }

    private func hidePanel() {
        visibleDialog = nil
        panel?.orderOut(nil)
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        globalEscapeMonitor = nil
        globalClickMonitor = nil
        localEscapeMonitor = nil
        for token in popoverObservers { NotificationCenter.default.removeObserver(token) }
        popoverObservers.removeAll()
        openPopovers.removeAll()
    }
}

@MainActor
private final class T3UsageTracker {
    private let workspace = NSWorkspace.shared
    private let update: (AXUIElement?, NSRect?) -> Void
    private let axQueue = DispatchQueue(label: "com.pulse.t3-overlay.ax", qos: .userInteractive)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var polling: Timer?
    private var pid: pid_t?
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var window: AXUIElement?
    private var dialog: AXUIElement?
    private var readInFlight = false
    private var pendingRead = false
    private var webArea: AXUIElement?
    private(set) var generation: UInt64 = 0

    var isFrontmost: Bool {
        guard let pid, let frontmost = workspace.frontmostApplication else { return false }
        return frontmost.processIdentifier == pid && !frontmost.isHidden
    }

    init(update: @escaping (AXUIElement?, NSRect?) -> Void) {
        self.update = update
    }

    func start() {
        let notifications = [NSWorkspace.didLaunchApplicationNotification,
                             NSWorkspace.didTerminateApplicationNotification,
                             NSWorkspace.didActivateApplicationNotification,
                             NSWorkspace.didDeactivateApplicationNotification,
                             NSWorkspace.didHideApplicationNotification,
                             NSWorkspace.didUnhideApplicationNotification]
        workspaceObservers = notifications.map { name in
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let changed = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    if changed?.processIdentifier == self.pid,
                       [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                        NSWorkspace.didTerminateApplicationNotification].contains(note.name) {
                        self.disconnect()
                    } else {
                        self.syncFrontmostApplication()
                    }
                }
            }
        }
        syncFrontmostApplication()
    }

    func stop() {
        for token in workspaceObservers { workspace.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        disconnect()
    }

    private func syncFrontmostApplication() {
        guard let frontmost = workspace.frontmostApplication, !frontmost.isHidden,
              frontmost.bundleIdentifier == "com.t3tools.t3code" else {
            disconnect()
            return
        }
        if pid != frontmost.processIdentifier {
            disconnect()
            pid = frontmost.processIdentifier
            resetPolling()
        }
        requestRead()
    }

    private func resetPolling() {
        polling?.invalidate()
        let timer = Timer(timeInterval: dialog == nil ? 0.03 : 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRead() }
        }
        polling = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func disconnect() {
        polling?.invalidate()
        polling = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        generation &+= 1
        pendingRead = false
        observer = nil
        app = nil
        window = nil
        webArea = nil
        dialog = nil
        pid = nil
        update(nil, nil)
    }

    private func handleNotification(_ name: String, from element: AXUIElement) {
        let matchesWindow = window.map { CFEqual($0, element) } ?? false
        let matchesDialog = dialog.map { CFEqual($0, element) } ?? false
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            generation &+= 1
            setDialog(nil)
            update(nil, nil)
            requestRead()
        case kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification:
            guard matchesWindow || matchesDialog else { return }
            generation &+= 1
            setDialog(nil)
            if matchesWindow && name == kAXUIElementDestroyedNotification { setWindow(nil) }
            update(nil, nil)
            requestRead()
        case kAXMovedNotification, kAXResizedNotification:
            guard matchesWindow || matchesDialog else { return }
            requestRead()
        case kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification, kAXWindowDeminiaturizedNotification:
            requestRead()
        default:
            break
        }
    }

    private func observeChange(from old: AXUIElement?, to new: AXUIElement?, names: [String]) {
        guard let observer else { return }
        axQueue.async {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for name in names {
                if let old { AXObserverRemoveNotification(observer, old, name as CFString) }
                if let new { AXObserverAddNotification(observer, new, name as CFString, context) }
            }
        }
    }

    private func setWindow(_ next: AXUIElement?) {
        guard !Self.same(window, next) else { return }
        setDialog(nil)
        observeChange(from: window, to: next, names: [
            kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
            kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
            kAXLayoutChangedNotification
        ])
        window = next
        webArea = nil
        generation &+= 1
    }

    private func setDialog(_ next: AXUIElement?) {
        guard !Self.same(dialog, next) else { return }
        let old = Self.same(window, dialog) ? nil : dialog
        let new = Self.same(window, next) ? nil : next
        if old != nil || new != nil {
            observeChange(from: old, to: new, names: [
                kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification
            ])
        }
        let cadenceChanged = (dialog == nil) != (next == nil)
        dialog = next
        if cadenceChanged { resetPolling() }
        generation &+= 1
    }

    private nonisolated static func same(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        if let first, let second { return CFEqual(first, second) }
        return first == nil && second == nil
    }

    private func requestRead() {
        guard let pid else { return }
        guard isFrontmost else {
            disconnect()
            return
        }
        if readInFlight {
            pendingRead = true
            return
        }
        readInFlight = true
        let generation = self.generation
        let app = self.app
        let window = self.window
        let dialog = self.dialog
        let webArea = self.webArea

        axQueue.async { [weak self] in
            guard let self else { return }
            guard app != nil || AXIsProcessTrusted() else {
                DispatchQueue.main.async {
                    self.finishRead()
                }
                return
            }
            let application = app ?? AXUIElementCreateApplication(pid)
            var newObserver: AXObserver?
            if app == nil {
                AXUIElementSetMessagingTimeout(application, 0.15)
                AXObserverCreate(pid, { observer, element, name, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let tracker = Unmanaged<T3UsageTracker>.fromOpaque(context).takeUnretainedValue()
                        guard tracker.observer === observer else { return }
                        tracker.handleNotification(name as String, from: element)
                    }
                }, &newObserver)
            }
            let result = Self.read(application: application, window: window, webArea: webArea,
                                   dialog: dialog)
            let createdObserver = newObserver
            DispatchQueue.main.async {
                defer { self.finishRead() }
                guard self.generation == generation, self.isFrontmost else { return }
                if self.app == nil {
                    self.app = application
                    self.observer = createdObserver
                    if let createdObserver {
                        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
                        self.observeChange(from: nil, to: application, names: [
                            kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                            kAXFocusedUIElementChangedNotification
                        ])
                    }
                }
                guard result.geometry.error != .cannotComplete else { return }
                self.setWindow(result.window)
                self.webArea = result.webArea
                if result.geometry.rect == nil {
                    self.setDialog(nil)
                    self.update(nil, nil)
                    if dialog != nil { self.requestRead() }
                    return
                }
                self.setDialog(result.dialog)
                self.update(result.dialog, result.geometry.rect.flatMap(self.screenFrame))
            }
        }
    }

    private func finishRead() {
        readInFlight = false
        if pendingRead {
            pendingRead = false
            requestRead()
        }
    }

    private struct Geometry {
        var rect: CGRect? = nil
        var error: AXError = .success
    }

    private nonisolated static func read(application: AXUIElement, window: AXUIElement?,
                                         webArea: AXUIElement?, dialog: AXUIElement?)
        -> (window: AXUIElement?, webArea: AXUIElement?, dialog: AXUIElement?, geometry: Geometry) {
        if let dialog { return (window, webArea, dialog, geometry(of: dialog)) }
        var value: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        if focusError == .cannotComplete { return (window, webArea, nil, Geometry(error: focusError)) }
        guard focusError == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return (nil, nil, nil, Geometry()) }
        let focused = value as! AXUIElement
        let area = (same(window, focused) ? webArea : nil) ?? findWebArea(in: focused)
        guard attribute(kAXMinimizedAttribute, of: focused) != true else {
            return (focused, area, nil, Geometry())
        }
        let usage = usageDialog(in: focused, webArea: area)
        return (focused, area, usage?.dialog, usage?.geometry ?? Geometry())
    }

    func rescanAfterEscape() {
        requestRead()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, generation] in
            guard let self, self.generation == generation else { return }
            self.requestRead()
        }
    }

    func close(_ target: AXUIElement) {
        guard isFrontmost, let pid else { return }
        postEscape(pid: pid, generation: generation)
    }

    private func pressCloseButton(_ button: AXUIElement, target: AXUIElement,
                                  pid: pid_t, generation: UInt64) {
        axQueue.async { [weak self] in
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                DispatchQueue.main.async { self?.postEscape(pid: pid, generation: generation) }
                return
            }
            self?.axQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                let remaining = Self.geometry(of: target)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation, self.isFrontmost else { return }
                    if remaining.rect != nil {
                        self.postEscape(pid: pid, generation: generation)
                    } else {
                        self.requestRead()
                    }
                }
            }
        }
    }

    private func postEscape(pid: pid_t, generation: UInt64) {
        guard self.generation == generation, isFrontmost, self.pid == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.postToPid(pid)
        up.postToPid(pid)
        rescanAfterEscape()
    }

    private nonisolated static func closeButton(in dialog: AXUIElement) -> AXUIElement? {
        if let button: AXUIElement = attribute(kAXCloseButtonAttribute, of: dialog),
           isCloseButton(button) { return button }
        var elements = [dialog]
        var index = 0
        while index < elements.count {
            let element = elements[index]
            index += 1
            if isCloseButton(element) { return element }
            if elements.count < 150 {
                let children: [AXUIElement] = attribute(kAXChildrenAttribute, of: element) ?? []
                elements.append(contentsOf: children.prefix(150 - elements.count))
            }
        }
        return nil
    }

    private nonisolated static func isCloseButton(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(kAXRoleAttribute, of: element)
        guard role == kAXButtonRole else { return false }
        let subrole: String? = attribute(kAXSubroleAttribute, of: element)
        let namedClose = subrole == kAXCloseButtonSubrole ||
            [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                let name: String? = attribute($0, of: element)
                return name?.caseInsensitiveCompare("Close") == .orderedSame
            }
        guard namedClose, attribute(kAXEnabledAttribute, of: element) == true else { return false }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success &&
            (actions as? [String])?.contains(kAXPressAction) == true
    }

    private nonisolated static func findWebArea(in window: AXUIElement) -> AXUIElement? {
        var nodes = [(element: window, depth: 0)]
        var index = 0
        while index < nodes.count {
            let (element, depth) = nodes[index]
            index += 1
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if role == "AXWebArea" { return element }
            switch role {
            case kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole, "AXUnknown":
                if depth < 12, nodes.count < 40 {
                    nodes.append(contentsOf: children(of: element).prefix(40 - nodes.count).map { ($0, depth + 1) })
                }
            default:
                break
            }
        }
        return nil
    }

    private nonisolated static func usageDialog(in window: AXUIElement, webArea: AXUIElement?)
        -> (dialog: AXUIElement, geometry: Geometry)? {
        if let webArea {
            for element in children(of: webArea).reversed() {
                let role: String? = attribute(kAXRoleAttribute, of: element)
                if let match = usageDialog(element, role: role) { return match }
                if role == kAXGroupRole {
                    for child in children(of: element).reversed() {
                        let childRole: String? = attribute(kAXRoleAttribute, of: child)
                        if let match = usageDialog(child, role: childRole) { return match }
                        if childRole == kAXGroupRole {
                            for grandchild in children(of: child).reversed() {
                                if let match = usageDialog(grandchild, role: attribute(kAXRoleAttribute, of: grandchild)) {
                                    return match
                                }
                            }
                        }
                    }
                }
            }
        }

        var nodes = [(element: webArea ?? window, depth: 0)]
        var index = 0
        let maxDepth = webArea == nil ? 12 : 5
        while index < nodes.count {
            let (element, depth) = nodes[index]
            index += 1
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if let match = usageDialog(element, role: role) { return match }
            switch role {
            case kAXScrollAreaRole, kAXListRole, kAXTableRole, kAXStaticTextRole, kAXTextAreaRole, kAXImageRole:
                continue
            default:
                if depth < maxDepth, nodes.count < 80 {
                    nodes.append(contentsOf: children(of: element).reversed().prefix(80 - nodes.count)
                        .map { ($0, depth + 1) })
                }
            }
        }
        return nil
    }

    private nonisolated static func usageDialog(_ element: AXUIElement, role: String?)
        -> (dialog: AXUIElement, geometry: Geometry)? {
        guard role == kAXGroupRole || role == kAXWindowRole || role == kAXSheetRole || role == "AXDialog"
        else { return nil }
        let subrole: String? = attribute(kAXSubroleAttribute, of: element)
        let isDialog = subrole == "AXApplicationDialog" || subrole == "AXDialog" ||
            role == "AXDialog" || role == kAXSheetRole
        guard isDialog || role == kAXGroupRole else { return nil }
        let namedUsage = [kAXTitleAttribute, kAXDescriptionAttribute].contains {
            let name: String? = attribute($0, of: element)
            return name == "Usage"
        }
        guard namedUsage || (isDialog && children(of: element).contains(where: isUsageHeading)) else { return nil }
        let frame = geometry(of: element)
        return frame.rect == nil ? nil : (element, frame)
    }

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) ?? []
    }

    private nonisolated static func isUsageHeading(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(kAXRoleAttribute, of: element)
        guard role == "AXHeading" || role == kAXStaticTextRole else { return false }
        let title: String? = attribute(kAXTitleAttribute, of: element)
        let value: String? = attribute(kAXValueAttribute, of: element)
        return title == "Usage" || value == "Usage"
    }

    private nonisolated static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private nonisolated static func geometry(of element: AXUIElement) -> Geometry {
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute]
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        guard error == .success else { return Geometry(error: error) }
        guard let values = values as? [CFTypeRef], values.count == names.count,
              CFGetTypeID(values[2]) == AXUIElementGetTypeID() else { return Geometry() }
        if let rect = geometry(position: values[0], size: values[1]) {
            return Geometry(rect: rect)
        }
        for value in values.prefix(2) where CFGetTypeID(value) == AXValueGetTypeID() {
            var attributeError = AXError.success
            if AXValueGetValue(value as! AXValue, .axError, &attributeError),
               attributeError == .invalidUIElement || attributeError == .cannotComplete {
                return Geometry(error: attributeError)
            }
        }
        return Geometry()
    }

    private nonisolated static func geometry(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func screenFrame(_ frame: CGRect) -> NSRect? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let rect = NSRect(x: frame.minX, y: primaryScreen.frame.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        return NSScreen.screens.contains { $0.frame.intersects(rect) } ? rect : nil
    }
}

@MainActor
private final class PulseUpdates: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = PulseUpdates()
    @Published private(set) var isUpdateAvailable = false
    lazy var controller = SPUStandardUpdaterController(startingUpdater: true,
                                                       updaterDelegate: nil, userDriverDelegate: self)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        isUpdateAvailable = true
    }

    func standardUserDriverWillFinishUpdateSession() {
        isUpdateAvailable = false
    }
}

final class PulseAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = PulseUpdates.shared.controller
        PulseDock.apply(UserDefaults.standard.bool(forKey: PulseDock.preferenceKey))
        PulseScreenPrivacy.apply(UserDefaults.standard.bool(forKey: PulseScreenPrivacy.preferenceKey))
        NotificationCenter.default.addObserver(self, selector: #selector(applyWindowPrivacy),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    @MainActor @objc private func applyWindowPrivacy(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            PulseScreenPrivacy.applySaved(to: window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct ProviderEntrance: ViewModifier {
    let enabled: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        let hidden = enabled && !visible
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden && !reduceMotion ? 17 : 0)
            .onAppear {
                guard enabled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.20 : 0.62)
                    .delay(reduceMotion ? 0 : 0.15 + Double(min(index, 5)) * 0.13)) {
                    visible = true
                }
            }
    }
}

private struct IntroMotion: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 5 : 0)
            .offset(y: hidden ? 11 : 0)
    }
}

struct PulseDashboardScene: View {
    private enum IntroStage { case waiting, welcome, scanning }

    @ObservedObject var state: DashboardState
    @ObservedObject var status: PulseStatusController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("pulseIntroSeenV3") private var introSeen = false
    @State private var stage: IntroStage = .waiting
    @State private var scanVisible = false
    @State private var revealProviders = false

    private var textTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: IntroMotion(hidden: true), identity: IntroMotion(hidden: false)),
            removal: .opacity
        )
    }

    var body: some View {
        ZStack {
            if introSeen {
                Dashboard(state: state, playsInitialReveal: revealProviders)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            } else {
                introduction
                    .foregroundStyle(Color(white: 0.88))
                    .background(Color(red: 0.135, green: 0.135, blue: 0.146).ignoresSafeArea())
                    .transition(.opacity)
            }
        }
        .frame(width: dashboardWidth)
        .frame(minHeight: 430, maxHeight: .infinity)
        .background(dashboardSurface.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(WindowDefaults())
        .onAppear {
            T3OverlayController.shared.install(state: state)
            status.install(state: state) { openWindow(id: "dashboard") }
            state.alerts.openDashboard = { openWindow(id: "dashboard") }
            if introSeen { state.startMonitoring() }
        }
        .task(id: stage) { await advanceIntroduction() }
        .onChange(of: state.initialScanFinished) { _, finished in
            if finished && scanVisible {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 480))
                    finishIntroduction()
                }
            }
        }
    }

    private var introduction: some View {
        ZStack {
            switch stage {
            case .waiting:
                Color.clear
            case .welcome:
                welcome.transition(textTransition)
            case .scanning:
                scan.transition(textTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            if let icon = PulseArtwork.image("Pulse", extension: "icns") {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text("Welcome to Pulse")
                    .font(PulseType.display(42).weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Text("See your T3 Code subscription limits in one place.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: reduceMotion ? 0.22 : 0.78)) { stage = .scanning }
                state.startMonitoring()
            } label: {
                Label("Check subscriptions", systemImage: "arrow.right")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .tint(Color(white: 0.82))
            .foregroundStyle(Color(white: 0.10))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(24)
    }

    private var scan: some View {
        let total = state.initialScanIDs.count
        let checked = state.initialScanIDs.subtracting(state.pending).count
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scanning your subscriptions")
                    .font(PulseType.display(32).weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Text(total == 0 ? "Reading your T3 Code provider list" : "\(checked) of \(total) accounts checked")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if total > 0 {
                ProgressView(value: Double(checked), total: Double(total))
                    .tint(.white.opacity(0.86))
                    .accessibilityLabel("Subscription scan progress")
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: checked)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Reading T3 Code settings")
            }
            VStack(spacing: 7) {
                ForEach(state.orderedDrivers, id: \.self) { driver in
                    let accounts = state.profiles.filter { $0.driver == driver && state.initialScanIDs.contains($0.id) }
                    let done = accounts.filter { !state.pending.contains($0.id) }.count
                    if done > 0 {
                        HStack(spacing: 9) {
                            ProviderMark(driver: driver, size: 17)
                            Text(T3.providerName(driver)).fontWeight(.medium)
                            Spacer()
                            Text("\(done) / \(accounts.count) checked").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(textTransition)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.48), value: checked)
            .frame(minHeight: 85, alignment: .top)
            Button("Open dashboard") { finishIntroduction() }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 390, alignment: .leading)
    }

    private func advanceIntroduction() async {
        guard !introSeen else { return }
        switch stage {
        case .waiting:
            withAnimation(.easeOut(duration: reduceMotion ? 0.22 : 0.88)) { stage = .welcome }
        case .welcome:
            break
        case .scanning:
            do {
                try await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 1100))
                scanVisible = true
                if state.initialScanFinished { finishIntroduction() }
            } catch {}
        }
    }

    private func finishIntroduction() {
        guard !introSeen else { return }
        revealProviders = true
        withAnimation(.easeInOut(duration: reduceMotion ? 0.22 : 0.72)) {
            introSeen = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            revealProviders = false
        }
    }
}

@main
struct Pulse: App {
    @NSApplicationDelegateAdaptor(PulseAppDelegate.self) private var appDelegate
    @StateObject private var dashboard = DashboardState()
    @StateObject private var status = PulseStatusController()

    init() {
        if CommandLine.arguments.dropFirst().first == "--check-reset-accounts" {
            var failed = false
            for profile in (try? T3.profiles()) ?? [] where profile.driver == "codex" {
                do {
                    _ = try CodexReset.run(profile, key: nil)
                    print(profile.name + ": account verified")
                } catch {
                    print(profile.name + ": " + error.localizedDescription)
                    failed = true
                }
            }
            exit(failed ? EXIT_FAILURE : EXIT_SUCCESS)
        }
        if CommandLine.arguments.dropFirst().first == "--check-inventory" {
            do {
                for profile in try T3.profiles() {
                    print("\(profile.driver) \(profile.name): \(profile.reading?.groups.flatMap(\.buckets).count ?? 0) cached limits")
                }
                exit(EXIT_SUCCESS)
            } catch {
                print(error.localizedDescription)
                exit(EXIT_FAILURE)
            }
        }
    }

    var body: some Scene {
        Window("Pulse", id: "dashboard") {
            PulseDashboardScene(state: dashboard, status: status)
        }
        .defaultSize(width: dashboardWidth, height: 700)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { PulseUpdates.shared.controller.checkForUpdates(nil) }
            }
        }
    }
}

actor CodexReset {
    static let shared = CodexReset()
    private var completed: [String: Date] = [:]

    func redeem(_ selected: Profile) throws -> String {
        guard let current = try T3.profiles().first(where: { $0.id == selected.id }),
              current.driver == "codex", (current.credits ?? 0) > 0,
              current.email == selected.email, let email = current.email else {
            throw QuotaCLI.Failure("T3’s account or credit balance changed. Reopen the details and try again.")
        }
        let account = email.lowercased()
        if let previous = completed[account], current.reading?.captured == previous {
            throw QuotaCLI.Failure("Wait for T3 to refresh the balance before using another credit.")
        }
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        let storageKey = "resetIntent." + digest
        let key = UserDefaults.standard.string(forKey: storageKey) ?? UUID().uuidString
        UserDefaults.standard.set(key, forKey: storageKey)
        let outcome = try Self.run(current, key: key)
        if outcome == "reset" || outcome == "alreadyRedeemed" {
            completed[account] = current.reading?.captured
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
        switch outcome {
        case "reset", "alreadyRedeemed": return "Reset confirmed. The bars update when T3 refreshes its quota cache."
        case "nothingToReset": return "No quota window is eligible for a reset."
        case "noCredit": return "Codex reports no available reset credit."
        default: return "Codex returned an unrecognized reset result. Check T3 before trying again."
        }
    }

    static func run(_ profile: Profile, key: String?) throws -> String {
        try withAccount(profile) { request in
            guard let key else { return "Account verified" }
            let result = try request(3, "account/rateLimitResetCredit/consume", ["idempotencyKey": key])
            guard let outcome = result["outcome"] as? String,
                  ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"].contains(outcome) else {
                throw QuotaCLI.Failure("Codex did not confirm the reset. Check the balance before retrying.")
            }
            return outcome
        }
    }

    static func readQuota(_ profile: Profile) throws -> Snapshot {
        try withAccount(profile) { request in
            let response = try request(3, "account/rateLimits/read", [:])
            guard let limits = response["rateLimits"] as? [String: Any] else {
                throw QuotaCLI.Failure("Codex returned no quota windows.")
            }
            let format = ISO8601DateFormatter()
            let windows = [("primary", "session", "Session"), ("secondary", "weekly", "Weekly")]
            let buckets = windows.compactMap { key, id, label -> Bucket? in
                guard let window = limits[key] as? [String: Any],
                      let used = window["usedPercent"] as? Double, (0...100).contains(used) else { return nil }
                let reset = (window["resetsAt"] as? Double).map { format.string(from: Date(timeIntervalSince1970: $0)) }
                return Bucket(id: id, name: label, remainingFraction: 1 - used / 100,
                              resetTime: reset, durationMinutes: window["windowDurationMins"] as? Double)
            }
            guard !buckets.isEmpty else { throw QuotaCLI.Failure("Codex returned no quota windows.") }
            return Snapshot(email: profile.email ?? "", captured: .now,
                            groups: [QuotaGroup(name: "Subscription", buckets: buckets)],
                            plan: AccountPlan.codex(limits["planType"] as? String))
        }
    }

    private static func withAccount<T>(_ profile: Profile,
        body: ((Int, String, [String: Any]) throws -> [String: Any]) throws -> T
    ) throws -> T {
        let config = profile.codexConfig
        guard config?.launchArgs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw QuotaCLI.Failure("This profile uses custom Codex launch arguments. Redeem it in T3 Code.")
        }
        let home = [config?.shadowHomePath, config?.homePath].compactMap { $0 }.first { !$0.isEmpty }
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        let configured = config?.binaryPath ?? ""
        let choices = configured.isEmpty || configured == "codex"
            ? [local, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            : [(configured as NSString).expandingTildeInPath]
        guard let binary = choices.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw QuotaCLI.Failure("The Codex CLI for this profile could not be found.")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["id": id, "method": method, "params": params])
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          reply["id"] as? Int == id else { continue }
                    if let result = reply["result"] as? [String: Any] { return result }
                    throw QuotaCLI.Failure("Codex declined the request or does not support this action.")
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else {
                    throw QuotaCLI.Failure("Codex did not confirm the request. Check the balance before retrying.")
                }
                buffer.append(chunk)
            }
        }
        _ = try request(1, "initialize", ["clientInfo": ["name": "subscription_usage", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized"])
        let account = try request(2, "account/read", ["refreshToken": false])
        guard let identity = account["account"] as? [String: Any],
              let email = identity["email"] as? String,
              email.caseInsensitiveCompare(profile.email ?? "") == .orderedSame else {
            throw QuotaCLI.Failure("The CLI sign-in doesn’t match this T3 account. No credit was used.")
        }
        return try body(request)
    }
}
