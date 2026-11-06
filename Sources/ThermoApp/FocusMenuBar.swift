import AppKit
import ThermoL10n

/// 独立的计时状态项，只在计时进行时出现，原 Thermo 状态项的指标和点击行为保持不变。
@MainActor final class FocusStatusItem: NSObject {
    static let shared = FocusStatusItem()
    private var item: NSStatusItem?
    private var ticker: Timer?
    private let model = FocusTimerModel.shared

    func start() {
        model.onChange = { [weak self] in self?.update() }
        update()
    }

    private func update() {
        guard let display = FocusMenuBarDisplay.make(model, now: Date(), showProgressIcon: FocusSettings.read().showProgressIcon) else {
            ticker?.invalidate(); ticker = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            RunLoop.main.add(timer, forMode: .common); ticker = timer
        }
        let item = self.item ?? makeItem()
        guard let button = item.button else { return }
        button.image = display.progress.map(FocusProgressIcon.make)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: (display.progress == nil ? "" : " ") + display.text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        let tip = model.phase.title + " · " + display.text
        if button.toolTip != tip { button.toolTip = tip }
        button.setAccessibilityLabel(tip)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        return item
    }

    @objc private func click() {
        guard let item else { return }
        // 与主状态项相同的做法：临时挂菜单弹出，再卸下，下次点击仍走这里。
        item.menu = StatusMenu.shared.focusMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }
}

enum FocusProgressIcon {
    static func make(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 1.5
            NSColor.black.setStroke(); track.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let pie = NSBezierPath()
            pie.move(to: center)
            pie.appendArc(withCenter: center, radius: ring.width / 2 - 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(1, max(0, progress))), clockwise: true)
            pie.close()
            NSColor.black.setFill(); pie.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
