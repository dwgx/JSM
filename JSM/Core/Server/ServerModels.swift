import Foundation

public enum ServerType: String, Codable {
    case java
}

public enum ServerEntryKind: String, Codable {
    case jar
    case mainClass
    case script
}

/// Represents how a Java server should be launched.
public struct ServerEntry: Codable {
    public var kind: ServerEntryKind
    /// Path to jar or script; nil when using mainClass launch.
    public var path: String?
    /// Fully qualified main class when using mainClass launch.
    public var mainClass: String?

    public init(kind: ServerEntryKind, path: String? = nil, mainClass: String? = nil) {
        self.kind = kind
        self.path = path
        self.mainClass = mainClass
    }
}

public struct LifecyclePolicy: Codable {
    public var restartOnCrash: Bool
    public var maxRestarts: Int
    public var stopSignal: Int32?

    public init(restartOnCrash: Bool = true, maxRestarts: Int = 3, stopSignal: Int32? = nil) {
        self.restartOnCrash = restartOnCrash
        self.maxRestarts = maxRestarts
        self.stopSignal = stopSignal
    }
}

public struct ServerDefinition: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var type: ServerType
    /// Security-scoped bookmark for workspace root.
    public var workspaceBookmark: Data
    public var entry: ServerEntry
    public var javaOptions: [String]
    public var programArgs: [String]
    public var env: [String: String]
    public var lifecycle: LifecyclePolicy

    public init(id: UUID = UUID(),
                name: String,
                type: ServerType = .java,
                workspaceBookmark: Data,
                entry: ServerEntry,
                javaOptions: [String] = [],
                programArgs: [String] = [],
                env: [String: String] = [:],
                lifecycle: LifecyclePolicy = LifecyclePolicy()) {
        self.id = id
        self.name = name
        self.type = type
        self.workspaceBookmark = workspaceBookmark
        self.entry = entry
        self.javaOptions = javaOptions
        self.programArgs = programArgs
        self.env = env
        self.lifecycle = lifecycle
    }
}

/// Portable server configuration used for YAML editing/import/export.
/// It intentionally excludes sandbox-specific bookmarks.
public struct ServerConfig: Codable {
    public var id: UUID?
    public var name: String
    public var type: ServerType
    public var entry: ServerEntry
    public var javaOptions: [String]
    public var programArgs: [String]
    public var env: [String: String]
    public var lifecycle: LifecyclePolicy

    public init(id: UUID? = nil,
                name: String,
                type: ServerType = .java,
                entry: ServerEntry,
                javaOptions: [String] = [],
                programArgs: [String] = [],
                env: [String: String] = [:],
                lifecycle: LifecyclePolicy = LifecyclePolicy()) {
        self.id = id
        self.name = name
        self.type = type
        self.entry = entry
        self.javaOptions = javaOptions
        self.programArgs = programArgs
        self.env = env
        self.lifecycle = lifecycle
    }

    public init(definition: ServerDefinition) {
        self.id = definition.id
        self.name = definition.name
        self.type = definition.type
        self.entry = definition.entry
        self.javaOptions = definition.javaOptions
        self.programArgs = definition.programArgs
        self.env = definition.env
        self.lifecycle = definition.lifecycle
    }

    public func applying(to definition: ServerDefinition) -> ServerDefinition {
        var updated = definition
        updated.name = name
        updated.type = type
        updated.entry = entry
        updated.javaOptions = javaOptions
        updated.programArgs = programArgs
        updated.env = env
        updated.lifecycle = lifecycle
        return updated
    }

    public func toDefinition(workspaceBookmark: Data) -> ServerDefinition {
        ServerDefinition(id: id ?? UUID(),
                         name: name,
                         type: type,
                         workspaceBookmark: workspaceBookmark,
                         entry: entry,
                         javaOptions: javaOptions,
                         programArgs: programArgs,
                         env: env,
                         lifecycle: lifecycle)
    }
}

public enum RuntimeState: String, Codable {
    case stopped
    case starting
    case stopping
    case running
    case crashed
}

public struct MetricsSnapshot: Codable {
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var threadCount: Int
    public var fileDescriptorCount: Int
    public var networkRxBytes: UInt64?
    public var networkTxBytes: UInt64?

    public init(cpuPercent: Double = 0,
                memoryBytes: UInt64 = 0,
                threadCount: Int = 0,
                fileDescriptorCount: Int = 0,
                networkRxBytes: UInt64? = nil,
                networkTxBytes: UInt64? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.fileDescriptorCount = fileDescriptorCount
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
    }
}

public final class LogRingBuffer {
    private let capacity: Int
    private var buffer: [String] = []
    private var index = 0
    private let lock = NSLock()

    public init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
        buffer = Array(repeating: "", count: self.capacity)
    }

    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        buffer[index] = line
        index = (index + 1) % capacity
    }

    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let slice1 = buffer[index..<capacity].filter { !$0.isEmpty }
        let slice2 = buffer[0..<index].filter { !$0.isEmpty }
        return Array(slice1 + slice2)
    }
}

public struct ServerRuntime: Identifiable {
    public var id: UUID { definitionID }
    public let definitionID: UUID
    public var pid: Int32?
    public var state: RuntimeState
    public var startTime: Date?
    public var metricsSnapshot: MetricsSnapshot?
    /// Shared mutable log buffer (hot reload safe because it is locked internally).
    public var logBuffer: LogRingBuffer

    public init(definitionID: UUID,
                pid: Int32? = nil,
                state: RuntimeState = .stopped,
                startTime: Date? = nil,
                metricsSnapshot: MetricsSnapshot? = nil,
                logBuffer: LogRingBuffer = LogRingBuffer()) {
        self.definitionID = definitionID
        self.pid = pid
        self.state = state
        self.startTime = startTime
        self.metricsSnapshot = metricsSnapshot
        self.logBuffer = logBuffer
    }
}
