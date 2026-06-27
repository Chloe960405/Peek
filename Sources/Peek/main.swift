import AppKit
import Foundation
import Security
import SwiftUI

@main
struct PeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 24)
    private let popover = NSPopover()
    private let store = UsageStore()
    private var refreshTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        self.statusItem.button?.image = StatusIconRenderer.image(codex: nil, claude: nil)
        self.statusItem.button?.imagePosition = .imageOnly
        self.statusItem.button?.title = ""
        self.statusItem.button?.toolTip = "Peek"
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(togglePopover)

        self.popover.behavior = .transient
        self.popover.delegate = self
        self.popover.contentSize = NSSize(width: 320, height: 490)
        let hostingController = NSHostingController(rootView: ContentView(store: self.store))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.popover.contentViewController = hostingController

        self.store.onChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.statusItem.button?.title = ""
                self?.statusItem.button?.image = StatusIconRenderer.image(
                    codex: state.codex?.primary?.usedPercent,
                    claude: state.claude?.primary?.usedPercent)
            }
        }

        Task { await self.store.refresh() }
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.store.refresh()
            }
        }
    }

    @MainActor
    @objc private func togglePopover() {
        guard let button = self.statusItem.button else { return }
        if self.popover.isShown {
            self.popover.performClose(nil)
        } else {
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.startOutsideClickMonitoring()
            Task { await self.store.refreshIfStale() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        self.stopOutsideClickMonitoring()
    }

    private func startOutsideClickMonitoring() {
        self.stopOutsideClickMonitoring()

        self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopover()
            }
        }

        self.localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if self.shouldKeepPopoverOpen(for: event) {
                return event
            }
            self.closePopover()
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func closePopover() {
        if self.popover.isShown {
            self.popover.performClose(nil)
        }
        self.stopOutsideClickMonitoring()
    }

    private func shouldKeepPopoverOpen(for event: NSEvent) -> Bool {
        guard self.popover.isShown else { return true }
        if event.window === self.popover.contentViewController?.view.window {
            return true
        }
        if let buttonWindow = self.statusItem.button?.window, event.window === buttonWindow {
            return true
        }
        return false
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state = AppUsageState()
    var onChange: ((AppUsageState) -> Void)?

    init() {
        self.state.codex = UsageCache.load(providerID: "codex")
        self.state.claude = UsageCache.load(providerID: "claude")
        self.state.updatedAt = UsageCache.latestUpdatedAt()
    }

    func refreshIfStale() async {
        if let updatedAt = self.state.updatedAt,
           Date().timeIntervalSince(updatedAt) < 5 * 60
        {
            return
        }
        await self.refresh()
    }

    func refresh() async {
        self.state.isRefreshing = true
        self.onChange?(self.state)

        let codexResult: Result<ProviderUsage, Error>
        do {
            codexResult = .success(try await UsageFetcher.fetchCodex())
        } catch {
            codexResult = .failure(error)
        }

        let claudeResult: Result<ProviderUsage, Error>
        do {
            claudeResult = .success(try await UsageFetcher.fetchClaude())
        } catch {
            claudeResult = .failure(error)
        }

        switch codexResult {
        case let .success(usage):
            self.state.codex = usage
            self.state.codexError = nil
            UsageCache.save(usage)
        case let .failure(error):
            if self.state.codex == nil {
                self.state.codex = UsageCache.load(providerID: "codex")
            }
            self.state.codexError = error.localizedDescription
        }

        switch claudeResult {
        case let .success(usage):
            self.state.claude = usage
            self.state.claudeError = nil
            UsageCache.save(usage)
        case let .failure(error):
            if self.state.claude == nil {
                self.state.claude = UsageCache.load(providerID: "claude")
            }
            self.state.claudeError = error.localizedDescription
        }

        self.state.isRefreshing = false
        self.state.updatedAt = UsageCache.latestUpdatedAt()
        self.onChange?(self.state)
    }
}

struct AppUsageState {
    var codex: ProviderUsage?
    var claude: ProviderUsage?
    var codexError: String?
    var claudeError: String?
    var isRefreshing = false
    var updatedAt: Date?
}

struct ProviderUsage: Identifiable {
    let id: String
    let name: String
    let account: String?
    let plan: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let accent: Color
}

struct UsageWindow: Identifiable {
    let id = UUID()
    let title: String
    let usedPercent: Double
    let resetAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - self.usedPercent))
    }
}

