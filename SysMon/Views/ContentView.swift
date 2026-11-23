import SwiftUI

/// 主界面：实时显示 CPU / 内存 / 网络，并提供悬浮窗开关。
struct ContentView: View {

    @ObservedObject private var store = MetricsStore.shared
    @ObservedObject private var floating = FloatingWindowController.shared

    private var snap: MetricsSnapshot { store.snapshot }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.05).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        headerCard
                        cpuCard
                        memoryCard
                        networkCard
                        floatingCard
                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)

                // 画中画的宿主视图：必须是层级里真实存在的一个 view，
                // 但可以完全透明、尺寸为 1×1，用户看不到它。
                PiPHostView()
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
            .navigationTitle("系统监视")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.toggle()
                    } label: {
                        Image(systemName: store.isRunning ? "pause.circle" : "play.circle")
                            .font(.system(size: 18))
                    }
                    .tint(.white)
                }
            }
        }
    }

    // MARK: - 顶部概要

    private var headerCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SystemMetricsSampler.deviceModel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("iOS \(SystemMetricsSampler.systemVersion)  ·  \(store.interval == 1 ? "每秒刷新" : String(format: "%.1f 秒刷新", store.interval))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.isRunning ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(store.isRunning ? "采集中" : "已暂停")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.isRunning ? .green : .secondary)
                }
                Text(timeText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBackground)
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: snap.timestamp)
    }

    // MARK: - CPU

    private var cpuCard: some View {
        MetricCard(title: "CPU", accent: Color(red: 0.42, green: 0.55, blue: 1.0)) {
            HStack(alignment: .center, spacing: 20) {
                if let cpu = snap.cpuUsage {
                    RingGauge(progress: cpu,
                              color: Color(red: 0.42, green: 0.55, blue: 1.0),
                              text: Fmt.percent(cpu))
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("历史曲线", "")
                        Sparkline(values: store.history,
                                  color: Color(red: 0.42, green: 0.55, blue: 1.0))
                            .frame(height: 44)
                        Text("近 \(store.history.count) 次采样的平均值 \(averageText(store.history))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    unavailableBlock(text: "系统未开放 CPU 负载读数")
                }
            }
        }
    }

    private func averageText(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        return Fmt.percent(values.reduce(0, +) / Double(values.count))
    }

    // MARK: - 内存

    private var memoryCard: some View {
        MetricCard(title: "内存", accent: Color(red: 0.31, green: 0.85, blue: 0.55)) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.percent(snap.memoryUsage))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.31, green: 0.85, blue: 0.55))
                    Spacer()
                    Text("\(Fmt.bytes(snap.memoryUsed)) / \(Fmt.bytes(snap.memoryTotal))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressBar(progress: snap.memoryUsage,
                            color: Color(red: 0.31, green: 0.85, blue: 0.55))

                HStack {
                    smallStat("Wired", Fmt.bytes(snap.memoryWired))
                    Divider().frame(height: 22).overlay(Color.white.opacity(0.08))
                    smallStat("Compressed", Fmt.bytes(snap.memoryCompressed))
                    Divider().frame(height: 22).overlay(Color.white.opacity(0.08))
                    smallStat("本 App", Fmt.bytes(snap.appMemory))
                }
                .padding(.top, 2)
            }
        }
    }

    private func smallStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 网络

    private var networkCard: some View {
        MetricCard(title: "网络", accent: Color(red: 1.0, green: 0.66, blue: 0.26)) {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    speedBlock(down: true,
                               speed: snap.downloadSpeed,
                               color: Color(red: 0.42, green: 0.55, blue: 1.0))
                    Divider().frame(height: 40).overlay(Color.white.opacity(0.08))
                    speedBlock(down: false,
                               speed: snap.uploadSpeed,
                               color: Color(red: 1.0, green: 0.66, blue: 0.26))
                }

                HStack {
                    Text("累计 ↓ \(Fmt.bytes(snap.totalReceived))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("↑ \(Fmt.bytes(snap.totalSent))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !snap.activeInterfaces.isEmpty {
                    HStack(spacing: 6) {
                        Text("网卡")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(snap.activeInterfaces.joined(separator: " · "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                    }
                }
            }
        }
    }

    private func speedBlock(down: Bool, speed: Double, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: down ? "arrow.down" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.speed(speed))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(down ? "下行" : "上行")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 悬浮窗

    private var floatingCard: some View {
        MetricCard(title: "悬浮小窗", accent: Color.white.opacity(0.75)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { floating.isActive },
                    set: { wantOn in
                        if wantOn { floating.start() } else { floating.stop() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("画中画悬浮显示")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        Text("离开 App 后也能看到实时指标")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color(red: 0.31, green: 0.85, blue: 0.55))
                .disabled(!floating.isSupported)

                if !floating.isSupported {
                    noteText("此设备或系统版本不支持画中画", color: .orange)
                } else if floating.isActive {
                    noteText("小窗已开启。听音乐时如被抢占，点这里关闭即可恢复。", color: .secondary)
                } else {
                    noteText("开启后系统会占用音频通道，音乐 App 可能被短暂顶掉。", color: .secondary)
                }

                if let err = floating.lastError {
                    noteText(err, color: .orange)
                }
            }
        }
    }

    private func noteText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("把「系统监视」加入负一屏：回到桌面 → 左滑到底 → 编辑 → 自定 → 添加小组件")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("小组件由系统调度刷新，频率低于主界面的 1 秒节拍")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 6)
        .padding(.horizontal, 8)
    }

    private func unavailableBlock(text: String) -> some View {
        HStack(spacing: 12) {
            Text("—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(height: 62)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

// MARK: - 卡片容器

private struct MetricCard<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3, height: 12)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

private extension MetricCard {
    init(title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }
}

// MARK: - 环形进度

private struct RingGauge: View {
    let progress: Double
    let color: Color
    let text: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: progress)
            Text(text)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(width: 86, height: 86)
    }
}

// MARK: - 横向进度条

private struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
                    .animation(.easeOut(duration: 0.35), value: progress)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - 迷你折线

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = points(in: CGSize(width: w, height: h))

            ZStack {
                if pts.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let n = values.count
        let step = n > 1 ? size.width / CGFloat(n - 1) : size.width
        return values.enumerated().map { idx, v in
            let clamped = min(max(v, 0), 1)
            return CGPoint(x: CGFloat(idx) * step,
                           y: size.height * (1 - CGFloat(clamped)))
        }
    }
}

// MARK: - 画中画宿主

/// 只有把 `AVSampleBufferDisplayLayer` 挂进真实视图层级，画中画才会工作。
/// 这个视图本身不需要可见。
private struct PiPHostView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? HostView)?.reattach()
    }

    final class HostView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            reattach()
        }

        func reattach() {
            guard window != nil else { return }
            FloatingWindowController.shared.attachHostLayer(to: self)
        }
    }
}
