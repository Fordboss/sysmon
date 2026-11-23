import Foundation
import Darwin

/// 网络累计字节计数（只统计物理网卡，排除 lo0 / utun 等虚拟接口）。
///
/// 用 `getifaddrs` 拿 AF_LINK 的 if_data，完全不涉及私有 API，
/// 也不需要额外的网络权限。累计值做差即可得速率。
struct NetworkCounters {
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var interfaces: [String] = []

    /// 明确要排除的接口前缀：回环与各类隧道/VPN 虚拟接口。
    /// 若把它们算进来，VPN 流量会被重复计数一倍。
    private static let excludedPrefixes = ["lo", "utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "anpi", "XHC", "bridge"]

    static func read() -> NetworkCounters {
        var result = NetworkCounters()

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return result
        }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            cursor = ifa.ifa_next

            // 只要链路层记录，里面带 if_data 收发字节
            guard let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            guard let dataPtr = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)

            guard !isExcluded(name) else { continue }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            let rcv = UInt64(data.ifi_ibytes)
            let snd = UInt64(data.ifi_obytes)

            // 全零接口（未启用）不计入列表
            if rcv == 0 && snd == 0 { continue }

            result.received &+= rcv
            result.sent &+= snd
            result.interfaces.append(name)
        }

        return result
    }

    private static func isExcluded(_ name: String) -> Bool {
        for prefix in excludedPrefixes where name.hasPrefix(prefix) {
            return true
        }
        // 虚拟接口形如 en0.100（VLAN），也排除
        if name.contains(".") { return true }
        return false
    }
}
