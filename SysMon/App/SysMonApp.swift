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
                        // 关掉定时器会让小窗上的数字冻住。
                        if floating.isActive {
                            MetricsStore.shared.start()
                        }
                    default:
                        break
                    }
                }
        }
    }
}
