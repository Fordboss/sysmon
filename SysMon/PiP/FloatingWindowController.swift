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

    /// 每次喂帧的最小间隔。1 秒一帧足够显示，太频繁会耗电。
    private let frameIntervalSeconds: Double = 1.0

    private var latestSnapshot: MetricsSnapshot = .empty
    private var lastRenderTime: CFTimeInterval = 0

    // MARK: - 初始化

    private override init() {
        super.init()
        // iOS 15+ 支持 sampleBufferDisplayLayer 作为画中画内容源
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        configureDisplayLayer()
        registerNotifications()
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        // 静音、不打断其他正在播放的内容（尽力而为）
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
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
    /// 这个 view 可以是 0×0 且隐藏在界面外——系统只需要它是 view hierarchy 的一部分。
    func attachHostLayer(to view: UIView) {
        displayLayer.frame = view.bounds
        if displayLayer.superlayer == nil {
            view.layer.addSublayer(displayLayer)
        }
    }

    // MARK: - 开启 / 关闭

    func start() {
        guard isSupported else {
            lastError = "此设备不支持画中画"
            return
        }

        configureAudioSession()
        startSilentAudio()

        // 先把第一帧画出来，否则 PiP 会起来是黑屏
        let snap = MetricsStore.shared.snapshot
        latestSnapshot = snap
        renderFrame(snap, force: true)

        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = controller
        }

        startRendering()

        guard let controller = pipController, controller.isPictureInPicturePossible else {
            // 刚起来时 possible 可能还是 false，等 0.5 秒再试一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let c = self.pipController else { return }
                if c.isPictureInPicturePossible {
                    c.startPictureInPicture()
                } else {
                    self.lastError = "画中画暂时不可用，请稍后重试"
                }
            }
            return
        }

        controller.startPictureInPicture()
    }

    func stop() {
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

    /// 生成一段 1 秒静音 WAV 循环播放。
    /// 没有这个，App 进后台后 audio 会话会被挂起，PiP 小窗随即被系统关闭。
    private func startSilentAudio() {
        guard silentPlayer == nil else { return }
        guard let url = Self.makeSilentWav(duration: 1.0) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
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

    /// 现场构造一个最小的 16-bit 单声道静音 WAV
    private static func makeSilentWav(duration: Double) -> URL? {
        let sampleRate = 8000
        let frameCount = Int(Double(sampleRate) * duration)
        let dataSize = frameCount * 2   // 16-bit mono

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
        data.append(Data(repeating: 0, count: dataSize))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sysmon-silent.wav")
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 2, preferred: 1)
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
        // 小窗尺寸按 3:2 出图，系统会等比缩放；这里画 600×400 保证清晰
        let size = CGSize(width: 600, height: 400)
        guard let image = FloatingRenderer.render(snapshot: snap, size: size) else { return }
        guard let buffer = Self.pixelBuffer(from: image, size: size) else { return }
        guard let sample = Self.sampleBuffer(from: buffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
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
