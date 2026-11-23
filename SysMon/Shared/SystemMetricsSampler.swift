import Foundation
import Darwin
import MachO

/// 系统指标采集器。
///
/// 全部走 Mach / BSD 系统调用，不依赖任何私有框架，因此在 TrollStore
/// 未签名安装的环境下也能正常工作。唯一有风险的是 CPU 负载：
/// 部分 iOS 版本会对 `host_statistics(HOST_CPU_LOAD_INFO)` 返回
/// KERN_FAILURE，此时 `cpuUsage` 会是 nil，UI 需要优雅降级。
final class SystemMetricsSampler {

    // MARK: - 单例

    static let shared = SystemMetricsSampler()
    private init() {
        memoryTotal = ProcessInfo.processInfo.physicalMemory
        networkBaseline = NetworkCounters.read()
    }

    // MARK: - 内部状态

    private var previousCPU: host_cpu_load_info?
    /// 上次采样的网络累计字节，用于算差值
    private var networkBaseline: NetworkCounters
    /// 上次采样时间，用于把差值换算成速率
    private var lastSampleTime: Date?
    /// 累计读写用于平滑
    private var smoothedDown: Double = 0
    private var smoothedUp: Double = 0

    private let memoryTotal: UInt64

    /// CPU 读取失败后不再反复尝试，避免每次采样都刷日志
    private var cpuProbeFailed = false

    // MARK: - 主入口

    /// 采一次样。注意：**必须**用固定间隔反复调用，
    /// CPU 与网速都是差分量，间隔不固定会导致读数抖动。
    func sample() -> MetricsSnapshot {
        var snap = MetricsSnapshot()
        let now = Date()

        // ---- CPU ----
        if let cpu = readCPUUsage() {
            snap.cpuUsage = cpu
        } else if cpuProbeFailed {
            snap.notes.append("系统拒绝提供 CPU 负载（沙盒限制）")
        }

        // ---- 内存 ----
        if let mem = readMemory() {
            snap.memoryUsed = mem.used
            snap.memoryTotal = mem.total
            snap.memoryWired = mem.wired
            snap.memoryCompressed = mem.compressed
            snap.memoryUsage = mem.total > 0 ? Double(mem.used) / Double(mem.total) : 0
        }
        snap.appMemory = readAppFootprint()

        // ---- 网络 ----
        let counters = NetworkCounters.read()
        snap.totalReceived = counters.received
        snap.totalSent = counters.sent
        snap.activeInterfaces = counters.interfaces

        let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0
        if elapsed > 0.05 {
            let dDown = Double(counters.received &- networkBaseline.received)
            let dUp = Double(counters.sent &- networkBaseline.sent)

            // 计数器回绕（或网卡重置）时差值会变成天文数字，直接丢弃
            let rawDown = (dDown >= 0 && dDown < 1e12) ? dDown / elapsed : 0
            let rawUp = (dUp >= 0 && dUp < 1e12) ? dUp / elapsed : 0

            // 指数平滑：网速跳变太剧烈会看不清，0.45 兼顾灵敏与稳定
            smoothedDown = smoothedDown * 0.55 + rawDown * 0.45
            smoothedUp = smoothedUp * 0.55 + rawUp * 0.45

            // 低于 1 KB/s 视为 0，避免显示 "312 B/s" 这种噪声
            snap.downloadSpeed = smoothedDown < 1024 ? 0 : smoothedDown
            snap.uploadSpeed = smoothedUp < 1024 ? 0 : smoothedUp
        }

        networkBaseline = counters
        lastSampleTime = now
        snap.timestamp = now
        return snap
    }

