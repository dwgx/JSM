import Foundation
import Combine
import Darwin
#if canImport(Yams)
import Yams
#endif
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

@MainActor
public final class AppStore: ObservableObject {
    public enum JavaDetectMode {
        case fast
        case full
    }
    public struct JavaAuthorizationRequest: Identifiable {
        public let id: UUID
        public let reason: String
        public let suggestedHome: URL?

        public init(reason: String, suggestedHome: URL?) {
            self.id = UUID()
            self.reason = reason
            self.suggestedHome = suggestedHome
        }
    }

    @Published public private(set) var servers: [ServerDefinition] = []
    @Published public private(set) var runtimes: [UUID: ServerRuntime] = [:]
    @Published public private(set) var logs: [UUID: [String]] = [:]
    @Published public var selectedServerID: UUID?
    @Published public var metricsInterval: TimeInterval = 2.0 { didSet { if !isLoadingSettings { saveSettings() } } }
    @Published public var consoleRenderer: ConsoleRenderer = .native { didSet { if !isLoadingSettings { saveSettings() } } }
    @Published public var themeAppearance: ThemeAppearance = .system { didSet { if !isLoadingSettings { saveSettings() } } }
    @Published public var processStopStrategy: ProcessStopStrategy = .stopSignalThenManualForce { didSet { if !isLoadingSettings { saveSettings() } } }
    @Published public var javaExecutable: String = "" {
        didSet {
            refreshJavaUsability()
            if !isLoadingSettings { saveSettings() }
        }
    }
    @Published public private(set) var lastStartedServerIDs: [UUID] = [] { didSet { if !isLoadingSettings { saveSettings() } } }
    @Published public var lastErrorMessage: String?
    @Published public private(set) var javaAuthorizationRequest: JavaAuthorizationRequest?
    @Published public private(set) var javaIsUsable: Bool = false
    @Published public private(set) var javaBookmarkIsUsable: Bool = false
    @Published public private(set) var javaBookmarkBlocksExecution: Bool = false
    @Published public private(set) var forceStopAvailableServerIDs: Set<UUID> = []

    private let serverStore: ServerStore
    private let settingsStore: SettingsStore
    private let processController: ProcessController
    private let metricsProvider: MetricsProvider
    private var metricsTimer: DispatchSourceTimer?
    private var isLoadingSettings = false
    private var javaExecutableBookmark: Data? {
        didSet {
            refreshJavaUsability()
            if !isLoadingSettings { saveSettings() }
        }
    }
    private var pendingStartServerID: UUID?
    private var stopRequestedServerIDs: Set<UUID> = []
    private var stopTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var restartAttempts: [UUID: Int] = [:]
    private var hasRecordedStartThisSession = false
    private var pendingInputs: [UUID: [String]] = [:]
    private let manualForceTimeoutSeconds: TimeInterval = 5