enum UsageCache {
    static func load(providerID: String) -> ProviderUsage? {
        guard let payload = try? JSONDecoder().decode(CachedUsagePayload.self, from: Data(contentsOf: fileURL(providerID: providerID))) else {
            return nil
        }
        return payload.usage.providerUsage
    }

    static func save(_ usage: ProviderUsage) {
        let payload = CachedUsagePayload(updatedAt: Date(), usage: CachedProviderUsage(usage))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let directory = cacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(providerID: usage.id), options: .atomic)
    }

    static func latestUpdatedAt() -> Date? {
        ["codex", "claude"].compactMap { providerID -> Date? in
            guard let payload = try? JSONDecoder().decode(CachedUsagePayload.self, from: Data(contentsOf: fileURL(providerID: providerID))) else {
                return nil
            }
            return payload.updatedAt
        }.max()
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Peek", isDirectory: true)
    }

    private static func fileURL(providerID: String) -> URL {
        cacheDirectory().appendingPathComponent("\(providerID)-usage.json")
    }
}

struct CachedUsagePayload: Codable {
    let updatedAt: Date
    let usage: CachedProviderUsage
}

struct CachedProviderUsage: Codable {
    let id: String
    let name: String
    let account: String?
    let plan: String?
    let primary: CachedUsageWindow?
    let secondary: CachedUsageWindow?

    init(_ usage: ProviderUsage) {
        self.id = usage.id
        self.name = usage.name
        self.account = usage.account
        self.plan = usage.plan
        self.primary = usage.primary.map(CachedUsageWindow.init)
        self.secondary = usage.secondary.map(CachedUsageWindow.init)
    }

    var providerUsage: ProviderUsage {
        ProviderUsage(
            id: self.id,
            name: self.name,
            account: self.account,
            plan: self.plan,
            primary: self.primary?.usageWindow,
            secondary: self.secondary?.usageWindow,
            accent: self.id == "claude"
                ? Color(red: 0.78, green: 0.43, blue: 0.34)
                : Color(red: 0.24, green: 0.64, blue: 0.70))
    }
}

struct CachedUsageWindow: Codable {
    let title: String
    let usedPercent: Double
    let resetAt: Date?

    init(_ window: UsageWindow) {
        self.title = window.title
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
    }

    var usageWindow: UsageWindow {
        UsageWindow(title: self.title, usedPercent: self.usedPercent, resetAt: self.resetAt)
    }
}

enum UsageFetcher {
    static func fetchCodex() async throws -> ProviderUsage {
        let credentials = try CodexCredentials.load()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Peek", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let rateLimit = decoded.rateLimit
        return ProviderUsage(
            id: "codex",
            name: "Codex",
            account: credentials.accountLabel,
            plan: decoded.planType?.capitalized,
            primary: rateLimit?.primaryWindow?.usageWindow(title: "会话"),
            secondary: rateLimit?.secondaryWindow?.usageWindow(title: "每周"),
            accent: Color(red: 0.24, green: 0.64, blue: 0.70))
    }

    static func fetchClaude() async throws -> ProviderUsage {
        let credentials = try await CredentialStore.shared.loadClaudeCredentials()
        return try await Self.fetchClaude(using: credentials, allowsCredentialReload: true)
    }

