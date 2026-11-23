import WidgetKit
import SwiftUI

/// 小组件扩展的入口。
/// 目前只提供一个「系统监视」小组件，后续若要加电池/温度卡片，在这里追加即可。
@main
struct SysMonWidgetBundle: WidgetBundle {
    var body: some Widget {
        SysMonWidget()
    }
}
