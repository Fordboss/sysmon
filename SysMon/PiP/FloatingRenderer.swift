import UIKit

/// 把指标画成一张图，供画中画小窗喂帧。
///
/// 用 UIGraphicsImageRenderer 而不是手写 CoreGraphics。
/// 注意：这里刻意不依赖任何 SwiftUI，因为画中画需要确定性尺寸的位图。
enum FloatingRenderer {

    static func render(snapshot: MetricsSnapshot, size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1          // 已经是 600×400，不需要额外倍数
            f.opaque = true      // 不透明，PiP 上不出现透明边
            return f
        }())

        return renderer.image { ctx in
            let cg = ctx.cgContext
            draw(cg: cg, snapshot: snapshot, size: size)
        }
    }

    // MARK: - 配色

    private static let bgColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
    private static let cardColor = UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1)
    private static let textPrimary = UIColor.white
    private static let textSecondary = UIColor(white: 0.62, alpha: 1)

    // 三个指标的主色：CPU 蓝紫、内存绿、网速橙
    private static let cpuColor = UIColor(red: 0.42, green: 0.55, blue: 1.0, alpha: 1)
    private static let memColor = UIColor(red: 0.31, green: 0.85, blue: 0.55, alpha: 1)
    private static let netColor = UIColor(red: 1.0, green: 0.66, blue: 0.26, alpha: 1)

    // MARK: - 绘制

    private static func draw(cg: CGContext, snapshot snap: MetricsSnapshot, size: CGSize) {
        let W = size.width
        let H = size.height

        // 背景
        cg.setFillColor(bgColor.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // 顶部标题条
        let titleH: CGFloat = 54
        let title = "系统监视"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: textSecondary
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: 24, y: 16))

        // 右上角时间戳，让小窗看起来是"活的"
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium),
            .foregroundColor: textSecondary
        ]
        let timeStr = NSAttributedString(string: df.string(from: snap.timestamp), attributes: timeAttrs)
        let timeSize = timeStr.size()
        timeStr.draw(at: CGPoint(x: W - timeSize.width - 24, y: 18))

        // 三块指标：CPU / 内存 / 网速，横向等分
        let contentTop = titleH + 8
        let contentH = H - contentTop - 20
        let gap: CGFloat = 14
        let cardW = (W - 24 * 2 - gap * 2) / 3

        drawCPU(cg: cg, snap: snap, rect: CGRect(x: 24, y: contentTop, width: cardW, height: contentH))
        drawMemory(cg: cg, snap: snap, rect: CGRect(x: 24 + cardW + gap, y: contentTop, width: cardW, height: contentH))
        drawNetwork(cg: cg, snap: snap, rect: CGRect(x: 24 + (cardW + gap) * 2, y: contentTop, width: cardW, height: contentH))
    }

    // MARK: CPU 卡片

    private static func drawCPU(cg: CGContext, snap: MetricsSnapshot, rect: CGRect) {
        drawCard(cg: cg, rect: rect)
        let inner = rect.insetBy(dx: 16, dy: 14)

        drawLabel("CPU", color: cpuColor, at: CGPoint(x: inner.minX, y: inner.minY))

        if let cpu = snap.cpuUsage {
            // 大数字
            let val = Fmt.percent(cpu)
            drawBigNumber(val, color: cpuColor, topLeft: CGPoint(x: inner.minX, y: inner.minY + 26), fontSize: 40)

            // 环形进度
            let ringSize: CGFloat = min(inner.width, inner.height - 92) - 4
            if ringSize > 30 {
                let center = CGPoint(x: inner.midX, y: inner.maxY - ringSize / 2 - 8)
                drawRing(cg: cg,
                         center: center,
                         radius: ringSize / 2 - 5,
                         progress: cpu,
                         color: cpuColor)
            }
        } else {
            // 降级：显示「—」并说明原因
            drawBigNumber("—", color: textSecondary, topLeft: CGPoint(x: inner.minX, y: inner.minY + 26), fontSize: 40)
            let note = NSAttributedString(string: "系统未开放", attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: textSecondary
            ])
            note.draw(at: CGPoint(x: inner.minX, y: inner.maxY - 26))
        }
    }

    // MARK: 内存卡片

    private static func drawMemory(cg: CGContext, snap: MetricsSnapshot, rect: CGRect) {
        drawCard(cg: cg, rect: rect)
        let inner = rect.insetBy(dx: 16, dy: 14)

        drawLabel("内存", color: memColor, at: CGPoint(x: inner.minX, y: inner.minY))

        let ratio = snap.memoryUsage
        drawBigNumber(Fmt.percent(ratio), color: memColor, topLeft: CGPoint(x: inner.minX, y: inner.minY + 26), fontSize: 40)

        // 竖向进度条：比环形更省地方，且能显示细节
        let barW: CGFloat = 14
        let barH = inner.height - 96
        if barH > 20 {
            let barRect = CGRect(x: inner.minX, y: inner.minY + 82, width: barW, height: barH)
            drawVerticalBar(cg: cg, rect: barRect, progress: ratio, color: memColor)

            // 右侧文字：已用 / 总量
            let usedText = NSAttributedString(string: Fmt.bytes(snap.memoryUsed), attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
                .foregroundColor: textPrimary
            ])
            usedText.draw(at: CGPoint(x: barRect.maxX + 10, y: barRect.minY + 2))

            let totalText = NSAttributedString(string: "共 \(Fmt.bytes(snap.memoryTotal))", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: textSecondary
            ])
            totalText.draw(at: CGPoint(x: barRect.maxX + 10, y: barRect.minY + 24))
        }
    }

    // MARK: 网络卡片

    private static func drawNetwork(cg: CGContext, snap: MetricsSnapshot, rect: CGRect) {
        drawCard(cg: cg, rect: rect)
        let inner = rect.insetBy(dx: 16, dy: 14)

        drawLabel("网络", color: netColor, at: CGPoint(x: inner.minX, y: inner.minY))

        // 下行
        drawArrow(cg: cg, origin: CGPoint(x: inner.minX + 2, y: inner.minY + 40), down: true, color: netColor)
        let downText = NSAttributedString(string: Fmt.speed(snap.downloadSpeed), attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: textPrimary
        ])
        downText.draw(at: CGPoint(x: inner.minX + 22, y: inner.minY + 30))

        // 上行
        drawArrow(cg: cg, origin: CGPoint(x: inner.minX + 2, y: inner.minY + 92), down: false, color: netColor)
        let upText = NSAttributedString(string: Fmt.speed(snap.uploadSpeed), attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: textPrimary
        ])
        upText.draw(at: CGPoint(x: inner.minX + 22, y: inner.minY + 82))

        // 底部累计量，字号小
        let totalText = NSAttributedString(string: "累计 ↓\(Fmt.bytes(snap.totalReceived))  ↑\(Fmt.bytes(snap.totalSent))", attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: textSecondary
        ])
        totalText.draw(at: CGPoint(x: inner.minX, y: inner.maxY - 18))
    }

    // MARK: - 基础绘制工具

    private static func drawCard(cg: CGContext, rect: CGRect) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
        cg.setFillColor(cardColor.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
    }

    private static func drawLabel(_ text: String, color: UIColor, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: color
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }

    private static func drawBigNumber(_ text: String, color: UIColor, topLeft: CGPoint, fontSize: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: topLeft)
    }

    private static func drawRing(cg: CGContext, center: CGPoint, radius: CGFloat, progress: Double, color: UIColor) {
        let lineWidth: CGFloat = 8
        // 轨道
        cg.setStrokeColor(UIColor(white: 1, alpha: 0.10).cgColor)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        cg.strokePath()

        // 进度
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0.001 else { return }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.addArc(
            center: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + .pi * 2 * CGFloat(clamped),
            clockwise: false
        )
        cg.strokePath()
    }

    private static func drawVerticalBar(cg: CGContext, rect: CGRect, progress: Double, color: UIColor) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.width / 2)
        cg.setFillColor(UIColor(white: 1, alpha: 0.10).cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0.001 else { return }
        let fillH = rect.height * CGFloat(clamped)
        let fillRect = CGRect(x: rect.minX, y: rect.maxY - fillH, width: rect.width, height: fillH)
        let fillPath = UIBezierPath(roundedRect: fillRect, cornerRadius: rect.width / 2)
        cg.setFillColor(color.cgColor)
        cg.addPath(fillPath.cgPath)
        cg.fillPath()
    }

    private static func drawArrow(cg: CGContext, origin: CGPoint, down: Bool, color: UIColor) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(2.5)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        let len: CGFloat = 12
        cg.move(to: origin)
        cg.addLine(to: CGPoint(x: origin.x, y: origin.y + len))

        if down {
            cg.move(to: CGPoint(x: origin.x - 4, y: origin.y + len - 4))
            cg.addLine(to: CGPoint(x: origin.x, y: origin.y + len))
            cg.addLine(to: CGPoint(x: origin.x + 4, y: origin.y + len - 4))
        } else {
            cg.move(to: CGPoint(x: origin.x - 4, y: origin.y + 4))
            cg.addLine(to: CGPoint(x: origin.x, y: origin.y))
            cg.addLine(to: CGPoint(x: origin.x + 4, y: origin.y + 4))
        }
        cg.strokePath()
    }
}
