import Foundation
import Darwin

public enum MetricsError: Error {
    case invalidPID
    case procInfoFailed
}

public nonisolated final class MetricsProvider {
    private struct CpuSample {
        let timestamp: TimeInterval
        let totalTime: UInt64
    }

    private var lastSamples: [Int32: CpuSample] = [:]
    private let lock = NSLock()

    public init() {}

    public func sample(pid: Int32) throws -> MetricsSnapshot {
        guard pid > 0 else { throw MetricsError.invalidPID }
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, raw, Int32(size))
            }
        }
        guard result == Int32(size) else { throw MetricsError.procInfoFailed }

        let totalTime = UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
        let now = CFAbsoluteTimeGetCurrent()
        let cpuPercent: Double
        lock.lock()
        if let last = lastSamples[pid] {
            let deltaTime = max(0.000_1, now - last.timestamp)
            let deltaCPU = Double(max(0, totalTime - last.totalTime))
            // proc_taskinfo time values are in nanoseconds.
            let cpuSeconds = deltaCPU / 1_000_000_000.0
            let cores = Double(max(1, ProcessInfo.processInfo.processorCount))
            cpuPercent = min(100.0, (cpuSeconds / deltaTime) * 100.0 / cores)
        } else {
            cpuPercent = 0
        }
        lastSamples[pid] = CpuSample(timestamp: now, totalTime: totalTime)
        lock.unlock()

        let memoryBytes = UInt64(info.pti_resident_size)
        let threadCount = Int(info.pti_threadnum)
        let fdCount = 0

        return MetricsSnapshot(cpuPercent: cpuPercent,
                               memoryBytes: memoryBytes,
                               threadCount: threadCount,
                               fileDescriptorCount: fdCount,
                               networkRxBytes: nil,
                               networkTxBytes: nil)
    }
}
