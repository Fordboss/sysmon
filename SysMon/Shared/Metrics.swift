import Foundation

/// 一次采样得到的全部指标。
/// 全部字段都是「整个设备」的数值，不是本 App 自己的。
struct MetricsSnapshot: Equatable {

    // MARK: CPU
    /// 设备整体 CPU 占用率，0...1。nil 表示系统拒绝读取（沙盒限制）。
    var cpuUsage: Double?

    // MARK: 内存
    /// 已用内存字节数（Active + Inactive + Wired + Compressed，扣掉可回收部分）
    var memoryUsed: UInt64 = 0
    /// 物理内存总量
    var memoryTotal: UInt64 = 0
    /// 已用比例 0...1
    var memoryUsage: Double = 0
    /// Wired（内核常驻，不可压缩）
    var memoryWired: UInt64 = 0
    /// 被压缩器压缩占用
    var memoryCompressed: UInt64 = 0
    /// 本 App 自身占用（phys_footprint）
    var appMemory: UInt64 = 0

    // MARK: 网络
    /// 下行速率，字节/秒
    var downloadSpeed: Double = 0
    /// 上行速率，字节/秒
    var uploadSpeed: Double = 0
    /// 累计下行字节
    var totalReceived: UInt64 = 0
    /// 累计上行字节
    var totalSent: UInt64 = 0
    /// 参与统计的网卡名，便于排查（如 en0）
    var activeInterfaces: [String] = []

    // MARK: 元信息
    var timestamp: Date = Date()
    /// 采样过程中遇到的非致命问题，用于在设置页展示
    var notes: [String] = []

    static let empty = MetricsSnapshot()

    /// 是否至少拿到了 CPU 或内存其中一项
    var hasAnyData: Bool {
        cpuUsage != nil || memoryTotal > 0
    }
}

// MARK: - 格式化

enum Fmt {

    /// 字节数 → "1.2 GB"
    static func bytes(_ value: UInt64) -> String {
        byteString(Double(value))
    }

    static func byteString(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, value)
        var idx = 0
        while v >= 1024 && idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        if idx == 0 {
            return String(format: "%.0f %@", v, units[idx])
        }
        // 大于 100 时不留小数，读数更稳、不会跳动
        if v >= 100 {
            return String(format: "%.0f %@", v, units[idx])
        }
        return String(format: "%.1f %@", v, units[idx])
    }

    /// 字节/秒 → "12.3 MB/s"
    static func speed(_ bytesPerSecond: Double) -> String {
        byteString(bytesPerSecond) + "/s"
    }

    /// 0...1 → "42%"
    static func percent(_ ratio: Double) -> String {
        let clamped = min(max(ratio, 0), 1)
        return String(format: "%.0f%%", clamped * 100)
    }

    /// 0...1 → "42.6%"（需要精度时用）
    static func percentPrecise(_ ratio: Double) -> String {
        let clamped = min(max(ratio, 0), 1)
        return String(format: "%.1f%%", clamped * 100)
    }
}
