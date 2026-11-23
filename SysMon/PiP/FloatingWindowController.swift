import Foundation
import AVKit
import AVFoundation
import UIKit
import CoreVideo
import CoreMedia

/// 画中画悬浮小窗。
///
/// iOS 不允许第三方 App 创建"系统级悬浮窗"，唯一能在别的 App 之上显示
/// 自绘内容的合法途径是「画中画」：把指标画面渲染进 `CVPixelBuffer`，
/// 包成 `CMSampleBuffer` 喂给 `AVSampleBufferDisplayLayer`，
/// 由 `AVPictureInPictureController` 把这一层显示成系统小窗。
///
/// 代价：为了让小窗在离开 App 后不被系统回收，必须持有一个活动的
/// audio 音频会话。所以开启悬浮窗期间，音乐类 App 可能被抢占。
@MainActor
final class FloatingWindowController: NSObject, ObservableObject {

    static let shared = FloatingWindowController()

    // MARK: - 对外状态

    @Published private(set) var isSupported = false
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    // MARK: - 核心对象

    private var pipController: AVPictureInPictureController?
    private let displayLayer = AVSampleBufferDisplayLayer()

    /// 一个静音的音频源，仅用于维持 audio 会话存活
    private var silentPlayer: AVAudioPlayer?
    private var renderLink: CADisplayLink?
    private var tickCount = 0

    /// 两次重绘的最小间隔。
    ///
    /// 数据本身 1 秒一变，但这里故意做成 0.5 秒一次：
    /// 一是让右上角秒数看起来在走（用户会以为"卡住了"），
    /// 二是画中画的 CMSampleBuffer 长时间没有新样本时，系统有可能判定播放结束而关窗。
    private let frameIntervalSeconds: Double = 0.5

    /// 帧计数，用作 presentationTimeStamp。
    /// ★ 必须用**单调递增的计数器**做时间戳，不能用墙上时钟。
    ///   用真实时间的话，帧到达不均匀会导致时间基漂移，画面卡顿甚至被丢弃。
    private var frameCount: Int64 = 0

    private var latestSnapshot: MetricsSnapshot = .empty
    private var lastRenderTime: CFTimeInterval = 0

    /// 宿主 view。画中画要求 layer 附着在**真实可见**的视图上，
    /// 所以必须留一个引用，在启动时校验它的尺寸与可见性。
    private weak var hostView: UIView?

    /// 监听 isPictureInPicturePossible。这一项必须是 KVO，
    /// 不能靠定时轮询——系统在准备完成时会主动翻这个值。
    private var possibleObservation: NSKeyValueObservation?

    /// 时间基。AVSampleBufferDisplayLayer 没有这个就不会推进播放，
    /// 画中画会因为「没有在播放」而拒绝启动。
    private var controlTimebase: CMTimebase?

    // MARK: - 初始化

    private override init() {
        super.init()
        // iOS 15+ 支持 sampleBufferDisplayLayer 作为画中画内容源
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        configureDisplayLayer()
        registerNotifications()
    }

