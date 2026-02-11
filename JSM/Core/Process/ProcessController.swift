import Foundation
import OSLog
import Darwin

public enum ProcessControllerError: Error {
    case invalidEntry
    case javaNotFound(String?)
    case launchFailed(Error?)
    case workspaceAccessDenied
    case javaAccessDenied
}

public protocol ProcessControlling {
    func start(server: ServerDefinition) async throws -> ServerRuntime
    func stop(runtime: ServerRuntime) async
    func forceStop(runtime: ServerRuntime) async
    func isRunning(definitionID: UUID) async -> Bool
    func restart(runtime: ServerRuntime) async throws -> ServerRuntime
    func sendInput(_ text: String, to runtime: ServerRuntime) async
    func attachStdout(for runtime: ServerRuntime, handler: @escaping (String) -> Void)
    func attachStderr(for runtime: ServerRuntime, handler: @escaping (String) -> Void)
}

/// Default NSTask-based process controller. It never blocks the main thread and streams output through async readers.
public final class ProcessController: ProcessControlling {
    private let logger = Logger(subsystem: "jsm.process", category: "controller")
    public var javaExecutable: String?
    public var javaExecutableBookmark: Bookmark?
    public var onTermination: ((UUID, Process.TerminationReason, Int32) -> Void)?
    private struct ProcessSession {
        let server: ServerDefinition
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        let logBuffer: LogRingBuffer
        let scope: SecurityScopedResource
        let javaScope: SecurityScopedResource?
    }
    private var sessions: [UUID: ProcessSession] = [:]
    private var stdoutHandlers: [UUID: [(String) -> Void]] = [:]
    private var stderrHandlers: [UUID: [(String) -> Void]] = [:]
    private let queue = DispatchQueue(label: "jsm.process.controller")

    public init() {}

