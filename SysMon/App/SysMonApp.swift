import SwiftUI
import UIKit

@main
struct SysMonApp: App {

    @ObservedObject private var store = MetricsStore.shared
    @ObservedObject private var floating = FloatingWindowController.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 全局外观：暗色更符合「监视器」的气质，也让画中画截图配色一致
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onAppear {
                    MetricsStore.shared.start()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        // 从后台回来必须重置差分基准，否则第一帧网速会爆表
                        MetricsStore.shared.handleForeground()
                    case .background:
                        // 采样继续跑：画中画小窗需要实时数据。
                        // 靠 UIBackgroundModes=audio + 持续播放极低幅度音频维持进程不被挂起。
                        if floating.isActive {
                            MetricsStore.shared.start()
                        }
                    case .inactive:
                        // inactive 是过渡态（下拉通知栏、来电横幅都会触发），
                        // 这里什么都不做，避免误把采样停掉
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
