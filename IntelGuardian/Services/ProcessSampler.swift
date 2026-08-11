#if os(macOS)
import Foundation
import Darwin

/// One process' accumulated CPU time over the trailing 2-hour window — the
/// proxy for how much heat it contributed — plus identity info so users can
/// tell processes apart. `id` equals `pid` so SwiftUI lists can identify rows.
struct ProcessUsage: Identifiable {
    let id: Int
    let pid: Int
    let ppid: Int
    let name: String
    /// Accumulated user+system CPU time in seconds over the window.
    let cpuSeconds: UInt64
    /// CPU usage over the most recent sampling interval, as % of one core.
    /// Multi-threaded / multi-core processes can exceed 100%.
    let cpuUsagePercent: Double
    /// When the process started (absolute time).
    let startDate: Date
    /// Seconds elapsed since the process started.
    let runtimeSeconds: TimeInterval
}

/// Tracks per-process CPU time over a sliding 2-hour window by differencing
/// the kernel's monotonically increasing per-process CPU counters (µs) at each
/// sample, then evicting entries older than the window. macOS only — iOS
/// sandboxes block process-level access, so this service is not compiled there.
final class ProcessSampler {
    private struct Accumulator {
        /// (sample time, CPU µs consumed in that interval), appended newest-last.
        var events: [(Date, UInt64)] = []
        /// Sum of the events currently inside the window.
        var total: UInt64 = 0
        /// CPU usage (% of one core) over the most recent interval.
        var usagePercent: Double = 0
    }

    /// How far back the ranking looks — mirrors the "近 2 小时" label.
    private let windowDuration: TimeInterval = 2 * 3600
    /// Only report processes that accumulated at least this much CPU over the
    /// window, so idle processes don't clutter the list.
    private let minCPUSeconds: UInt64 = 10
    /// Skipped pids: the app itself plus kernel/diagnostic pseudo-processes.
    private let excludedPIDs: Set<pid_t>

    /// Last cumulative CPU time (µs) per pid; seeds delta computation.
    private var lastRead: [pid_t: UInt64] = [:]
    private var lastSampleAt: Date?
    private var window: [pid_t: Accumulator] = [:]

    init() {
        var excluded = Set<pid_t>([getpid()])
        for pid in [0, 1] { excluded.insert(pid_t(pid)) }
        self.excludedPIDs = excluded
    }

    /// Samples all processes, folds each interval's delta into the process'
    /// sliding 2-hour window, and returns the top consumers by accumulated CPU.
    /// The first call only establishes a baseline and returns empty.
    func sampleTopProcesses(top: Int = 12) -> [ProcessUsage] {
        let now = Date()
        let current = readAllTaskCPU()
        defer { lastRead = current; lastSampleAt = now }

        guard let prevAt = lastSampleAt else { return [] }
        let interval = now.timeIntervalSince(prevAt)
        guard interval > 0 else { return [] }

        let cutoff = now.addingTimeInterval(-windowDuration)

        var totals: [pid_t: UInt64] = [:]
        totals.reserveCapacity(current.count)
        for (pid, currentCPU) in current {
            guard let prevCPU = lastRead[pid] else { continue }   // first sighting; seed next sample
            if currentCPU < prevCPU {                              // pid reused by a restarted process
                window[pid] = nil
                continue
            }
            let delta = currentCPU - prevCPU
            guard delta > 0 else { continue }

            // CPU usage over this interval as % of one core: the µs of CPU time
            // consumed divided by the wall-clock interval (in the same units).
            let usage = Double(delta) / (interval * 1_000_000) * 100

            var acc = window[pid] ?? Accumulator()
            acc.events.append((now, delta))
            acc.total += delta
            acc.usagePercent = usage
            while let first = acc.events.first, first.0 < cutoff {
                acc.total &-= first.1
                acc.events.removeFirst()
            }
            window[pid] = acc
            totals[pid] = acc.total
        }

        // Bound memory by dropping tracking state for processes that exited.
        window = window.filter { current[$0.key] != nil }

        let candidates = totals.compactMap { pid, total -> (pid_t, UInt64, Double)? in
            let seconds = total / 1_000_000
            let usage = window[pid]?.usagePercent ?? 0
            return seconds >= minCPUSeconds ? (pid, seconds, usage) : nil
        }
        let top12 = candidates.sorted { $0.1 > $1.1 }.prefix(top)
        return top12.map { pid, seconds, usage in
            ProcessUsage(
                id: Int(pid),
                pid: Int(pid),
                ppid: Int(parentPID(pid) ?? 0),
                name: processName(pid),
                cpuSeconds: seconds,
                cpuUsagePercent: usage,
                startDate: startDate(pid) ?? .distantPast,
                runtimeSeconds: runtime(pid) ?? 0
            )
        }
    }

    func reset() {
        lastRead.removeAll()
        lastSampleAt = nil
        window.removeAll()
    }

    // MARK: - Process info (BSD info)

    /// Parent pid, or nil if unreadable.
    private func parentPID(_ pid: pid_t) -> Int32? {
        guard let info = bsdInfo(pid) else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// Absolute start time, or nil if unreadable.
    private func startDate(_ pid: pid_t) -> Date? {
        guard let info = bsdInfo(pid) else { return nil }
        let seconds = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    /// Seconds since the process started, or nil if unreadable.
    private func runtime(_ pid: pid_t) -> TimeInterval? {
        guard let start = startDate(pid) else { return nil }
        return Date().timeIntervalSince(start)
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    // MARK: - Process enumeration

    /// pid → accumulated user+system CPU time in microseconds.
    private func readAllTaskCPU() -> [pid_t: UInt64] {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [:] }

        var result: [pid_t: UInt64] = [:]
        result.reserveCapacity(Int(count))
        var info = proc_taskinfo()
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for i in 0..<Int(count) {
            let pid = pids[i]
            guard pid > 0, !excludedPIDs.contains(pid) else { continue }
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize)
            guard r == infoSize else { continue }
            result[pid] = info.pti_total_user + info.pti_total_system
        }
        return result
    }

    /// Best-effort process name from KERN_PROCARGS2 (exec path / argv[0]).
    private func processName(_ pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return "pid \(pid)"
        }
        var raw = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &raw, &size, nil, 0) == 0 else {
            return "pid \(pid)"
        }
        let bytes = raw.map { UInt8(bitPattern: $0) }

        func cString(at offset: Int) -> (String, Int)? {
            var end = offset
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            guard end > offset else { return nil }
            let s = String(decoding: bytes[offset..<end], as: UTF8.self)
            return (s, end + 1)
        }

        // Layout: [Int32 argc][exec path\0][padding \0...][argv0\0]...
        var offset = MemoryLayout<Int32>.size
        guard let (execPath, consumed) = cString(at: offset) else { return "pid \(pid)" }
        offset = consumed
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        if let (argv0, _) = cString(at: offset), !argv0.isEmpty {
            return (argv0 as NSString).lastPathComponent
        }
        return (execPath as NSString).lastPathComponent
    }
}
#endif
