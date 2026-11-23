# SysMon — iOS 16 系统监控

实时显示 **CPU 占用率 / 内存占用率 / 网速（下行 + 上行）**，两种查看方式：

| 形态 | 说明 | 状态 |
|---|---|---|
| **悬浮小窗** | 浮在其它 App 之上，边用手机边看 | 走 PiP（画中画）实现，见下方限制 |
| **负一屏小组件** | Today View 小组件，小/中两种尺寸 | WidgetKit，最小刷新间隔约 1 分钟 |

---

## 一、为什么悬浮窗只能走 PiP

iOS 没有任何公开 API 能创建系统级悬浮窗（那是 Android 的 `TYPE_APPLICATION_OVERLAY`）。
唯一合法的"浮在所有 App 之上"通道是**画中画**：

```
采样数据 → CoreGraphics 自绘 600×400 位图
        → CVPixelBuffer (32BGRA + IOSurface)
        → CMSampleBuffer
        → AVSampleBufferDisplayLayer
        → AVPictureInPictureController(contentSource:)
```

为了让 PiP 退到后台不被系统杀掉，必须声明 `UIBackgroundModes: audio` 并保持一个
音频会话在播放——本项目现场生成 1 秒**静音 WAV** 循环播放（`volume = 0`），
并用 `.mixWithOthers` 尽量减少对其它 App 的影响。

**代价（必须知道）**：
- 悬浮窗开着时占用音频通道，部分机型上正在播的音乐/视频可能被暂停
- 因此做成了**随时可开关**：主界面一个开关，不用就关掉，音频立刻恢复

---

## 二、安装（TrollStore，无需签名）

1. 手机需已装 **TrollStore**（iOS 14.0 – 16.6.1 / 17.0）
2. 从本仓库 **Actions → 最新一次 Build Unsigned IPA → Artifacts** 下载
   `SysMon-unsigned-ipa.zip`，解压得到 `SysMon-unsigned.ipa`
3. 传到手机（AirDrop / 隔空投送、文件 App、或 TrollStore 里的"从 URL 安装"）
4. 用 TrollStore 打开该 IPA → **Install**
5. 桌面出现「系统监视」图标

> 未签名包不具备有效描述文件，**不能用 AltStore / Sideloadly / Xcode 直接装**，
> 只能走 TrollStore（或自签后重签）。

---

## 三、怎么用

### 悬浮小窗
1. 打开 App → 顶部把「悬浮窗」开关打开
2. 上滑退到桌面 → 小窗会自动浮现（首次可能需点一下小窗里的播放按钮）
3. 拖动到任意角落，可以盖在微信、浏览器、游戏上面
4. 关闭：回到 App 关掉开关，或在小窗上点关闭按钮

### 负一屏小组件
1. 桌面**右滑到底**进入「今天」视图
2. 拉到底部点「编辑」→ 左上角「+」→ 搜索「系统监视」
3. 选小号或中号 → 添加
4. 长按小组件可切换尺寸

小组件每 **20 秒** 生成一组数据、60 秒后请求刷新，实际刷新节奏由系统决定
（iOS 会按你的使用习惯调度，通常 1–15 分钟）。要**秒级实时**请看悬浮窗。

---

## 四、数据从哪来 / 口径是什么

| 指标 | 实现 | 口径 |
|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` 差分 `cpu_ticks` | `(user + system) / (user + system + idle + nice)` |
| 内存已用 | `host_statistics64(HOST_VM_INFO64)` × `vm_kernel_page_size` | `Active + Wired + Compressed − Purgeable − Speculative` |
| 内存占比 | 已用 / 物理总内存 | — |
| 本进程内存 | `task_info(TASK_VM_INFO).phys_footprint` | 与「设置 → 电池」口径一致 |
| 下行/上行速率 | `getifaddrs` 读 `AF_LINK` 的 `if_data.ifi_ibytes/ifi_obytes` 差分 | 排除 `lo / utun / ipsec / ppp / gif / stf / awdl / llw / anpi / XHC / bridge` 及 VLAN 子接口 |

### 小组件为什么要"现场双读"

Widget 扩展是**独立进程、每次刷新都是新的**，进程内不保留上一次的计数器基线，
所以差分会全部失效。为此小组件走 `sampleInstantaneous(window: 0.2)`：
先读一次、`usleep(200ms)`、再读一次，用这 200ms 的差值换算速率。
因此小组件显示的网速是**最近 200 毫秒的平均值**，CPU 也是这 200ms 的占用。

---

## 五、已知限制

- **CPU 可能显示「—」**：`host_statistics` 在部分系统版本/沙盒环境下会被拒绝。
  代码里有降级路径，拒绝时显示「—」而不是假装 0。
- **小组件不是秒级**：WidgetKit 不允许 1 秒刷新，这是系统硬限制，无法绕过。
- **悬浮窗在锁屏 / 部分全屏视频下会被系统收起**，这是 PiP 本身的规则。
- **不支持 App Group 共享数据**：未签名 + TrollStore 无法获得真实 App Group，
  所以两个 target 各自独立采样，代码通过 `Shared/` 目录两边编译复用。

---

## 六、自己编译

```bash
brew install xcodegen
xcodegen generate
open SysMon.xcodeproj   # 需要 macOS + Xcode 16
```

云编译：push 到 `main` 即触发 `.github/workflows/build.yml`（`macos-15`），
产物在 Actions 的 Artifacts 里。

---

## 七、目录结构

```
SysMon/
├── App/SysMonApp.swift            入口，启动采样
├── Shared/
│   ├── Metrics.swift              数据结构 + 格式化
│   ├── SystemMetricsSampler.swift Mach / getifaddrs 采样
│   ├── NetworkCounters.swift      网卡字节计数
│   └── MetricsStore.swift         1 秒节拍 + 历史曲线
├── PiP/
│   ├── FloatingWindowController.swift  PiP 全流程
│   └── FloatingRenderer.swift          600×400 自绘
├── Views/ContentView.swift         主界面
├── Widget/                         WidgetKit 扩展
└── Assets.xcassets/                图标
```
