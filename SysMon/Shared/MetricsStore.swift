import Foundation
import Combine
import UIKit

/// 全局指标刷新中心。
///
/// 用固定 1 秒节拍驱动采样。之所以不用 `Timer.publish`，
/// 是因为它在滚动 / 后台切换时会漂移，导致网速差分量忽大忽小。
@MainActor
final class MetricsStore: ObservableObject {

    static let shared = MetricsStore()

    @Published private(set) var snapshot: MetricsSnapshot = .empty
    @Published private(set) var history: [Double] = []       // CPU 历史，画迷你曲线
    @Published private(set) var memoryHistory: [Double] = [] // 内存历史

    /// 刷新间隔，秒。可在设置页调整。
    @Published var interval: Double = 1.0 {
        didSet { restartIfRunning() }
    }

    /// 是否正在实时采样
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private let sampler = SystemMetricsSampler.shared
    private let maxHistory = 60

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sampler.resetBaselines()

        // 先同步采一次，界面不用等 1 秒才有数
        tick()

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common 让它在滚动视图拖动时也继续走，否则数值会"卡住"
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    /// App 从后台回前台时调用：丢掉了后台期间的累计差，必须重置基准
    func handleForeground() {
        sampler.resetBaselines()
        if isRunning { tick() }
    }

    // MARK: - 采样

    private func tick() {
        let snap = sampler.sample()
        snapshot = snap

        if let cpu = snap.cpuUsage {
            history.append(cpu)
            if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        }
        memoryHistory.append(snap.memoryUsage)
        if memoryHistory.count > maxHistory {
            memoryHistory.removeFirst(memoryHistory.count - maxHistory)
        }
    }
}