    /// 供**小组件**使用的采样式：现场做一次固定窗口的双读，直接给出瞬时速率。
    ///
    /// 小组件扩展每次刷新都可能是一个新进程，`networkBaseline` / `previousCPU`
    /// 这些实例状态不保证能延续，用常规 `sample()` 会拿到 0 或严重偏低的读数。
    /// 这里用一个很短的时间窗（默认 200 ms）自己造基准，缺点是无法平滑，
    /// 但小组件本来就只有 1 分钟级别的刷新，瞬时值反而是对的。
    func sampleInstantaneous(window: TimeInterval = 0.2) -> MetricsSnapshot {
        var snap = MetricsSnapshot()
        let gap = max(window, 0.05)

        // CPU 与网速都是差分量：先读一次建立基准
        _ = readCPUUsage()
        let firstNet = NetworkCounters.read()
        let start = Date()

        usleep(useconds_t(gap * 1_000_000))

        if let cpu = readCPUUsage() {
            snap.cpuUsage = cpu
        } else if cpuProbeFailed {
            snap.notes.append("系统拒绝提供 CPU 负载（沙盒限制）")
        }

        if let mem = readMemory() {
            snap.memoryUsed = mem.used
            snap.memoryTotal = mem.total
            snap.memoryWired = mem.wired
            snap.memoryCompressed = mem.compressed
            snap.memoryUsage = mem.total > 0 ? Double(mem.used) / Double(mem.total) : 0
        }
        snap.appMemory = readAppFootprint()

        let secondNet = NetworkCounters.read()
        snap.totalReceived = secondNet.received
        snap.totalSent = secondNet.sent
        snap.activeInterfaces = secondNet.interfaces

        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let dDown = Double(secondNet.received &- firstNet.received)
        let dUp = Double(secondNet.sent &- firstNet.sent)
        if dDown >= 0 && dDown < 1e12 {
            let raw = dDown / elapsed
            snap.downloadSpeed = raw < 1024 ? 0 : raw   // 低于 1 KB/s 归零，去掉噪声
        }
        if dUp >= 0 && dUp < 1e12 {
            let raw = dUp / elapsed
            snap.uploadSpeed = raw < 1024 ? 0 : raw
        }

        snap.timestamp = Date()
        return snap
    }

    /// 重置差分基准。切到前台 / 从后台回来时调用，避免算出离谱的瞬时速率。
    func resetBaselines() {
        networkBaseline = NetworkCounters.read()
        lastSampleTime = nil
        smoothedDown = 0
        smoothedUp = 0
        previousCPU = nil
    }

    // MARK: - CPU

    /// 通过 HOST_CPU_LOAD_INFO 读 tick 计数，两次采样求差。
    private func readCPUUsage() -> Double? {
        guard !cpuProbeFailed else { return nil }

        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            cpuProbeFailed = true
            return nil
        }

        defer { previousCPU = info }
        guard let prev = previousCPU else { return nil }

        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)

        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }

        return min(max(busy / total, 0), 1)
    }

    // MARK: - 内存

    private struct MemoryInfo {
        var used: UInt64
        var total: UInt64
        var wired: UInt64
        var compressed: UInt64
    }

    /// 通过 HOST_VM_INFO64 读页统计。
    private func readMemory() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)

        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // 可清除页（文件缓存）在 iOS 上算「可用」，不计入已用
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize

        // 用量口径对齐「设置 → 通用 → iPhone 储存空间」附近的内存显示：
        // 已用 ≈ Active + Wired + Compressed，Inactive 视为可回收不计。
        var used = active &+ wired &+ compressed
        let deductible = purgeable &+ speculative
        used = used > deductible ? used &- deductible : used

        return MemoryInfo(
            used: min(used, memoryTotal),
            total: memoryTotal,
            wired: wired,
            compressed: compressed
        )
    }

    /// 本 App 的内存占用，走 task_vm_info 的 phys_footprint。
    private func readAppFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    // MARK: - 设备信息

    /// 芯片型号，用于在界面上显示（如 "iPhone 14 Pro"）
    static var deviceModel: String {
        // 模拟器 / 真机都可用；不同 iOS 版本字段名不同，做兜底
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "iOS 设备" : machine
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