    private func configureDisplayLayer() {
        // ── 画中画渲染的强制合规项。
        //    少了它们，layer 在画中画里会被**静默禁用**：不崩溃、不打日志、只是黑屏。
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isOpaque = true                 // 关键：避免合成器降级

        // 背景不透明，避免画中画里出现透明穿帮（与我们喂的黑色底图一致）
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false

        // ── 时间基：告诉系统「这些帧按 1 倍速播放」。
        //    没有它，layer 会一直处于暂停状态，
        //    于是 isPictureInPicturePossible 永远为 false，startPictureInPicture() 无声失败。
        //    注意：CF 函数在 Swift 里参数是**无标签**的，写成 allocator: 会编译不过。
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            kCFAllocatorDefault,
            CMClockGetHostTimeClock(),
            &tb
        )
        if status == noErr, let timebase = tb {
            _ = CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()))
            _ = CMTimebaseSetRate(timebase, 1.0)
            displayLayer.controlTimebase = timebase
            controlTimebase = timebase
        }
    }

    private func registerNotifications() {
        // 这两个通知的 Swift 名字在不同 SDK 上导入结果不一致
        // （有时是 AVPictureInPictureController.didStart…，有时只保留全局常量），
        // 直接用原始字符串最保险。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePipStart),
            name: Notification.Name("AVPictureInPictureControllerDidStartPictureInPictureNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePipStop),
            name: Notification.Name("AVPictureInPictureControllerDidStopPictureInPictureNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePipRestore),
            name: Notification.Name("AVPictureInPictureControllerFailedToStartPictureInPictureNotification"),
            object: nil
        )
    }

    // MARK: - 宿主视图

    /// 调用方必须把返回的 layer 挂到某个 UIView 上，否则画中画无法工作。
    ///
    /// ★ 这个 view **不能是 0×0、不能 alpha≈0**。系统在判定是否允许画中画时，
    ///   会检查内容源 layer 所在视图是否可见可绘。之前用 1×1 + opacity 0.001，
    ///   结果 isPictureInPicturePossible 恒为 false，startPictureInPicture() 静默失败。
    ///   现在改成：可见（alpha=1）、可绘（有实际尺寸）、但不接收触摸、
    ///   不遮挡内容（放在最底层、尺寸取 1 点宽高的可见形式不够，改为真实的
    ///   缩略预览视图，用户还能看到一个小预览块）。
    func attachHostLayer(to view: UIView) {
        guard hostView !== view else {
            // 同一个 view 重复挂载，只需校正 frame
            displayLayer.frame = view.bounds
            return
        }
        hostView = view
        displayLayer.frame = view.bounds
        displayLayer.removeFromSuperlayer()
        view.layer.addSublayer(displayLayer)
    }

    /// 宿主视图尺寸变化时同步 layer 尺寸（旋转 / 布局变更）
    func syncHostLayerFrame() {
        guard let host = hostView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = host.bounds
        CATransaction.commit()
    }

    // MARK: - 开启 / 关闭

    func start() {
        guard isSupported else {
            lastError = "此设备不支持画中画"
            return
        }
        guard hostView != nil, let host = hostView else {
            lastError = "悬浮窗宿主视图未就绪，请先停留在主界面再开启"
            return
        }

        // 宿主必须是可见、有尺寸的。这是画中画启动的硬前提。
        guard host.window != nil, host.bounds.width >= 8, host.bounds.height >= 8 else {
            lastError = "悬浮窗宿主视图尺寸异常，请回到主界面重试"
            return
        }

        lastError = nil
        configureAudioSession()
        startSilentAudio()

        // 先喂一帧。系统在 layer 从未渲染过内容时会静默拒绝启动画中画。
        let snap = MetricsStore.shared.snapshot
        latestSnapshot = snap
        renderFrame(snap, force: true)

        // 创建控制器（只创建一次）
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            // 说明：不设置 requiresLinearPlayback / controlStyle。
            // 这些属性在不同 iOS 版本上的可写性不一致，KVC 写不存在的 key 会直接抛异常崩溃。
            // 我们的 playbackDelegate 已经返回「无限时长的直播」，小窗上本来就不会出现进度条。
            pipController = controller

            // ★ KVO 监听：这是官方推荐做法。
            //   系统准备完成时会把 isPictureInPicturePossible 翻成 true，
            //   我们在这里才调用 startPictureInPicture()。
            possibleObservation = controller.observe(
                \.isPictureInPicturePossible,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let self, change.newValue == true else { return }
                self.startRendering()
                if !self.isActive, let c = self.pipController, !c.isPictureInPictureActive {
                    c.startPictureInPicture()
                }
            }
        }

        startRendering()

        guard let controller = pipController else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // 不再只等一次 0.6 秒就放弃。
            // 系统可能需要几秒来准备内容源（尤其在刚进前台时）。
            // 用 KVO 兜底，同时保留一个 3 秒的超时提示。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                guard let c = self.pipController else { return }
                if !self.isActive && !c.isPictureInPictureActive && !c.isPictureInPicturePossible {
                    self.lastError = "画中画启动超时。请确认已开启「后台音频」并保持 App 在前台时点击开关。"
                }
            }
        }
    }

    func stop() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        pipController?.stopPictureInPicture()
        stopRendering()
        stopSilentAudio()
        deactivateAudioSession()
        isActive = false
    }

    func toggle() {
        isActive ? stop() : start()
    }

    // MARK: - 音视频会话

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers：尽量与其他音频共存，别一开悬浮窗就把音乐掐了
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = "音频会话配置失败：\(error.localizedDescription)"
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 生成一段极低幅度的音频循环播放。
    ///
    /// ★ 为什么不能用「全 0 采样 + volume=0」：
    ///   iOS 会检测音频是否真的有声。全静音时系统判定「这个 App 其实没在放音」，
    ///   于是降级 audio session，App 进后台后被挂起，画中画小窗随即消失。
    ///   这里改用 **-60 dBFS 的正弦波**（约 0.1% 幅度，人耳完全听不见），
    ///   系统认为有真实音频在播，session 就不会被降级。
    private func startSilentAudio() {
        guard silentPlayer == nil else { return }
        guard let url = Self.makeNearSilentWav(duration: 2.0) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1.0     // ★ 必须 1.0，靠波形本身极小来保持安静
            player.prepareToPlay()
            player.play()
            silentPlayer = player
        } catch {
            lastError = "静音音频启动失败：\(error.localizedDescription)"
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
    }

    /// 现场构造一个 -60 dBFS 的正弦波 WAV。
    ///
    /// 幅度 0.001（≈ -60 dBFS），20 Hz 这个频率在手机上根本放不出来，
    /// 双重保险保证绝对听不到，但采样值不为 0 —— 这点是骗过系统音频活动检测的关键。
    private static func makeNearSilentWav(duration: Double) -> URL? {
        let sampleRate = 8000
        let frameCount = Int(Double(sampleRate) * duration)
        let dataSize = frameCount * 2   // 16-bit mono

        let amplitude: Double = 0.001    // -60 dBFS
        let freq: Double = 20.0          // 低频，手机扬声器/耳机都放不出

        var data = Data()
        func append(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)                                   // PCM
        append16(1)                                   // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))              // byte rate
        append16(2)                                   // block align
        append16(16)                                  // bits per sample
        append("data")
        append32(UInt32(dataSize))

        var pcm = Data(capacity: dataSize)
        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            let v = sin(2.0 * Double.pi * freq * t) * amplitude
            let s = Int16(max(-32767, min(32767, v * 32767.0)))
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        data.append(pcm)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sysmon-near-silent.wav")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 渲染循环

    private func startRendering() {
        guard renderLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onFrame))
        // 允许 2~10 fps，首选 4 fps。太低的帧率会让画中画看起来冻结。
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 10, preferred: 4)
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    private func stopRendering() {
        renderLink?.invalidate()
        renderLink = nil
    }

    @objc private func onFrame() {
        let now = CACurrentMediaTime()
        guard now - lastRenderTime >= frameIntervalSeconds else { return }
        lastRenderTime = now
        renderFrame(MetricsStore.shared.snapshot, force: false)
    }

    // MARK: - 画面渲染

    private func renderFrame(_ snap: MetricsSnapshot, force: Bool) {
        latestSnapshot = snap

        // 宿主尺寸变了就跟着改，否则画中画里会被拉伸
        syncHostLayerFrame()

        let size = CGSize(width: 600, height: 400)
        guard let image = FloatingRenderer.render(snapshot: snap, size: size) else { return }
        guard let buffer = Self.pixelBuffer(from: image, size: size) else { return }

        // ★ 单调递增的时间戳 + 固定 4fps 时间基。
        //   用墙上时钟会让时间基漂移，画中画里表现为卡顿/掉帧。
        frameCount += 1
        let pts = CMTime(value: frameCount, timescale: 4)
        guard let sample = Self.sampleBuffer(from: buffer, presentationTime: pts) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
            // flush 之后要重新设时间基，否则 layer 停在失败状态
            if let tb = controlTimebase {
                displayLayer.controlTimebase = tb
            }
        }
        displayLayer.enqueue(sample)
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 底色不透明，避免 PiP 上出现黑边或透明穿帮
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        guard let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private static func sampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let format = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return sample
    }

    // MARK: - 通知

    @objc private func handlePipStart() {
        isActive = true
        lastError = nil
    }

    @objc private func handlePipStop() {
        isActive = false
        stopRendering()
        stopSilentAudio()
        deactivateAudioSession()
    }

    @objc private func handlePipRestore() {
        // 无需处理，仅为占位避免误订阅
    }
}

// MARK: - 代理

extension FloatingWindowController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        lastError = nil
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        lastError = "启动悬浮窗失败：\(error.localizedDescription)"
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        stopRendering()
        stopSilentAudio()
        deactivateAudioSession()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点小窗上的「返回 App」按钮时，把主界面带回来
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            window.rootViewController?.dismiss(animated: false)
        }
        completionHandler(true)
    }
}

extension FloatingWindowController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // .positiveInfinity：告诉系统这是"直播"，小窗不显示进度条与时间
        CMTimeRange(
            start: .negativeInfinity,
            duration: .positiveInfinity
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