    public func start(server: ServerDefinition) async throws -> ServerRuntime {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let bookmark = Bookmark(data: server.workspaceBookmark)
        let scoped = try SecurityScopedResource(bookmark: bookmark)
        guard scoped.startAccessing() else { throw ProcessControllerError.workspaceAccessDenied }
        process.currentDirectoryURL = scoped.url

        // Activate Java scope (if available) before resolving `bin/java`, otherwise FileManager checks may fail
        // under App Sandbox and we end up falling back to `/usr/bin/java` stubs or failing incorrectly.
        let javaScope = try openJavaScopeIfNeeded()
        let command = try buildCommand(for: server, workspaceURL: scoped.url)
        process.arguments = command
        process.standardInput = Pipe()
        var environment = ProcessInfo.processInfo.environment.merging(server.env) { _, new in new }
        if let javaHome = resolveJavaHomeForEnvironment() {
            environment["JAVA_HOME"] = javaHome
            environment["JDK_HOME"] = javaHome
            let javaBin = (javaHome as NSString).appendingPathComponent("bin")
            let existingPath = environment["PATH"] ?? ""
            if !existingPath.split(separator: ":").contains(Substring(javaBin)) {
                environment["PATH"] = existingPath.isEmpty ? javaBin : "\(javaBin):\(existingPath)"
            }
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let logBuffer = LogRingBuffer(capacity: 4096)

        let definitionID = server.id
        process.terminationHandler = { [weak self] proc in
            self?.logger.debug("Process terminated pid=\(proc.processIdentifier)")
            self?.queue.async {
                self?.onTermination?(definitionID, proc.terminationReason, proc.terminationStatus)
                if let session = self?.sessions[definitionID] {
                    session.scope.stopAccessing()
                    session.javaScope?.stopAccessing()
                }
                self?.sessions[definitionID] = nil
                self?.stdoutHandlers[definitionID] = nil
                self?.stderrHandlers[definitionID] = nil
            }
        }

        do {
            try process.run()
        } catch {
            scoped.stopAccessing()
            javaScope?.stopAccessing()
            throw ProcessControllerError.launchFailed(error)
        }

        let pid = process.processIdentifier
        stream(pipe: stdoutPipe, to: logBuffer, definitionID: definitionID, isStdout: true)
        stream(pipe: stderrPipe, to: logBuffer, definitionID: definitionID, isStdout: false)

        let session = ProcessSession(server: server,
                                     process: process,
                                     stdout: stdoutPipe,
                                     stderr: stderrPipe,
                                     logBuffer: logBuffer,
                                     scope: scoped,
                                     javaScope: javaScope)
        queue.async { self.sessions[definitionID] = session }

        return ServerRuntime(definitionID: definitionID,
                             pid: pid,
                             state: .running,
                             startTime: Date(),
                             metricsSnapshot: nil,
                             logBuffer: logBuffer)
    }

    public func stop(runtime: ServerRuntime) async {
        queue.async {
            guard let session = self.sessions[runtime.definitionID] else { return }
            let pid = session.process.processIdentifier
            if let signal = session.server.lifecycle.stopSignal {
                _ = kill(pid, signal)
            } else {
                session.process.terminate()
            }
        }
    }

    public func forceStop(runtime: ServerRuntime) async {
        queue.async {
            guard let session = self.sessions[runtime.definitionID] else { return }
            _ = kill(session.process.processIdentifier, SIGKILL)
        }
    }

    public func isRunning(definitionID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let session = self.sessions[definitionID] else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: session.process.isRunning)
            }
        }
    }

    public func restart(runtime: ServerRuntime) async throws -> ServerRuntime {
        let server: ServerDefinition? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.sessions[runtime.definitionID]?.server)
            }
        }
        guard let server else { throw ProcessControllerError.invalidEntry }
        await stop(runtime: runtime)
        return try await start(server: server)
    }

    public func sendInput(_ text: String, to runtime: ServerRuntime) async {
        queue.async {
            guard let session = self.sessions[runtime.definitionID],
                  let stdin = session.process.standardInput as? Pipe else { return }
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
        }
    }

    public func attachStdout(for runtime: ServerRuntime, handler: @escaping (String) -> Void) {
        queue.async {
            var handlers = self.stdoutHandlers[runtime.definitionID] ?? []
            handlers.append(handler)
            self.stdoutHandlers[runtime.definitionID] = handlers
        }
    }

    public func attachStderr(for runtime: ServerRuntime, handler: @escaping (String) -> Void) {
        queue.async {
            var handlers = self.stderrHandlers[runtime.definitionID] ?? []
            handlers.append(handler)
            self.stderrHandlers[runtime.definitionID] = handlers
        }
    }

    private func buildCommand(for server: ServerDefinition, workspaceURL: URL) throws -> [String] {
        let java = try resolveJavaExecutable()
        let javaOptions = injectJnaTempDir(into: server.javaOptions, workspaceURL: workspaceURL)
        switch server.entry.kind {
        case .jar:
            guard let jar = server.entry.path else { throw ProcessControllerError.invalidEntry }
            return [java] + javaOptions + ["-jar", resolve(path: jar, workspace: workspaceURL)] + server.programArgs
        case .mainClass:
            guard let mainClass = server.entry.mainClass else { throw ProcessControllerError.invalidEntry }
            return [java] + javaOptions + [mainClass] + server.programArgs
        case .script:
            guard let script = server.entry.path else { throw ProcessControllerError.invalidEntry }
            let scriptPath = resolve(path: script, workspace: workspaceURL)
            let ext = URL(fileURLWithPath: scriptPath).pathExtension.lowercased()
            if ext == "sh" || ext == "command" {
                return ["/bin/bash", scriptPath] + server.programArgs
            }
            return [scriptPath] + server.programArgs
        }
    }

    private func injectJnaTempDir(into options: [String], workspaceURL: URL) -> [String] {
        if options.contains(where: { $0.hasPrefix("-Djna.tmpdir=") }) {
            return options
        }
        let tempDir = workspaceURL.appendingPathComponent(".jna", isDirectory: true).path
        return ["-Djna.tmpdir=\(tempDir)"] + options
    }

    private func resolveJavaExecutable() throws -> String {
        let isSystemStub: (String) -> Bool = { path in
            path == "/usr/bin/java" && !JavaLocator.hasSystemJava()
        }

        if let bookmark = javaExecutableBookmark,
           let url = try? bookmark.resolve() {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, isDir.boolValue {
                let java = url.appendingPathComponent("bin/java").path
                if FileManager.default.isExecutableFile(atPath: java) {
                    if isSystemStub(java) {
                        // Avoid Apple Java stub when no system JRE/JDK is registered.
                    } else {
                        return java
                    }
                }
            } else if FileManager.default.isExecutableFile(atPath: url.path) {
                if isSystemStub(url.path) {
                    // Ignore stub.
                } else {
                    return url.path
                }
            }
        }
        if let path = javaExecutable, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isSystemStub(path) {
                // Ignore stub.
            } else if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            throw ProcessControllerError.javaNotFound(path)
        }
        if let detected = JavaLocator.findJavaExecutable() {
            return detected
        }
        throw ProcessControllerError.javaNotFound(nil)
    }

    private func resolve(path: String, workspace: URL) -> String {
        let url = URL(fileURLWithPath: path)
        if path.hasPrefix("/") { return url.path }
        return workspace.appendingPathComponent(path).path
    }

    private func openJavaScopeIfNeeded() throws -> SecurityScopedResource? {
        guard let bookmark = javaExecutableBookmark else { return nil }
        do {
            let resource = try SecurityScopedResource(bookmark: bookmark)
            if resource.startAccessing() {
                return resource
            }
            // If the resolved URL is already accessible without a security scope, don't fail.
            let url = resource.url
            var isDir: ObjCBool = false
            let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue

            var candidates: [String] = []
            if isDirectory {
                candidates.append(url.appendingPathComponent("bin/java").path)
            } else {
                candidates.append(url.path)
            }
            if let configured = javaExecutable?.trimmingCharacters(in: .whitespacesAndNewlines),
               !configured.isEmpty {
                candidates.append(configured)
            }

            if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return nil
            }
            throw ProcessControllerError.javaAccessDenied
        } catch {
            throw ProcessControllerError.javaAccessDenied
        }
    }

    private func resolveJavaHomeForEnvironment() -> String? {
        if let bookmark = javaExecutableBookmark,
           let url = try? bookmark.resolve() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url.path }
            if url.lastPathComponent == "java" {
                let bin = url.deletingLastPathComponent()
                if bin.lastPathComponent == "bin" {
                    return bin.deletingLastPathComponent().path
                }
                return bin.path
            }
            return url.deletingLastPathComponent().path
        }

        guard let path = javaExecutable?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url.path }
        if url.lastPathComponent == "java" {
            let bin = url.deletingLastPathComponent()
            if bin.lastPathComponent == "bin" { return bin.deletingLastPathComponent().path }
            return bin.path
        }
        return url.deletingLastPathComponent().path
    }

    private func stream(pipe: Pipe, to buffer: LogRingBuffer, definitionID: UUID, isStdout: Bool) {
        let handle = pipe.fileHandleForReading
        var remainder = ""
        handle.readabilityHandler = { [weak self] file in
            guard let self else { return }
            let data = file.availableData
            guard !data.isEmpty else {
                if !remainder.isEmpty {
                    let lastLine = remainder
                    remainder = ""
                    buffer.append(lastLine)
                    self.queue.async {
                        let handlers = isStdout ? (self.stdoutHandlers[definitionID] ?? []) : (self.stderrHandlers[definitionID] ?? [])
                        handlers.forEach { $0(lastLine) }
                    }
                }
                file.readabilityHandler = nil
                return
            }

            remainder += String(decoding: data, as: UTF8.self)
            remainder = remainder.replacingOccurrences(of: "\r\n", with: "\n")
            let parts = remainder.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard parts.count > 1 else { return }

            let completed = parts.dropLast().map(String.init)
            remainder = String(parts.last ?? "")
            if completed.isEmpty { return }

            for line in completed {
                buffer.append(line)
            }

            self.queue.async {
                let handlers = isStdout ? (self.stdoutHandlers[definitionID] ?? []) : (self.stderrHandlers[definitionID] ?? [])
                for line in completed {
                    handlers.forEach { $0(line) }
                }
            }
        }
    }
}