    enum AppStoreError: LocalizedError {
        case accessDenied
        case workspaceNotAuthorized(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "权限不足：操作失败（未获得访问权限）。"
            case .workspaceNotAuthorized(let path):
                return "权限不足：无法访问工作目录：\(path)。请重新选择工作目录并授予权限。"
            }
        }
    }

    public init(serverStore: ServerStore,
                settingsStore: SettingsStore,
                processController: ProcessController,
                metricsProvider: MetricsProvider) {
        self.serverStore = serverStore
        self.settingsStore = settingsStore
        self.processController = processController
        self.metricsProvider = metricsProvider
        self.processController.onTermination = { [weak self] id, reason, status in
            Task { @MainActor in
                self?.handleProcessTermination(definitionID: id, reason: reason, status: status)
            }
        }
        loadSettings()
        loadServers()
        startMetricsTimer()
    }

    public convenience init() {
        self.init(serverStore: ServerStore(),
                  settingsStore: SettingsStore(),
                  processController: ProcessController(),
                  metricsProvider: MetricsProvider())
    }

    public func loadServers() {
        do {
            servers = try serverStore.load()
            if selectedServerID == nil {
                selectedServerID = servers.first?.id
            }
            reconcileLastStartedServerIDs()
        } catch {
            servers = []
        }
    }

    public func saveServers() {
        do {
            try serverStore.save(servers)
        } catch {
            lastErrorMessage = "保存服务器列表失败：\(error)"
        }
    }

    public func addServer(_ definition: ServerDefinition) {
        servers.append(definition)
        selectedServerID = definition.id
        saveServers()
    }

    public func createServer(name: String,
                             workspaceURL: URL,
                             entry: ServerEntry,
                             javaOptions: [String] = [],
                             programArgs: [String] = [],
                             env: [String: String] = [:],
                             lifecycle: LifecyclePolicy) throws {
        let bookmark: Bookmark
        do {
            bookmark = try Bookmark.create(for: workspaceURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 256 {
                throw AppStoreError.workspaceNotAuthorized(workspaceURL.path(percentEncoded: false))
            }
            throw error
        }
        let definition = ServerDefinition(name: name,
                                          workspaceBookmark: bookmark.data,
                                          entry: entry,
                                          javaOptions: javaOptions,
                                          programArgs: programArgs,
                                          env: env,
                                          lifecycle: lifecycle)
        addServer(definition)
    }

    public func updateServer(_ definition: ServerDefinition) {
        guard let index = servers.firstIndex(where: { $0.id == definition.id }) else { return }
        servers[index] = definition
        saveServers()
    }

    public func removeServer(id: UUID) {
        clearStopControls(for: id)
        if let runtime = runtimes[id] {
            stopRequestedServerIDs.insert(id)
            Task { await processController.stop(runtime: runtime) }
        }
        servers.removeAll { $0.id == id }
        runtimes[id] = nil
        logs[id] = nil
        restartAttempts[id] = nil
        lastStartedServerIDs.removeAll { $0 == id }
        if pendingStartServerID == id { pendingStartServerID = nil }
        if selectedServerID == id { selectedServerID = servers.first?.id }
        saveServers()
    }

    public func importServer(from url: URL, workspaceURL: URL) throws {
        try withScopedAccess(to: url) { scopedURL in
            let loader = ConfigLoader()
            let bookmark = try Bookmark.create(for: workspaceURL)
            let config = try loader.loadServerConfig(from: scopedURL)
            let definition = config.toDefinition(workspaceBookmark: bookmark.data)
            addServer(definition)
        }
    }

    public func importBundle(from url: URL, workspaceURL: URL) throws {
#if canImport(ZIPFoundation) && canImport(Yams)
        try withScopedAccess(to: url) { scopedURL in
            let archive = try Archive(url: scopedURL, accessMode: .read)
            guard let entry = archive["server.yaml"] else { return }
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let serverURL = tempDir.appendingPathComponent("server.yaml")
            _ = try archive.extract(entry, to: serverURL)
            let yaml = try String(contentsOf: serverURL, encoding: .utf8)
            let decoder = YAMLDecoder()
            let bookmark = try Bookmark.create(for: workspaceURL)
            if let config = try? decoder.decode(ServerConfig.self, from: yaml) {
                let definition = config.toDefinition(workspaceBookmark: bookmark.data)
                addServer(definition)
            } else {
                var definition = try decoder.decode(ServerDefinition.self, from: yaml)
                definition.workspaceBookmark = bookmark.data
                addServer(definition)
            }
        }
#else
        _ = url
        _ = workspaceURL
#endif
    }

    public func exportServer(id: UUID, to destination: URL) throws {
        guard let definition = servers.first(where: { $0.id == id }) else { return }
        let exporter = BundleExporter()
        try withScopedAccess(to: destination) { scopedURL in
            try exporter.exportServerBundle(definition: definition,
                                            includeWorkspace: true,
                                            includeTheme: false,
                                            to: scopedURL)
        }
    }

    public func yaml(for id: UUID) -> String {
#if canImport(Yams)
        guard let definition = servers.first(where: { $0.id == id }) else { return "" }
        let encoder = YAMLEncoder()
        let config = ServerConfig(definition: definition)
        return (try? encoder.encode(config)) ?? ""
#else
        return ""
#endif
    }

    public func updateFromYAML(_ yaml: String, id: UUID) throws {
#if canImport(Yams)
        let decoder = YAMLDecoder()
        if let config = try? decoder.decode(ServerConfig.self, from: yaml),
           let existing = servers.first(where: { $0.id == id }) {
            let updated = config.applying(to: existing)
            updateServer(updated)
        } else {
            var definition = try decoder.decode(ServerDefinition.self, from: yaml)
            definition.id = id
            updateServer(definition)
        }
#else
        _ = yaml
        _ = id
#endif
    }

    public func startServer(id: UUID) async {
        await startServerInternal(id: id, isAutomaticRestart: false)
    }

    private func startServerInternal(id: UUID, isAutomaticRestart: Bool) async {
        guard let definition = servers.first(where: { $0.id == id }) else { return }
        if let runtime = runtimes[id] {
            switch runtime.state {
            case .running, .starting:
                appendLog("[JSM] 进程已在运行，无需重复启动。", id: id)
                return
            case .stopping:
                appendLog("[JSM] 正在关闭中，请等待退出后再启动。", id: id)
                return
            case .stopped, .crashed:
                break
            }
        }
        let baseDefinition = applyingJavaSandboxCompatibility(to: definition)
        let normalization = normalizeEntry(for: baseDefinition)
        if let error = normalization.error {
            lastErrorMessage = error
            appendLog("[JSM] \(error)", id: id)
            return
        }
        let (effectiveDefinition, javaWarnings) = sanitizeJavaOptions(for: normalization.server)
        let warnings = normalization.warnings + javaWarnings
        let didNormalize = normalizationDidChange(original: definition, normalized: effectiveDefinition)
        if !isAutomaticRestart {
            restartAttempts[id] = 0
        }
        if !warnings.isEmpty {
            for warning in warnings {
                appendLog("[JSM] \(warning)", id: id)
            }
        }
        if didNormalize && !isAutomaticRestart {
            updateServer(effectiveDefinition)
            appendLog("[JSM] 已自动修正启动配置并保存。", id: id)
        }
        if javaExecutableValue == nil {
            // Trigger best-effort auto detection so we can prompt for authorization immediately if needed.
            _ = await autoDetectJava()
        }
        if javaAuthorizationRequest != nil {
            pendingStartServerID = id
            return
        }

        if let preflightError = await preflightWorkspaceChecks(server: effectiveDefinition) {
            lastErrorMessage = preflightError
            appendLog("[JSM] \(preflightError)", id: id)
            return
        }

        processController.javaExecutable = javaExecutableValue
        do {
            clearStopControls(for: id)
            if let existing = runtimes[id] {
                var runtime = existing
                runtime.state = .starting
                runtime.startTime = Date()
                runtimes[id] = runtime
            } else {
                runtimes[id] = ServerRuntime(definitionID: id, state: .starting, startTime: Date())
            }
            appendLog("[JSM] 启动中…", id: id)
            appendLog("[JSM] 命令: \(commandPreview(for: effectiveDefinition))", id: id)
            let runtime = try await processController.start(server: effectiveDefinition)
            runtimes[id] = runtime
            let existing = logs[id] ?? []
            logs[id] = existing + runtime.logBuffer.snapshot()
            if let pid = runtime.pid {
                appendLog("[JSM] 已启动（pid=\(pid)）", id: id)
            } else {
                appendLog("[JSM] 已启动", id: id)
            }
            processController.attachStdout(for: runtime) { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line, id: id)
                }
            }
            processController.attachStderr(for: runtime) { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line, id: id)
                }
            }
            if let queued = pendingInputs[id], !queued.isEmpty {
                for line in queued {
                    await processController.sendInput(line, to: runtime)
                }
                pendingInputs[id] = []
                appendLog("[JSM] 已发送缓存命令 \(queued.count) 条。", id: id)
            }
            if !isAutomaticRestart {
                recordLastStartedServer(id: id)
            }
        } catch {
            if var runtime = runtimes[id] {
                runtime.state = .crashed
                runtime.pid = nil
                runtimes[id] = runtime
            }
            appendLog("[JSM] 启动失败：\(error)", id: id)
            if case ProcessControllerError.javaNotFound(let candidate) = error {
                if hasJavaExecutableBookmark, javaBookmarkBlocksExecution {
                    let message = """
Java 授权已保存，但仍无法执行：\(candidate ?? (javaExecutableValue ?? "(未配置)"))。
这通常是 App Sandbox 限制导致（禁止执行该路径下的可执行文件）。
建议：改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），或在工程 entitlements 放行对应路径，或仅本地开发时关闭 App Sandbox。
（可在 设置 → Java Runtime 点击“自检”查看详细信息）
"""
                    lastErrorMessage = message
                    appendLog("[JSM] \(message)", id: id)
                    return
                }

                // In sandbox, Java under ~/.sdkman (and similar) is not accessible until user grants permission.
                // Instead of only showing an error, request an authorization flow.
                pendingStartServerID = id
                let suggested = inferredJavaHomeURL(from: candidate ?? javaExecutableValue)
                    ?? JavaLocator.likelyJavaHomeDirectories().first
                let reason = hasJavaExecutableBookmark
                    ? "Java 路径不可用：请重新选择 Java Home（或直接选择 bin/java）并授权访问。"
                    : "已检测到 Java 路径，但当前未保存授权（App Sandbox）。请选择 Java Home（或直接选择 bin/java）授予权限，之后启动将不再提示。"
                appendLog("[JSM] \(reason)", id: id)
                requestJavaAuthorization(reason: reason, suggestedHome: suggested)
            } else if case ProcessControllerError.workspaceAccessDenied = error {
                let message = "权限不足：工作目录未授权或书签无效。请在“编辑服务器”中重新选择工作目录后保存。"
                lastErrorMessage = message
                appendLog("[JSM] \(message)", id: id)
            } else if case ProcessControllerError.javaAccessDenied = error {
                if hasJavaExecutableBookmark, javaBookmarkBlocksExecution {
                    let message = """
Java 授权已保存，但仍无法执行：\(javaExecutableValue ?? "(未配置)")。
这通常是 App Sandbox 限制导致（禁止执行该路径下的可执行文件）。
建议：改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），或在工程 entitlements 放行对应路径，或仅本地开发时关闭 App Sandbox。
（可在 设置 → Java Runtime 点击“自检”查看详细信息）
"""
                    lastErrorMessage = message
                    appendLog("[JSM] \(message)", id: id)
                    return
                }
                pendingStartServerID = id
                let suggested = inferredJavaHomeURL(from: javaExecutableValue) ?? JavaLocator.likelyJavaHomeDirectories().first
                let reason = "Java Home 权限不足或授权已失效：请重新选择 Java Home（或 bin/java）并授权访问。"
                appendLog("[JSM] \(reason)", id: id)
                requestJavaAuthorization(reason: reason, suggestedHome: suggested)
            } else if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 256 {
                let message = "工作目录书签无效或来自旧版本。请在“编辑服务器”中重新选择工作目录后保存。"
                lastErrorMessage = message
                appendLog("[JSM] \(message)", id: id)
            } else {
                let message = "启动失败：\(error)"
                lastErrorMessage = message
                appendLog("[JSM] \(message)", id: id)
            }
        }
    }

    private func recordLastStartedServer(id: UUID) {
        var updated = hasRecordedStartThisSession ? lastStartedServerIDs : []
        hasRecordedStartThisSession = true
        updated.removeAll { $0 == id }
        updated.append(id)
        lastStartedServerIDs = updated
    }

    private func reconcileLastStartedServerIDs() {
        let valid = Set(servers.map(\.id))
        let filtered = lastStartedServerIDs.filter { valid.contains($0) }
        if filtered != lastStartedServerIDs {
            lastStartedServerIDs = filtered
        }
    }

    private func applyingJavaSandboxCompatibility(to server: ServerDefinition) -> ServerDefinition {
        let sandboxed = isAppSandboxed
        // When JSM is sandboxed, the spawned Java process inherits the sandbox. On newer macOS versions this can
        // prevent dlopen() of ad-hoc-signed native libraries that some server stacks try to load (JLine/JNA),
        // resulting in noisy warnings but typically not affecting server operation. Since JSM doesn't provide an
        // interactive TTY console, we prefer a "dumb" terminal provider by default to reduce native loads.
        var defaults: [String] = [
            "-Dorg.jline.terminal.providers=dumb",
            "-Dorg.jline.terminal.dumb=true",
            "-Dorg.jline.terminal.jna=false",
            "-Dorg.jline.terminal.jni=false",
            "-Dorg.jline.terminal.jansi=false",
            "-Dorg.jline.terminal.exec=false",
            "-Dio.netty.transport.noNative=true"
        ]
        if sandboxed {
            // Prevent JNA from extracting native dylibs into the sandbox (which triggers Gatekeeper dialogs).
            defaults.append(contentsOf: [
                "-Djna.nosys=true",
                "-Djna.nounpack=true"
            ])
        }

        var merged: [String] = []
        for option in defaults {
            if let keyPrefix = systemPropertyPrefix(for: option),
               server.javaOptions.contains(where: { $0.hasPrefix(keyPrefix) }) {
                continue
            }
            if server.javaOptions.contains(option) { continue }
            merged.append(option)
        }
        guard !merged.isEmpty else { return server }

        var copy = server
        copy.javaOptions = merged + copy.javaOptions
        return copy
    }

    private func normalizationDidChange(original: ServerDefinition, normalized: ServerDefinition) -> Bool {
        if original.entry.kind != normalized.entry.kind { return true }
        if original.entry.path != normalized.entry.path { return true }
        if original.entry.mainClass != normalized.entry.mainClass { return true }
        if original.javaOptions != normalized.javaOptions { return true }
        if original.programArgs != normalized.programArgs { return true }
        return false
    }

    private func preflightWorkspaceChecks(server: ServerDefinition) async -> String? {
        let bookmark = Bookmark(data: server.workspaceBookmark)
        do {
            let scope = try SecurityScopedResource(bookmark: bookmark)
            guard scope.startAccessing() else {
                return "权限不足：工作目录未授权或书签无效。请重新选择工作目录。"
            }
            defer { scope.stopAccessing() }

            if isAppSandboxed {
                appendLog("[JSM] 当前运行在 App Sandbox 中，可能无法移除隔离标记，且子进程可能触发系统验证弹窗。建议在开发环境关闭 App Sandbox。", id: server.id)
            } else {
                appendLog("[JSM] App Sandbox 已关闭。", id: server.id)
            }

            // If the app bundle itself is quarantined, macOS will propagate quarantine to files we create.
            let appURL = Bundle.main.bundleURL
            if Quarantine.hasQuarantine(at: appURL) {
                if Quarantine.removeQuarantine(at: appURL) {
                    appendLog("[JSM] 已清除应用本体的隔离标记。", id: server.id)
                } else {
                    appendLog("[JSM] 无法清除应用本体的隔离标记，后续创建的文件可能继续被系统隔离。", id: server.id)
                }
            }

            let workspaceResult = Quarantine.clearQuarantine(in: scope.url,
                                                             fileExtensions: ["jar", "dylib", "jnilib", "so"],
                                                             includeDirectories: true)
            appendLog("[JSM] 隔离标记扫描（工作目录）：扫描 \(workspaceResult.scanned)，清除 \(workspaceResult.removed)，失败 \(workspaceResult.failed)。", id: server.id)
            if workspaceResult.failed > 0 {
                let errInfo = workspaceResult.lastError.map { " errno=\($0) \(String(cString: strerror($0)))" } ?? ""
                appendLog("[JSM] 部分文件无法清除隔离标记，可能仍会触发系统验证弹窗。\(errInfo)", id: server.id)
            }

            // Prepare a stable JNA temp directory inside the workspace to avoid Gatekeeper prompts in random temp paths.
            let jnaTemp = scope.url.appendingPathComponent(".jna", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: jnaTemp, withIntermediateDirectories: true)
                _ = Quarantine.removeQuarantine(at: jnaTemp)
            } catch {
                appendLog("[JSM] 无法创建 JNA 临时目录：\(error.localizedDescription)", id: server.id)
            }

            var cacheRoots: [URL] = []
            if let sandboxCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                cacheRoots.append(sandboxCaches)
            }
            let userCaches = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
            if !cacheRoots.contains(userCaches) {
                cacheRoots.append(userCaches)
            }

            for cacheRoot in cacheRoots {
                let cacheResult = Quarantine.clearQuarantine(in: cacheRoot,
                                                             fileExtensions: ["dylib", "jnilib", "so", "tmp"],
                                                             includeDirectories: true)
                appendLog("[JSM] 隔离标记扫描（缓存）：扫描 \(cacheResult.scanned)，清除 \(cacheResult.removed)，失败 \(cacheResult.failed)。", id: server.id)
                if cacheResult.failed > 0 {
                    let errInfo = cacheResult.lastError.map { " errno=\($0) \(String(cString: strerror($0)))" } ?? ""
                    appendLog("[JSM] 缓存目录清除隔离标记失败。\(errInfo)", id: server.id)
                }
            }

            if let lockError = checkWorldLocks(workspaceURL: scope.url) {
                return lockError
            }
        } catch {
            return "工作目录书签解析失败：\(error)"
        }
        return nil
    }

    private func checkWorldLocks(workspaceURL: URL) -> String? {
        let lockFiles = [
            workspaceURL.appendingPathComponent("world/session.lock"),
            workspaceURL.appendingPathComponent("world_nether/session.lock"),
            workspaceURL.appendingPathComponent("world_the_end/session.lock")
        ]
        for url in lockFiles {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let fd = open(url.path, O_RDONLY)
            if fd < 0 { continue }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK {
                    return "世界数据已被其他实例占用：\(url.path)。请先关闭其他服务器或确认无实例后删除 session.lock。"
                }
            } else {
                _ = flock(fd, LOCK_UN)
            }
        }
        return nil
    }

    private func systemPropertyPrefix(for javaOption: String) -> String? {
        guard javaOption.hasPrefix("-D") else { return nil }
        guard let eq = javaOption.firstIndex(of: "=") else { return nil }
        return String(javaOption[..<javaOption.index(after: eq)])
    }

    private var isAppSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private struct JavaJarCommand {
        let jarPath: String
        let javaOptions: [String]
        let programArgs: [String]
    }

    private func normalizeCommandDashes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "﹣", with: "-")
            .replacingOccurrences(of: "－", with: "-")
    }

    private func splitCommandLine(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character? = nil

        for ch in text {
            if ch == "\"" || ch == "'" {
                if inQuotes && ch == quoteChar {
                    inQuotes = false
                    quoteChar = nil
                    continue
                } else if !inQuotes {
                    inQuotes = true
                    quoteChar = ch
                    continue
                }
            }

            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func parseJavaJarCommand(from raw: String) -> JavaJarCommand? {
        let normalized = normalizeCommandDashes(raw)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = splitCommandLine(trimmed)
        guard !tokens.isEmpty else { return nil }

        var startIndex = 0
        let first = tokens.first?.lowercased() ?? ""
        if first == "java" || first.hasSuffix("/java") || first.hasSuffix("\\java") {
            startIndex = 1
        }

        var jarIndex: Int?
        if let flag = tokens.firstIndex(of: "-jar"), flag + 1 < tokens.count {
            jarIndex = flag + 1
        } else if let idx = tokens.firstIndex(where: { $0.lowercased().hasSuffix(".jar") }) {
            jarIndex = idx
        }

        guard let jarIndex else { return nil }

        let javaOptions: [String]
        if let flag = tokens.firstIndex(of: "-jar"), flag > startIndex {
            javaOptions = Array(tokens[startIndex..<flag])
        } else if jarIndex > startIndex {
            javaOptions = Array(tokens[startIndex..<jarIndex])
        } else {
            javaOptions = []
        }

        let jarPath = tokens[jarIndex]
        let programArgs = jarIndex + 1 < tokens.count ? Array(tokens[(jarIndex + 1)...]) : []
        return JavaJarCommand(jarPath: jarPath, javaOptions: javaOptions, programArgs: programArgs)
    }

    private func looksLikeJavaCommand(_ raw: String) -> Bool {
        let lower = normalizeCommandDashes(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains(" -jar ") || lower.hasPrefix("java ") || lower.hasSuffix(".jar") || lower.contains(".jar ")
    }

    private func prependUnique(_ items: [String], to list: [String]) -> [String] {
        guard !items.isEmpty else { return list }
        var result = list
        for item in items.reversed() where !result.contains(item) {
            result.insert(item, at: 0)
        }
        return result
    }

    private struct EntryNormalizationResult {
        var server: ServerDefinition
        var warnings: [String]
        var error: String?
    }

    private func normalizeEntry(for server: ServerDefinition) -> EntryNormalizationResult {
        var updated = server
        var warnings: [String] = []

        switch server.entry.kind {
        case .mainClass:
            let raw = server.entry.mainClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                return EntryNormalizationResult(server: updated, warnings: warnings, error: "MainClass 未配置：请填写完整类名，或改为 Jar 类型。")
            }
            if looksLikeJavaCommand(raw), let parsed = parseJavaJarCommand(from: raw) {
                warnings.append("检测到 MainClass 中包含 java -jar 命令，已自动改为 Jar 启动。")
                updated.entry = ServerEntry(kind: .jar, path: parsed.jarPath)
                updated.javaOptions = prependUnique(parsed.javaOptions, to: updated.javaOptions)
                updated.programArgs = prependUnique(parsed.programArgs, to: updated.programArgs)
            } else if raw.contains(" ") || raw.contains("\t") {
                return EntryNormalizationResult(server: updated,
                                                warnings: warnings,
                                                error: "MainClass 不能包含空格或 -jar，请改为 Jar 类型或填写完整类名。")
            }

        case .jar:
            let raw = server.entry.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                return EntryNormalizationResult(server: updated, warnings: warnings, error: "Jar 路径未配置：请填写 jar 文件路径。")
            }
            if looksLikeJavaCommand(raw), let parsed = parseJavaJarCommand(from: raw) {
                if parsed.jarPath != raw {
                    warnings.append("检测到 Jar 路径中包含 java -jar 命令，已自动提取 jar 文件路径。")
                }
                updated.entry.path = parsed.jarPath
                updated.javaOptions = prependUnique(parsed.javaOptions, to: updated.javaOptions)
                updated.programArgs = prependUnique(parsed.programArgs, to: updated.programArgs)
            }

        case .script:
            let raw = server.entry.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                return EntryNormalizationResult(server: updated, warnings: warnings, error: "脚本路径未配置：请填写脚本文件路径。")
            }
        }

        var extractedFromArgs: JavaJarCommand?
        var cleanedArgs: [String] = []
        for arg in updated.programArgs {
            let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = normalizeCommandDashes(trimmed).lowercased()
            if (lower.contains("java") || lower.contains("-jar")),
               let parsed = parseJavaJarCommand(from: trimmed) {
                if extractedFromArgs == nil {
                    extractedFromArgs = parsed
                }
                cleanedArgs.append(contentsOf: parsed.programArgs)
                updated.javaOptions = prependUnique(parsed.javaOptions, to: updated.javaOptions)
                continue
            }
            cleanedArgs.append(trimmed)
        }
        updated.programArgs = cleanedArgs

        if let parsed = extractedFromArgs {
            switch updated.entry.kind {
            case .jar:
                if (updated.entry.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    updated.entry.path = parsed.jarPath
                    warnings.append("检测到 Program Args 中包含 java -jar 命令，已自动提取 jar 文件路径。")
                } else {
                    warnings.append("检测到 Program Args 中包含 java -jar 命令，已忽略 java/-jar，仅保留其参数。")
                }
            case .mainClass:
                warnings.append("检测到 Program Args 中包含 java -jar 命令，已自动改为 Jar 启动。")
                updated.entry = ServerEntry(kind: .jar, path: parsed.jarPath)
            case .script:
                warnings.append("检测到 Program Args 中包含 java -jar 命令，但当前类型为 Script，请检查配置。")
            }
        }

        return EntryNormalizationResult(server: updated, warnings: warnings, error: nil)
    }

    private func commandPreview(for server: ServerDefinition) -> String {
        let java = javaExecutableValue ?? "java"
        let javaOptions = server.javaOptions.joined(separator: " ")
        let programArgs = server.programArgs.joined(separator: " ")

        switch server.entry.kind {
        case .jar:
            let jar = server.entry.path ?? "(未配置)"
            var parts: [String] = [java]
            if !javaOptions.isEmpty { parts.append(javaOptions) }
            parts.append("-jar")
            parts.append(jar)
            if !programArgs.isEmpty { parts.append(programArgs) }
            return parts.joined(separator: " ")
        case .mainClass:
            let mainClass = server.entry.mainClass ?? "(未配置)"
            var parts: [String] = [java]
            if !javaOptions.isEmpty { parts.append(javaOptions) }
            parts.append(mainClass)
            if !programArgs.isEmpty { parts.append(programArgs) }
            return parts.joined(separator: " ")
        case .script:
            let script = server.entry.path ?? "(未配置)"
            var parts: [String] = [script]
            if !programArgs.isEmpty { parts.append(programArgs) }
            return parts.joined(separator: " ")
        }
    }

    private func sanitizeJavaOptions(for server: ServerDefinition) -> (ServerDefinition, [String]) {
        var warnings: [String] = []
        var filtered: [String] = []

        for option in server.javaOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if parseJavaJarCommand(from: trimmed) != nil {
                warnings.append("检测到无效 Java 选项“\(option)”。Jar 启动命令不应放在 Java Options 中，已忽略。")
                continue
            }

            let normalized = normalizeCommandDashes(trimmed)
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            if normalized == "-jar" || normalized == "java-jar" || normalized == "java" {
                warnings.append("检测到无效 Java 选项“\(option)”。Jar 类型会自动添加 -jar，本项已忽略。")
                continue
            }

            filtered.append(trimmed)
        }

        guard filtered != server.javaOptions else { return (server, warnings) }
        var copy = server
        copy.javaOptions = filtered
        return (copy, warnings)
    }

    public func stopServer(id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        if runtime.state == .stopping { return }

        stopRequestedServerIDs.insert(id)
        if pendingStartServerID == id { pendingStartServerID = nil }

        clearStopTimeout(for: id)
        forceStopAvailableServerIDs.remove(id)

        var updated = runtime
        updated.state = .stopping
        runtimes[id] = updated

        switch processStopStrategy {
        case .stopSignalThenManualForce:
            appendLog("[JSM] 正在发送停止信号（\(Int(manualForceTimeoutSeconds)) 秒无响应可强制关闭）…", id: id)
            await processController.stop(runtime: runtime)
            scheduleStopTimeout(for: id, autoForce: false)
        case .stopSignalThenAutoForce:
            appendLog("[JSM] 正在发送停止信号（\(Int(manualForceTimeoutSeconds)) 秒后自动强制）…", id: id)
            await processController.stop(runtime: runtime)
            scheduleStopTimeout(for: id, autoForce: true)
        case .immediateForceKill:
            appendLog("[JSM] 正在强制关闭进程…", id: id)
            await processController.forceStop(runtime: runtime)
        }
    }

    public func forceStopServer(id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        stopRequestedServerIDs.insert(id)
        clearStopControls(for: id)
        appendLog("[JSM] 已发送强制关闭（SIGKILL）。", id: id)
        await processController.forceStop(runtime: runtime)
    }

    public func restartServer(id: UUID) async {
        await stopServer(id: id)
        let stopped = await waitUntilStopped(id: id, timeout: 15)
        guard stopped else {
            appendLog("[JSM] 重启中止：进程仍未退出，请点击“强制关闭”后重试。", id: id)
            return
        }
        await startServerInternal(id: id, isAutomaticRestart: false)
    }

    private func scheduleStopTimeout(for id: UUID, autoForce: Bool) {
        clearStopTimeout(for: id)
        let delayNs = UInt64(manualForceTimeoutSeconds * 1_000_000_000)
        stopTimeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self, !Task.isCancelled else { return }
            let running = await processController.isRunning(definitionID: id)
            guard running else { return }

            if autoForce {
                appendLog("[JSM] 停止超时，正在执行强制关闭…", id: id)
                await forceStopServer(id: id)
            } else {
                forceStopAvailableServerIDs.insert(id)
                appendLog("[JSM] 关闭超时：可点击“强制关闭”。", id: id)
            }
        }
    }

    private func clearStopTimeout(for id: UUID) {
        stopTimeoutTasks[id]?.cancel()
        stopTimeoutTasks[id] = nil
    }

    private func clearStopControls(for id: UUID) {
        clearStopTimeout(for: id)
        forceStopAvailableServerIDs.remove(id)
    }

    private func waitUntilStopped(id: UUID, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = await processController.isRunning(definitionID: id)
            if !running {
                if var runtime = runtimes[id], runtime.state == .stopping {
                    runtime.state = .stopped
                    runtime.pid = nil
                    runtimes[id] = runtime
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    public func sendInput(_ text: String, id: UUID) async {
        guard let runtime = runtimes[id], runtime.state == .running else {
            pendingInputs[id, default: []].append(text)
            appendLog("[JSM] 进程未运行，输入已缓存，启动后自动发送。", id: id)
            return
        }
        await processController.sendInput(text, to: runtime)
    }

    public func runtime(for id: UUID) -> ServerRuntime? { runtimes[id] }

    public func logs(for id: UUID) -> [String] { logs[id] ?? [] }

    public func server(for id: UUID?) -> ServerDefinition? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    public func setMetricsInterval(_ interval: TimeInterval) {
        metricsInterval = interval
        restartMetricsTimer()
    }

    public func setJavaExecutable(_ path: String?) {
        javaExecutable = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        processController.javaExecutable = javaExecutableValue
    }

    public func setJavaExecutableFromUserInput(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            javaExecutableBookmark = nil
            processController.javaExecutableBookmark = nil
            setJavaExecutable(nil)
            return
        }
        let url = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: url.path) {
            setJavaExecutable(url: url)
        } else {
            javaExecutableBookmark = nil
            processController.javaExecutableBookmark = nil
            setJavaExecutable(trimmed)
        }
    }

    public func setJavaExecutable(url: URL) {
        let fileManager = FileManager.default

        let homeURL = inferJavaHome(from: url)
        let resolvedHomeURL = homeURL.resolvingSymlinksInPath()
        let homeJavaPath = homeURL.appendingPathComponent("bin/java").path
        let resolvedJavaPath = resolvedHomeURL.appendingPathComponent("bin/java").path

        // Prefer a bookmark to the resolved path, but fall back to the user-selected path
        // (e.g. SDKMAN's `current` symlink) if the resolved target isn't accessible yet.
        if let bookmark = try? Bookmark.create(for: resolvedHomeURL) {
            javaExecutableBookmark = bookmark.data
            processController.javaExecutableBookmark = bookmark
            javaExecutable = resolvedJavaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let bookmark = try? Bookmark.create(for: homeURL) {
            javaExecutableBookmark = bookmark.data
            processController.javaExecutableBookmark = bookmark
            javaExecutable = homeJavaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if fileManager.isExecutableFile(atPath: resolvedJavaPath) {
            // System-installed JDKs are often readable/executable without a user-scoped bookmark.
            javaExecutableBookmark = nil
            processController.javaExecutableBookmark = nil
            javaExecutable = resolvedJavaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if fileManager.isExecutableFile(atPath: homeJavaPath) {
            javaExecutableBookmark = nil
            processController.javaExecutableBookmark = nil
            javaExecutable = homeJavaPath.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                javaExecutableBookmark = nil
                processController.javaExecutableBookmark = nil
                javaExecutable = homeJavaPath.trimmingCharacters(in: .whitespacesAndNewlines)
                requestJavaAuthorization(reason: "已找到 Java 位置，但缺少授权（App Sandbox）。请选择 Java Home（或直接选择 bin/java）以授予权限。", suggestedHome: homeURL)
            }

        processController.javaExecutable = javaExecutableValue
    }

    /// Apply a user selection from the file picker to configure and authorize Java.
    /// The `url` must come from an Open/Save panel in a sandboxed app (Powerbox) so it carries security scope.
    @discardableResult
    public func applyJavaHomeSelection(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        func bookmarkAllowsJavaExecution(_ bookmark: Bookmark, javaPath: String) -> Bool {
            do {
                let resource = try SecurityScopedResource(bookmark: bookmark)
                guard resource.startAccessing() else { return false }
                defer { resource.stopAccessing() }
                let scopeURL = resource.url.standardizedFileURL
                let javaURL = URL(fileURLWithPath: javaPath).standardizedFileURL

                var isDir: ObjCBool = false
                let exists = fileManager.fileExists(atPath: scopeURL.path, isDirectory: &isDir)
                let isDirectory = exists ? isDir.boolValue : scopeURL.hasDirectoryPath

                let scopeCandidates = [
                    scopeURL.path,
                    scopeURL.resolvingSymlinksInPath().standardizedFileURL.path
                ]
                let javaCandidates = [
                    javaURL.path,
                    javaURL.resolvingSymlinksInPath().standardizedFileURL.path
                ]

                let isWithinScope: Bool = {
                    if isDirectory {
                        for scopePath in scopeCandidates {
                            let prefix = scopePath.hasSuffix("/") ? scopePath : "\(scopePath)/"
                            if javaCandidates.contains(where: { $0.hasPrefix(prefix) }) {
                                return true
                            }
                        }
                        return false
                    }
                    return scopeCandidates.contains(where: { javaCandidates.contains($0) })
                }()

                return isWithinScope && fileManager.isExecutableFile(atPath: javaPath)
            } catch {
                return false
            }
        }

        // Use the Powerbox-scoped URL directly for probing. Creating+resolving a bookmark immediately can
        // change the URL (especially for symlinks like SDKMAN `current`) and may lose the temporary access.
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }

        // Persist the selection so future launches can re-open the same location.
        let selectionBookmark: Bookmark
        do {
            selectionBookmark = try Bookmark.create(for: url)
        } catch {
            lastErrorMessage = "无法创建 Java 授权书签：\(error)"
            return false
        }

        // Also activate the resolved bookmark URL while probing. This can be necessary for symlink-heavy layouts
        // (e.g. SDKMAN `current`), where the Powerbox URL may not grant stable access to the resolved target.
        let resolvedSelectionURL = (try? selectionBookmark.resolve())?.standardizedFileURL
        let resolvedStarted = resolvedSelectionURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if resolvedStarted, let resolvedSelectionURL {
                resolvedSelectionURL.stopAccessingSecurityScopedResource()
            }
        }

        let standardizedSelectionURL = url.standardizedFileURL
        let looksLikeBinJava = standardizedSelectionURL.lastPathComponent == "java"
            && standardizedSelectionURL.deletingLastPathComponent().lastPathComponent == "bin"
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: standardizedSelectionURL.path, isDirectory: &isDir)
        let treatAsFile = looksLikeBinJava || (exists && !isDir.boolValue)
        if treatAsFile {
            // Allow selecting the java executable directly (e.g. .../bin/java).
            guard standardizedSelectionURL.lastPathComponent == "java" else {
                lastErrorMessage = "请选择 Java Home 目录（包含 bin/java），或直接选择 bin/java 可执行文件。"
                return false
            }

            let resolvedJavaPath: String? = resolvedSelectionURL.flatMap { resolved in
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    return resolved.appendingPathComponent("bin/java").path(percentEncoded: false)
                }
                return resolved.path(percentEncoded: false)
            }
            var candidates: [String] = [
                standardizedSelectionURL.path(percentEncoded: false),
                standardizedSelectionURL.resolvingSymlinksInPath().path(percentEncoded: false)
            ]
            if let resolvedJavaPath {
                candidates.append(resolvedJavaPath)
            }
            guard let chosenJavaPath = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
                if let blocked = candidates.first(where: {
                    fileManager.fileExists(atPath: $0)
                        && fileManager.isReadableFile(atPath: $0)
                        && !fileManager.isExecutableFile(atPath: $0)
                }) {
                    lastErrorMessage = """
已找到 java，但当前沙盒禁止执行：\(blocked)。
建议：改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），或在工程 entitlements 放行对应路径，或仅本地开发时关闭 App Sandbox。
（可在 设置 → Java Runtime 点击“自检”查看详细信息）
"""
                } else {
                    lastErrorMessage = "所选 java 文件不可执行或不可访问。请改为选择 Java Home 目录（包含 bin/java）。"
                }
                return false
            }

            let inferredHome = inferJavaHome(from: URL(fileURLWithPath: chosenJavaPath))
            var bookmarkCandidates: [Bookmark] = []
            if let homeBookmark = try? Bookmark.create(for: inferredHome) {
                bookmarkCandidates.append(homeBookmark)
            }
            bookmarkCandidates.append(selectionBookmark)
            guard let chosenBookmark = bookmarkCandidates.first(where: {
                bookmarkAllowsJavaExecution($0, javaPath: chosenJavaPath)
            }) else {
                if fileManager.fileExists(atPath: chosenJavaPath),
                   fileManager.isReadableFile(atPath: chosenJavaPath),
                   !fileManager.isExecutableFile(atPath: chosenJavaPath) {
                    lastErrorMessage = """
Java 授权已保存，但沙盒仍禁止执行：\(chosenJavaPath)。
建议：改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），或在工程 entitlements 放行对应路径，或仅本地开发时关闭 App Sandbox。
（可在 设置 → Java Runtime 点击“自检”查看详细信息）
"""
                } else {
                    lastErrorMessage = "Java 授权已保存，但仍无法访问所选 java 可执行文件。请重新选择 Java Home 目录（包含 bin/java）。"
                }
                return false
            }
            javaExecutableBookmark = chosenBookmark.data
            processController.javaExecutableBookmark = chosenBookmark
            setJavaExecutable(chosenJavaPath)

            retryPendingStartIfNeeded()
            return true
        }

        // Treat selection as directory.
        let selectionResolvedSymlinksURL = standardizedSelectionURL.resolvingSymlinksInPath().standardizedFileURL
        var bases: [URL] = [standardizedSelectionURL, selectionResolvedSymlinksURL]
        if let resolvedSelectionURL {
            bases.append(resolvedSelectionURL)
            bases.append(resolvedSelectionURL.resolvingSymlinksInPath().standardizedFileURL)
        }
        func uniqueByPath(_ urls: [URL]) -> [URL] {
            var seen: Set<String> = []
            var results: [URL] = []
            for value in urls {
                let path = value.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                results.append(value.standardizedFileURL)
            }
            return results
        }
        bases = uniqueByPath(bases)

        var homeCandidates: [URL] = []
        for base in bases {
            homeCandidates.append(base)
            homeCandidates.append(contentsOf: candidateJavaHomes(from: base))
        }
        for base in bases {
            if let discovered = discoverJavaHome(oneLevelUnder: base) {
                homeCandidates.append(discovered)
            }
        }
        homeCandidates = uniqueByPath(homeCandidates)

        struct JavaProbe {
            let home: URL
            let javaURL: URL
            let exists: Bool
            let executable: Bool
        }

        let probes: [JavaProbe] = homeCandidates.compactMap { candidate in
            let home = inferJavaHome(from: candidate).standardizedFileURL
            let javaURL = home.appendingPathComponent("bin/java")
            let exists = fileManager.fileExists(atPath: javaURL.path)
            guard exists else { return nil }
            let executable = fileManager.isExecutableFile(atPath: javaURL.path)
            return JavaProbe(home: home, javaURL: javaURL, exists: exists, executable: executable)
        }

        guard let chosen = probes.first(where: { $0.executable }) ?? probes.first else {
            let isSymlink = (try? standardizedSelectionURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if isSymlink, selectionResolvedSymlinksURL.path != standardizedSelectionURL.path {
                lastErrorMessage = """
未在所选位置找到 Java（bin/java）。
你选择的是符号链接：\(standardizedSelectionURL.path) → \(selectionResolvedSymlinksURL.path)
建议改选实际 JDK 目录（例如：\(selectionResolvedSymlinksURL.path)），或直接选择：\(standardizedSelectionURL.appendingPathComponent("bin/java").path)
"""
            } else {
                lastErrorMessage = "未在所选位置找到 Java（bin/java）。请选择 Java Home 目录（包含 bin/java），或直接选择 bin/java 可执行文件。"
            }
            return false
        }

        let javaPath = chosen.javaURL.path
        var bookmarkCandidates: [Bookmark] = []
        if let homeBookmark = try? Bookmark.create(for: chosen.home) {
            bookmarkCandidates.append(homeBookmark)
        }
        bookmarkCandidates.append(selectionBookmark)

        guard let chosenBookmark = bookmarkCandidates.first(where: {
            bookmarkAllowsJavaExecution($0, javaPath: javaPath)
        }) else {
            if fileManager.fileExists(atPath: javaPath),
               fileManager.isReadableFile(atPath: javaPath),
               !fileManager.isExecutableFile(atPath: javaPath) {
                lastErrorMessage = """
Java 授权已保存，但沙盒仍禁止执行：\(javaPath)。
建议：改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），或在工程 entitlements 放行对应路径，或仅本地开发时关闭 App Sandbox。
（可在 设置 → Java Runtime 点击“自检”查看详细信息）
"""
            } else {
                lastErrorMessage = "Java 授权已保存，但仍无法访问 bin/java。请重新选择 Java Home（建议直接选择 bin/java 可执行文件）。"
            }
            return false
        }

        javaExecutableBookmark = chosenBookmark.data
        processController.javaExecutableBookmark = chosenBookmark
        setJavaExecutable(javaPath)

        retryPendingStartIfNeeded()
        return true
    }

    @discardableResult
    public func autoDetectJava(mode: JavaDetectMode = .full) async -> Bool {
        if hasUsableJavaConfiguration { return true }
        if javaAuthorizationRequest != nil { return false }

        let candidate = await Task.detached(priority: .utility) { () -> String? in
            switch mode {
            case .fast:
                return JavaLocator.findJavaExecutableFast()
            case .full:
                if let detected = JavaLocator.findJavaExecutable() {
                    return detected
                }
                if let home = JavaLocator.javaHomeFromSystem() {
                    return (home as NSString).appendingPathComponent("bin/java")
                }
                return JavaLocator.guessJavaExecutableFromShell()
            }
        }.value

        guard let candidate, !candidate.isEmpty else { return false }

        if FileManager.default.isExecutableFile(atPath: candidate) {
            setJavaExecutable(url: URL(fileURLWithPath: candidate))
            return hasUsableJavaConfiguration
        }

        // We found a likely java location but cannot access it under App Sandbox until the user authorizes.
        javaExecutableBookmark = nil
        processController.javaExecutableBookmark = nil
        setJavaExecutable(candidate)
        let suggested = inferredJavaHomeURL(from: candidate) ?? JavaLocator.likelyJavaHomeDirectories().first
        requestJavaAuthorization(reason: "检测到 Java，但需要先授权 Java Home（App Sandbox）。请选择 Java Home（或直接选择 bin/java）。", suggestedHome: suggested)
        return true
    }

    public var hasJavaExecutableBookmark: Bool {
        javaExecutableBookmark != nil
    }

    public var hasUsableJavaConfiguration: Bool {
        javaIsUsable
    }

    public func requestJavaAuthorization(reason: String, suggestedHome: URL?) {
        javaAuthorizationRequest = JavaAuthorizationRequest(reason: reason, suggestedHome: suggestedHome)
    }

    public func clearJavaAuthorizationRequest(id: UUID) {
        if javaAuthorizationRequest?.id == id {
            javaAuthorizationRequest = nil
        }
    }

    public func cancelPendingStart() {
        pendingStartServerID = nil
    }

    private nonisolated static func resolveDNS(host: String, port: String = "443") -> (ok: Bool, error: String?) {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, port, &hints, &res)
        if code == 0 {
            if let res { freeaddrinfo(res) }
            return (true, nil)
        }
        return (false, String(cString: gai_strerror(code)))
    }

    public func diagnosticsReport() async -> String {
        enum Level: Int {
            case ok = 0
            case warn = 1
            case fail = 2
        }

        func label(_ level: Level) -> String {
            switch level {
            case .ok: return "通过"
            case .warn: return "警告"
            case .fail: return "失败"
            }
        }

        func item(_ level: Level, _ text: String) -> String {
            "- [\(label(level))] \(text)"
        }

        func info(_ text: String) -> String {
            "- \(text)"
        }

        func entryMisconfigMessages(_ server: ServerDefinition) -> [String] {
            var messages: [String] = []
            switch server.entry.kind {
            case .mainClass:
                let raw = server.entry.mainClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let normalized = normalizeCommandDashes(raw)
                let lower = normalized.lowercased()
                if raw.contains(" ") || raw.contains("\t") {
                    messages.append("MainClass 包含空格（看起来不是类名）。")
                }
                if parseJavaJarCommand(from: normalized) != nil || lower.contains("-jar") || lower.contains(".jar") || lower.hasPrefix("java ") {
                    messages.append("MainClass 看起来是 java -jar 命令，应该改为 Jar 类型。")
                }
            case .jar:
                let raw = server.entry.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let normalized = normalizeCommandDashes(raw)
                let lower = normalized.lowercased()
                if parseJavaJarCommand(from: normalized) != nil && normalized != raw {
                    messages.append("Jar 路径包含 java -jar 命令，请只填写 jar 文件名/路径。")
                } else if lower.contains(" -jar ") || lower.hasPrefix("java ") || lower.contains("java -jar") {
                    messages.append("Jar 路径包含 java -jar 命令，请只填写 jar 文件名/路径。")
                }
            case .script:
                break
            }

            let argsContainJavaCommand = server.programArgs.contains { raw in
                let normalized = normalizeCommandDashes(raw)
                let lower = normalized.lowercased()
                return (lower.contains("java") || lower.contains("-jar")) && parseJavaJarCommand(from: normalized) != nil
            }
            if argsContainJavaCommand {
                messages.append("Program Args 包含 java -jar 命令，应只填写程序参数。")
            }

            let optionsContainJavaCommand = server.javaOptions.contains { raw in
                let normalized = normalizeCommandDashes(raw)
                let lower = normalized.lowercased()
                return (lower.contains("java") || lower.contains("-jar")) && parseJavaJarCommand(from: normalized) != nil
            }
            if optionsContainJavaCommand {
                messages.append("Java Options 包含 java -jar 命令，应只填写 JVM 选项（如 -Xmx）。")
            }
            return messages
        }

        let fm = FileManager.default
        refreshJavaUsability()

        var suggestions: [String] = []

        func uniqueSuggestions(_ values: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if seen.insert(value).inserted {
                    result.append(value)
                }
            }
            return result
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

#if arch(arm64)
        let arch = "arm64"
#elseif arch(x86_64)
        let arch = "x86_64"
#else
        let arch = "unknown"
#endif

        // --- Java ---
        var javaLines: [String] = []
        var javaLevel: Level = .ok

        let configuredJava = javaExecutableValue ?? "(未配置)"
        javaLines.append(info("配置路径: \(configuredJava)"))
        javaLines.append(info("书签: \(javaExecutableBookmark == nil ? "无" : "有")"))
        javaLines.append(info("可用: \(hasUsableJavaConfiguration ? "是" : "否")"))

        if hasUsableJavaConfiguration {
            javaLevel = .ok
        } else if javaExecutableValue == nil {
            javaLevel = .fail
            javaLines.append(item(.fail, "未配置 Java Runtime。"))
            suggestions.append("在 设置 → Java Runtime 点击“自动分析并修复”，或手动选择 Java Home（包含 bin/java）。")
        } else if hasJavaExecutableBookmark, javaBookmarkBlocksExecution {
            javaLevel = .fail
            javaLines.append(item(.fail, "已授权，但沙盒禁止执行该 Java。"))
            suggestions.append("建议改用系统/包管理器安装的 JDK（如 /Library/Java/JavaVirtualMachines 或 Homebrew），避免 ~/.sdkman 等受限路径。")
        } else {
            javaLevel = .warn
            javaLines.append(item(.warn, "Java 路径已配置，但当前不可执行/不可访问。"))
            suggestions.append("在 设置 → Java Runtime 重新选择 Java Home（或直接选择 bin/java）并授权。")
        }

        if let java = javaExecutableValue, !java.isEmpty {
            javaLines.append(info("路径存在: \(fm.fileExists(atPath: java) ? "是" : "否")"))
            javaLines.append(info("可读: \(fm.isReadableFile(atPath: java) ? "是" : "否")"))
            javaLines.append(info("可执行: \(fm.isExecutableFile(atPath: java) ? "是" : "否")"))
        }

        if let bookmarkData = javaExecutableBookmark {
            let bookmark = Bookmark(data: bookmarkData)
            do {
                let resource = try SecurityScopedResource(bookmark: bookmark)
                let resolvedPath = resource.url.path(percentEncoded: false)
                javaLines.append(info("书签解析: \(resolvedPath)"))
                let started = resource.startAccessing()
                javaLines.append(info("startAccessing: \(started ? "成功" : "失败")"))
                if started {
                    defer { resource.stopAccessing() }
                    var isDir: ObjCBool = false
                    let exists = fm.fileExists(atPath: resource.url.path, isDirectory: &isDir)
                    let isDirectory = exists ? isDir.boolValue : resource.url.hasDirectoryPath
                    let bookmarkJava = isDirectory
                        ? resource.url.appendingPathComponent("bin/java").path(percentEncoded: false)
                        : resource.url.path(percentEncoded: false)
                    javaLines.append(info("书签 java: \(bookmarkJava)"))
                    javaLines.append(info("书签 java 存在: \(fm.fileExists(atPath: bookmarkJava) ? "是" : "否")"))
                    javaLines.append(info("书签 java 可读: \(fm.isReadableFile(atPath: bookmarkJava) ? "是" : "否")"))
                    javaLines.append(info("书签 java 可执行: \(fm.isExecutableFile(atPath: bookmarkJava) ? "是" : "否")"))
                }
            } catch {
                javaLines.append(item(.warn, "书签解析失败：\(error)"))
                if javaLevel == .ok { javaLevel = .warn }
                suggestions.append("Java 书签可能已失效：请重新选择 Java Home 授权。")
            }
        }

        // --- Network (DNS) ---
        var networkLines: [String] = []
        var networkLevel: Level = .ok
        let hostsToCheck = [
            "piston-data.mojang.com",
            "api.papermc.io",
            "repo.maven.apache.org"
        ]

        var failedHosts: [(String, String)] = []
        for host in hostsToCheck {
            let start = Date()
            let result = await Task.detached(priority: .utility) { Self.resolveDNS(host: host) }.value
            let ms = Int(Date().timeIntervalSince(start) * 1000.0)
            if result.ok {
                networkLines.append(item(.ok, "DNS 解析成功：\(host)（\(ms)ms）"))
            } else {
                let error = result.error ?? "未知错误"
                networkLines.append(item(.warn, "DNS 解析失败：\(host)（\(ms)ms）\(error)"))
                failedHosts.append((host, error))
            }
        }
        if failedHosts.count == hostsToCheck.count {
            networkLevel = .fail
        } else if !failedHosts.isEmpty {
            networkLevel = .warn
        }
        if !failedHosts.isEmpty {
            suggestions.append("网络/DNS 异常会导致 Paperclip 下载失败（UnknownHost）。请检查系统网络、DNS、代理/VPN 或防火墙设置。")
        }

        // --- Servers ---
        var serverLines: [String] = []
        var serversLevel: Level = .ok
        var serverOK = 0
        var serverWarn = 0
        var serverFail = 0

        if servers.isEmpty {
            serverLines.append(info("(无服务器)"))
        } else {
            for server in servers {
                var level: Level = .ok
                serverLines.append("• \(server.name) (\(server.id.uuidString))")

                if let runtime = runtimes[server.id] {
                    serverLines.append("  - 运行状态: \(runtime.state.rawValue) pid=\(runtime.pid.map(String.init) ?? "-")")
                } else {
                    serverLines.append("  - 运行状态: stopped")
                }

                let bookmark = Bookmark(data: server.workspaceBookmark)
                do {
                    let scope = try SecurityScopedResource(bookmark: bookmark)
                    let resolved = scope.url.path(percentEncoded: false)
                    serverLines.append("  - 工作目录: \(resolved)")
                    let started = scope.startAccessing()
                    serverLines.append("  - startAccessing: \(started ? "成功" : "失败")")
                    if started {
                        defer { scope.stopAccessing() }
                        var isDir: ObjCBool = false
                        let exists = fm.fileExists(atPath: scope.url.path, isDirectory: &isDir)
                        let dirOK = exists && isDir.boolValue
                        serverLines.append("  - 目录存在: \(dirOK ? "是" : "否")")
                        if !dirOK {
                            level = .fail
                        }

                switch server.entry.kind {
                case .jar:
                    if let jar = server.entry.path, !jar.isEmpty {
                        let jarURL = jar.hasPrefix("/") ? URL(fileURLWithPath: jar) : scope.url.appendingPathComponent(jar)
                        let jarPath = jarURL.path(percentEncoded: false)
                        let jarExists = fm.fileExists(atPath: jarURL.path)
                        serverLines.append("  - jar: \(jarPath)")
                        serverLines.append("  - jar 存在: \(jarExists ? "是" : "否")")
                        if !jarExists { level = .fail }
                    } else {
                        serverLines.append("  - jar: (未配置)")
                        level = .fail
                    }
                case .mainClass:
                    serverLines.append("  - mainClass: \(server.entry.mainClass ?? "(未配置)")")
                    if server.entry.mainClass?.isEmpty != false { level = .fail }
                case .script:
                            if let script = server.entry.path, !script.isEmpty {
                                let scriptURL = script.hasPrefix("/") ? URL(fileURLWithPath: script) : scope.url.appendingPathComponent(script)
                                let scriptPath = scriptURL.path(percentEncoded: false)
                                let exists = fm.fileExists(atPath: scriptURL.path)
                                serverLines.append("  - script: \(scriptPath)")
                                serverLines.append("  - script 存在: \(exists ? "是" : "否")")
                                if !exists { level = .fail }
                            } else {
                                serverLines.append("  - script: (未配置)")
                                level = .fail
                            }
                        }

                        let normalization = normalizeEntry(for: server)
                        let (previewServer, javaWarnings) = sanitizeJavaOptions(for: normalization.server)
                        var entryWarnings = entryMisconfigMessages(server)
                        entryWarnings.append(contentsOf: normalization.warnings)
                        entryWarnings.append(contentsOf: javaWarnings)
                        if let error = normalization.error {
                            serverLines.append("  - 入口错误: \(error)")
                            level = .fail
                        }
                        if !entryWarnings.isEmpty {
                            for warning in entryWarnings {
                                serverLines.append("  - 入口警告: \(warning)")
                            }
                            if level == .ok { level = .warn }
                            suggestions.append("服务器“\(server.name)”入口填写错误：Jar 类型只需填写 jar 文件名（例如 paper.jar），不要写 `java -jar ...`。")
                        }
                        serverLines.append("  - 命令预览: \(commandPreview(for: previewServer))")

                        // EULA check (Minecraft servers)
                        let eulaURL = scope.url.appendingPathComponent("eula.txt")
                        if fm.fileExists(atPath: eulaURL.path) {
                            if let text = try? String(contentsOf: eulaURL, encoding: .utf8) {
                                let accepted = text
                                    .split(separator: "\n")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .first(where: { $0.hasPrefix("eula=") })
                                    .map { $0 == "eula=true" } ?? false
                                serverLines.append("  - eula: \(accepted ? "已同意" : "未同意")")
                                if !accepted, level == .ok { level = .warn }
                                if !accepted {
                                    suggestions.append("服务器“\(server.name)”未同意 EULA：请在工作目录 eula.txt 设置 eula=true。")
                                }
                            } else {
                                serverLines.append("  - eula: (读取失败)")
                                if level == .ok { level = .warn }
                            }
                        } else {
                            serverLines.append("  - eula: (未生成)")
                        }
                    } else {
                        level = .fail
                            suggestions.append("服务器“\(server.name)”工作目录未授权或书签失效：请在“编辑服务器”重新选择工作目录并保存。")
                    }
                } catch {
                    serverLines.append("  - 工作目录书签解析失败: \(error)")
                    level = .fail
                    suggestions.append("服务器“\(server.name)”工作目录书签解析失败：请在“编辑服务器”重新选择工作目录并保存。")
                }

                switch level {
                case .ok:
                    serverOK += 1
                case .warn:
                    serverWarn += 1
                case .fail:
                    serverFail += 1
                }
                serverLines.append("  - 结论: \(label(level))")
                serverLines.append("")
            }
        }

        if serverFail > 0 {
            serversLevel = .fail
        } else if serverWarn > 0 {
            serversLevel = .warn
        } else {
            serversLevel = .ok
        }

        // --- Assemble report ---
        var lines: [String] = []
        lines.append("JSM 自检报告")
        lines.append("时间: \(timestamp)")
        lines.append("App: \(version) (\(build))")
        lines.append("系统: \(ProcessInfo.processInfo.operatingSystemVersionString) (\(arch))")
        lines.append("容器: \(fm.homeDirectoryForCurrentUser.path(percentEncoded: false))")
        lines.append("关闭策略: \(processStopStrategy.rawValue)")
        lines.append("")
        lines.append("=== 总览 ===")
        lines.append("Java: \(label(javaLevel))")
        lines.append("网络: \(label(networkLevel))")
        if servers.isEmpty {
            lines.append("服务器: 无")
        } else {
            lines.append("服务器: \(label(serversLevel))（通过 \(serverOK) / 警告 \(serverWarn) / 失败 \(serverFail)）")
        }

        lines.append("")
        lines.append("=== Java ===")
        lines.append(contentsOf: javaLines)
        lines.append("")
        lines.append("=== 网络（DNS） ===")
        lines.append(contentsOf: networkLines)
        lines.append("")
        lines.append("=== 服务器 ===")
        lines.append(contentsOf: serverLines)

        let finalSuggestions = uniqueSuggestions(suggestions)
        if !finalSuggestions.isEmpty {
            lines.append("=== 建议 ===")
            for value in finalSuggestions {
                lines.append("- \(value)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func refreshJavaUsability() {
        let fm = FileManager.default
        javaBookmarkIsUsable = false
        javaBookmarkBlocksExecution = false

        if let bookmarkData = javaExecutableBookmark {
            let bookmark = Bookmark(data: bookmarkData)
            if let resource = try? SecurityScopedResource(bookmark: bookmark) {
                let started = resource.startAccessing()
                defer { if started { resource.stopAccessing() } }

                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: resource.url.path, isDirectory: &isDir)
                let isDirectory = exists ? isDir.boolValue : resource.url.hasDirectoryPath
                let bookmarkJava = isDirectory
                    ? resource.url.appendingPathComponent("bin/java").path(percentEncoded: false)
                    : resource.url.path(percentEncoded: false)

                let bookmarkExists = fm.fileExists(atPath: bookmarkJava)
                let bookmarkReadable = fm.isReadableFile(atPath: bookmarkJava)
                let bookmarkExecutable = fm.isExecutableFile(atPath: bookmarkJava)
                javaBookmarkIsUsable = bookmarkExists && bookmarkExecutable
                javaBookmarkBlocksExecution = bookmarkExists && bookmarkReadable && !bookmarkExecutable
            }
        }

        let directUsable = javaExecutableValue.map { fm.isExecutableFile(atPath: $0) } ?? false
        javaIsUsable = directUsable || javaBookmarkIsUsable
    }

    private var javaExecutableValue: String? {
        let trimmed = javaExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func inferredJavaHomeURL(from path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        if url.lastPathComponent == "java" {
            // Prefer preselecting the executable itself. It avoids symlink-directory quirks (e.g. SDKMAN `current`)
            // and still allows us to infer JAVA_HOME after the user authorizes.
            return url
        }
        return url.deletingLastPathComponent()
    }

    private func retryPendingStartIfNeeded() {
        guard let pending = pendingStartServerID else { return }
        pendingStartServerID = nil
        Task { await startServer(id: pending) }
    }

    private func handleProcessTermination(definitionID: UUID,
                                          reason: Process.TerminationReason,
                                          status: Int32) {
        clearStopControls(for: definitionID)
        let stopRequested = stopRequestedServerIDs.contains(definitionID)
        stopRequestedServerIDs.remove(definitionID)

        let crash: Bool
        if stopRequested {
            crash = false
        } else {
            switch reason {
            case .exit:
                crash = status != 0
            case .uncaughtSignal:
                crash = true
            @unknown default:
                crash = status != 0
            }
        }

        if var runtime = runtimes[definitionID] {
            runtime.pid = nil
            runtime.state = crash ? .crashed : .stopped
            runtimes[definitionID] = runtime
        }

        guard crash, let server = servers.first(where: { $0.id == definitionID }) else {
            if !crash { restartAttempts[definitionID] = 0 }
            return
        }

        appendLog("进程异常退出：status=\(status)", id: definitionID)

        guard server.lifecycle.restartOnCrash else { return }
        let attempts = restartAttempts[definitionID, default: 0]
        if attempts >= max(0, server.lifecycle.maxRestarts) {
            lastErrorMessage = "服务“\(server.name)”崩溃，已达到最大重启次数（\(server.lifecycle.maxRestarts)）。"
            return
        }
        restartAttempts[definitionID] = attempts + 1

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.startServerInternal(id: definitionID, isAutomaticRestart: true)
        }
    }

    private func candidateJavaHomes(from url: URL) -> [URL] {
        var results: [URL] = []
        func addDirectory(_ value: URL) {
            let resolved = value.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return }
            if !results.contains(where: { $0.path == resolved.path }) { results.append(resolved) }
        }

        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()

        for base in [original, resolved] {
            addDirectory(base)

            if base.lastPathComponent == "bin" {
                addDirectory(base.deletingLastPathComponent())
            }

            if base.pathExtension == "jdk" {
                addDirectory(base.appendingPathComponent("Contents/Home"))
            }

            addDirectory(base.appendingPathComponent("Contents/Home"))
            addDirectory(base.appendingPathComponent("libexec/openjdk.jdk/Contents/Home"))
            addDirectory(base.appendingPathComponent("openjdk.jdk/Contents/Home"))
            addDirectory(base.appendingPathComponent("current"))
        }

        return results
    }

    private func inferJavaHome(from url: URL) -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let isDirectory = exists ? isDir.boolValue : url.hasDirectoryPath
        let normalized = url.standardizedFileURL

        if !isDirectory {
            if normalized.lastPathComponent == "java" {
                let bin = normalized.deletingLastPathComponent()
                if bin.lastPathComponent == "bin" {
                    return bin.deletingLastPathComponent()
                }
                return bin
            }
            return normalized.deletingLastPathComponent()
        }

        if normalized.pathExtension == "jdk" {
            return normalized.appendingPathComponent("Contents/Home")
        }

        if normalized.lastPathComponent == "bin" {
            return normalized.deletingLastPathComponent()
        }

        // Prefer common bundle layouts if the user selected a higher-level directory.
        let directHome = normalized.appendingPathComponent("Contents/Home")
        if fm.isExecutableFile(atPath: directHome.appendingPathComponent("bin/java").path) {
            return directHome
        }
        let homebrewHome = normalized.appendingPathComponent("libexec/openjdk.jdk/Contents/Home")
        if fm.isExecutableFile(atPath: homebrewHome.appendingPathComponent("bin/java").path) {
            return homebrewHome
        }
        let nestedHome = normalized.appendingPathComponent("openjdk.jdk/Contents/Home")
        if fm.isExecutableFile(atPath: nestedHome.appendingPathComponent("bin/java").path) {
            return nestedHome
        }

        return normalized
    }

    private func discoverJavaHome(oneLevelUnder root: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else {
            return nil
        }
        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let home = item.pathExtension == "jdk" ? item.appendingPathComponent("Contents/Home") : item
            let java = home.appendingPathComponent("bin/java").path
            if fm.isExecutableFile(atPath: java) {
                return home
            }
        }
        return nil
    }

    private func appendLog(_ line: String, id: UUID) {
        if logs[id] == nil { logs[id] = [] }
        logs[id, default: []].append(line)
        if logs[id, default: []].count > 2000 {
            logs[id] = Array(logs[id, default: []].suffix(2000))
        }
    }

    private func startMetricsTimer() {
        let metricsQueue = DispatchQueue(label: "jsm.metrics")
        let metricsProvider = self.metricsProvider
        var samplingInFlight = false

        let timer = DispatchSource.makeTimerSource(queue: metricsQueue)
        timer.schedule(deadline: .now() + metricsInterval, repeating: metricsInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if samplingInFlight { return }
            samplingInFlight = true

            Task.detached(priority: .background) { [weak self] in
                defer {
                    metricsQueue.async {
                        samplingInFlight = false
                    }
                }
                guard let self else { return }

                let running: [(UUID, Int32)] = await MainActor.run {
                    self.runtimes.compactMap { (id, runtime) in
                        guard runtime.state == .running, let pid = runtime.pid else { return nil }
                        return (id, pid)
                    }
                }

                var samples: [UUID: MetricsSnapshot] = [:]
                for (id, pid) in running {
                    guard let snapshot = try? metricsProvider.sample(pid: pid) else { continue }
                    samples[id] = snapshot
                }

                guard !samples.isEmpty else { return }
                let sampledSnapshots = samples
                await MainActor.run {
                    var updated = self.runtimes
                    for (id, snapshot) in sampledSnapshots {
                        guard var runtime = updated[id] else { continue }
                        runtime.metricsSnapshot = snapshot
                        updated[id] = runtime
                    }
                    self.runtimes = updated
                }
            }
        }
        timer.resume()
        metricsTimer = timer
    }

    private func restartMetricsTimer() {
        metricsTimer?.cancel()
        metricsTimer = nil
        startMetricsTimer()
    }

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        let settings = (try? settingsStore.load()) ?? AppSettings()
        metricsInterval = settings.metricsInterval
        consoleRenderer = settings.consoleRenderer
        themeAppearance = settings.themeAppearance
        processStopStrategy = settings.processStopStrategy
        javaExecutable = (settings.javaExecutable ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if javaExecutable == "/usr/bin/java" || javaExecutable == "java", !JavaLocator.hasSystemJava() {
            javaExecutable = ""
        }
        javaExecutableBookmark = settings.javaExecutableBookmark
        lastStartedServerIDs = settings.lastStartedServerIDs
        if let data = javaExecutableBookmark {
            processController.javaExecutableBookmark = Bookmark(data: data)
        } else {
            processController.javaExecutableBookmark = nil
        }
        processController.javaExecutable = javaExecutableValue
    }

    private func saveSettings() {
        let settings = AppSettings(javaExecutable: javaExecutableValue,
                                   javaExecutableBookmark: javaExecutableBookmark,
                                   metricsInterval: metricsInterval,
                                   consoleRenderer: consoleRenderer,
                                   lastStartedServerIDs: lastStartedServerIDs,
                                   themeAppearance: themeAppearance,
                                   processStopStrategy: processStopStrategy)
        try? settingsStore.save(settings)
    }

    private func withScopedAccess(to url: URL, _ action: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        let scopeTarget = exists ? url : url.deletingLastPathComponent()
        let bookmark = try Bookmark.create(for: scopeTarget)
        try SandboxAccess.withBookmark(bookmark) { resourceURL in
            let scopedURL = exists ? resourceURL : resourceURL.appendingPathComponent(url.lastPathComponent)
            try action(scopedURL)
        }
    }
}