    private static func fetchClaude(using credentials: ClaudeCredentials, allowsCredentialReload: Bool) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(credentials.cliVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        if allowsCredentialReload, http.statusCode == 401 || http.statusCode == 403 {
            await CredentialStore.shared.clearClaudeCredentials()
            let credentials = try await CredentialStore.shared.loadClaudeCredentials()
            return try await Self.fetchClaude(using: credentials, allowsCredentialReload: false)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FetchError.authenticationExpired("Claude Code 未登录或登录已过期，请运行 claude auth login")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return ProviderUsage(
            id: "claude",
            name: "Claude",
            account: "Claude Code",
            plan: nil,
            primary: decoded.fiveHour?.usageWindow(title: "会话"),
            secondary: decoded.sevenDay?.usageWindow(title: "每周"),
            accent: Color(red: 0.78, green: 0.43, blue: 0.34))
    }
}

actor CredentialStore {
    static let shared = CredentialStore()

    private var claudeCredentials: ClaudeCredentials?

    func loadClaudeCredentials() throws -> ClaudeCredentials {
        if let claudeCredentials {
            return claudeCredentials
        }
        let credentials = try ClaudeCredentials.loadFromKeychain()
        self.claudeCredentials = credentials
        return credentials
    }

    func clearClaudeCredentials() {
        self.claudeCredentials = nil
    }
}

enum FetchError: LocalizedError {
    case missingCredentials(String)
    case invalidCredentials(String)
    case authenticationExpired(String)
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .missingCredentials(message):
            message
        case let .invalidCredentials(message):
            message
        case let .authenticationExpired(message):
            message
        case .invalidResponse:
            "响应格式无效"
        case let .httpStatus(code):
            code == 429 ? "请求太频繁，稍后会自动恢复" : "HTTP \(code)"
        }
    }
}

struct CodexCredentials {
    let accessToken: String
    let accountId: String?
    let accountLabel: String?

    static func load() throws -> CodexCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let url = path.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw FetchError.missingCredentials("找不到 ~/.codex/auth.json")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidCredentials("Codex auth.json 不是有效 JSON")
        }
        if let apiKey = object["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexCredentials(accessToken: apiKey, accountId: nil, accountLabel: nil)
        }
        guard let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens.stringValue("access_token", "accessToken"),
              !accessToken.isEmpty
        else {
            throw FetchError.invalidCredentials("Codex auth.json 缺少 access token")
        }
        return CodexCredentials(
            accessToken: accessToken,
            accountId: tokens.stringValue("account_id", "accountId"),
            accountLabel: nil)
    }
}

struct ClaudeCredentials {
    let accessToken: String
    let cliVersion: String

    static func loadFromKeychain() throws -> ClaudeCredentials {
        let password: String
        do {
            password = try Keychain.genericPassword(service: "Claude Code-credentials", account: NSUserName())
        } catch FetchError.missingCredentials {
            password = try Keychain.genericPassword(service: "Claude Code-credentials", account: nil)
        }
        guard let data = password.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth.stringValue("accessToken", "access_token"),
              !accessToken.isEmpty
        else {
            throw FetchError.invalidCredentials("Claude Code Keychain 凭据格式无法识别")
        }
        return ClaudeCredentials(accessToken: accessToken, cliVersion: Self.detectCLIVersion() ?? "2.1.0")
    }

    private static func detectCLIVersion() -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(homeDirectory)/.local/bin/claude",
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
        } catch {
            return nil
        }
    }
}

enum Keychain {
    static func genericPassword(service: String, account: String?) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw FetchError.missingCredentials("找不到 Keychain 项：\(service)")
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidCredentials("Keychain 项不是文本")
        }
        return value
    }
}

struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexWindow: Decodable {
    let usedPercent: Double
    let resetAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    func usageWindow(title: String) -> UsageWindow {
        UsageWindow(
            title: title,
            usedPercent: self.usedPercent,
            resetAt: self.resetAt.map { Date(timeIntervalSince1970: $0) })
    }
}

struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    func usageWindow(title: String) -> UsageWindow {
        UsageWindow(
            title: title,
            usedPercent: self.utilization ?? 0,
            resetAt: DateParser.iso8601(self.resetsAt))
    }
}

enum DateParser {
    static func iso8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension Dictionary where Key == String, Value == Any {
    func stringValue(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ProviderCard(
                        usage: store.state.codex,
                        error: store.state.codexError,
                        fallbackName: "Codex",
                        accent: Color(red: 0.24, green: 0.64, blue: 0.70),
                        dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage"))
                    ProviderCard(
                        usage: store.state.claude,
                        error: store.state.claudeError,
                        fallbackName: "Claude",
                        accent: Color(red: 0.78, green: 0.43, blue: 0.34),
                        dashboardURL: URL(string: "https://claude.ai/settings/usage"))
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 320, height: 490)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
    }

    private var header: some View {
        HStack {
            Text("Peek")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if store.state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(updatedText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            FooterActionButton("刷新") {
                Task { await store.refresh() }
            }
            FooterActionButton("退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var updatedText: String {
        guard let date = store.state.updatedAt else { return "尚未刷新" }
        return "更新 \(date.formatted(date: .omitted, time: .shortened))"
    }
}

struct FooterActionButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(minWidth: 46, minHeight: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var backgroundColor: Color {
        if isPressed {
            return Color.primary.opacity(0.18)
        }
        if isHovering {
            return Color.primary.opacity(0.12)
        }
        return .clear
    }
}

struct ProviderCard: View {
    let usage: ProviderUsage?
    let error: String?
    let fallbackName: String
    let accent: Color
    let dashboardURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage?.name ?? fallbackName)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let account = usage?.account {
                        Text(account)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let plan = usage?.plan {
                        Text(plan)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if usage == nil {
                ProgressView()
                    .controlSize(.small)
            }

            if let primary = usage?.primary {
                WindowRow(window: primary, accent: accent)
            }
            if let secondary = usage?.secondary {
                WindowRow(window: secondary, accent: accent)
            }

            if let dashboardURL {
                Button("打开 Usage 页面") {
                    DashboardOpener.open(dashboardURL)
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

enum DashboardOpener {
    static func open(_ url: URL) {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(resetText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: window.usedPercent / 100, color: accent)
                .frame(height: 7)
            HStack {
                Text("\(Int(window.remainingPercent.rounded()))% 剩余")
                Spacer()
                Text("已用 \(Int(window.usedPercent.rounded()))%")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard let resetAt = window.resetAt else { return "重置时间未知" }
        let interval = resetAt.timeIntervalSinceNow
        if interval <= 0 { return "即将重置" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h 后重置"
        }
        return "\(hours)h \(minutes)m 后重置"
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.13))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, proxy.size.width * min(max(value, 0), 1)))
            }
        }
    }
}

enum StatusIconRenderer {
    static func image(codex: Double?, claude: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        drawBar(rect: NSRect(x: 1.5, y: 9.5, width: 15, height: 6), used: codex)
        drawBar(rect: NSRect(x: 1.5, y: 2.5, width: 15, height: 4), used: claude)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawBar(rect: NSRect, used: Double?) {
        let radius = rect.height / 2
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSColor.black.withAlphaComponent(0.28).setFill()
        trackPath.fill()

        let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: max(0, radius - 0.5),
            yRadius: max(0, radius - 0.5))
        strokePath.lineWidth = 1
        NSColor.black.withAlphaComponent(0.44).setStroke()
        strokePath.stroke()

        guard let used else { return }
        let remaining = max(0, min(100, 100 - used)) / 100
        let fillWidth = (rect.width * CGFloat(remaining) * 2).rounded() / 2
        guard fillWidth > 0 else { return }

        NSGraphicsContext.current?.cgContext.saveGState()
        trackPath.addClip()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
}
