import WidgetKit
import SwiftUI

// MARK: - Timeline 数据模型

struct MetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: MetricsSnapshot
}

// MARK: - Provider

/// 负一屏小组件的刷新完全由系统调度（通常 1～15 分钟一次，
/// 受 App 使用频率、电量、低电量模式影响），**做不到**主界面那样的 1 秒节拍。
/// 所以这里给多条 entry，让系统在两次刷新之间也能自动翻页显示"较新"的读数。
struct Provider: TimelineProvider {

    /// 负一屏编辑界面里的占位样式，不跑真实采样
    func placeholder(in context: Context) -> MetricsEntry {
        MetricsEntry(date: Date(), snapshot: .sample)
    }

    /// 添加小组件时的预览快照。这里跑一次瞬时采样，让预览就是真数据
    func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
        if context.isPreview {
            completion(MetricsEntry(date: Date(), snapshot: .sample))
            return
        }
        let snap = SystemMetricsSampler.shared.sampleInstantaneous()
        completion(MetricsEntry(date: Date(), snapshot: snap))
    }

    /// 真正的刷新时刻。系统调用这里后，我们给 3 条 entry（0 / 20 / 40 秒），
    /// 然后请求 60 秒后再来一次。
    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        var entries: [MetricsEntry] = []
        var latest = MetricsSnapshot.sample

        for index in 0..<3 {
            // 只有第一条真正打一次差分采样（会阻塞 200ms），
            // 后面几条复用同一份数据，只推后时间戳——避免白白多阻塞 400ms
            if index == 0 {
                latest = SystemMetricsSampler.shared.sampleInstantaneous()
            }
            let date = Date().addingTimeInterval(Double(index) * 20)
            entries.append(MetricsEntry(date: date, snapshot: latest))
        }

        // 60 秒后再刷新。系统可能推迟，但不会早于这个时间
        let next = Date().addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - 小组件声明

struct SysMonWidget: Widget {
    let kind = "SysMonWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SysMonWidgetView(entry: entry)
        }
        .configurationDisplayName("系统监视")
        .description("实时查看 CPU 占用、内存占用和当前网速。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 视图

struct SysMonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricsEntry

    private var snap: MetricsSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumLayout
            default:
                smallLayout
            }
        }
        .widgetBackground(Color(red: 0.05, green: 0.05, blue: 0.07))
    }

    // MARK: 小尺寸：竖排三行

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("系统监视")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer(minLength: 2)
                Text(timeText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.bottom, 7)

            row(title: "CPU", value: cpuText, ratio: snap.cpuUsage, color: Palette.cpu)
            Spacer(minLength: 5)
            row(title: "内存", value: Fmt.percent(snap.memoryUsage), ratio: snap.memoryUsage, color: Palette.mem)
            Spacer(minLength: 5)
            row(title: "网速", value: Fmt.speed(snap.downloadSpeed), ratio: nil, color: Palette.net)
        }
        .padding(.horizontal, 2)
    }

    /// 一行：左边标题 + 细进度条，右边数值
    private func row(title: String, value: String, ratio: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer(minLength: 2)
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let ratio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(width: max(2, geo.size.width * min(max(ratio, 0), 1)))
                    }
                }
                .frame(height: 2.5)
            }
        }
    }

    // MARK: 中尺寸：横排三栏

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("系统监视")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(snap.activeInterfaces.isEmpty ? "无网络" : snap.activeInterfaces.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.bottom, 8)

            HStack(spacing: 0) {
                column(
                    title: "CPU",
                    value: cpuText,
                    detail: "近 1 分钟均值",
                    ratio: snap.cpuUsage,
                    color: Palette.cpu
                )
                divider
                column(
                    title: "内存",
                    value: Fmt.percent(snap.memoryUsage),
                    detail: "\(Fmt.bytes(snap.memoryUsed)) / \(Fmt.bytes(snap.memoryTotal))",
                    ratio: snap.memoryUsage,
                    color: Palette.mem
                )
                divider
                column(
                    title: "网速",
                    value: Fmt.speed(snap.downloadSpeed),
                    detail: "↑ \(Fmt.speed(snap.uploadSpeed))",
                    ratio: nil,
                    color: Palette.net
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }

    private func column(title: String, value: String, detail: String, ratio: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let ratio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(color)
                            .frame(width: max(2, geo.size.width * min(max(ratio, 0), 1)))
                    }
                }
                .frame(height: 2.5)
                .padding(.trailing, 2)
            }
            Text(detail)
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 辅助

    private var cpuText: String {
        guard let cpu = snap.cpuUsage else { return "—" }
        return Fmt.percent(cpu)
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: entry.date)
    }
}

// MARK: - 配色（与主界面、悬浮窗保持一致）

private enum Palette {
    static let cpu = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let mem = Color(red: 0.31, green: 0.85, blue: 0.55)
    static let net = Color(red: 1.0, green: 0.66, blue: 0.26)
}

// MARK: - iOS 16 / 17 背景兼容

extension View {
    /// iOS 17 起小组件必须声明 containerBackground，否则系统会给出默认底色并
    /// 打警告；iOS 16 没有这个 API，退回普通 background。
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { color }
        } else {
            ZStack {
                color
                self
            }
        }
    }
}

// MARK: - 占位数据

extension MetricsSnapshot {
    /// 负一屏编辑界面的静态占位，写死一组好看的数值
    static var sample: MetricsSnapshot {
        var s = MetricsSnapshot()
        s.cpuUsage = 0.34
        s.memoryTotal = ProcessInfo.processInfo.physicalMemory
        s.memoryUsed = s.memoryTotal * 58 / 100
        s.memoryUsage = 0.58
        s.memoryWired = s.memoryTotal * 22 / 100
        s.memoryCompressed = s.memoryTotal * 9 / 100
        s.downloadSpeed = 3_400_000
        s.uploadSpeed = 420_000
        s.totalReceived = 8_200_000_000
        s.totalSent = 640_000_000
        s.activeInterfaces = ["en0"]
        return s
    }
}
