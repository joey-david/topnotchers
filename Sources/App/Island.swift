import AppKit
import QuartzCore

final class IslandWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
}

/// Hosts the hand-built layer tree; never takes mouse events itself.
private final class LayerHost: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

final class IslandView: NSView {
    weak var controller: IslandController?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { controller?.click(convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { controller?.showMenu(e, in: self) }
    override func mouseEntered(with e: NSEvent) { controller?.pointerMoved() }
    override func mouseExited(with e: NSEvent) { controller?.pointerMoved() }
    override func mouseMoved(with e: NSEvent) { controller?.pointerMoved() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if controller?.key(e) != true { super.keyDown(with: e) } }
}

private final class Slot {
    let id: String
    let layer = CALayer()
    let dot = CALayer()
    var sprite: Sprite
    var anim: Anim?
    var dotState: AgentState?
    var leaving = false
    init(id: String, sprite: Sprite) { self.id = id; self.sprite = sprite }
}

final class IslandController: NSObject {
    private let window = IslandWindow()
    private let view = IslandView()
    private let host = LayerHost()
    private let root = CALayer()
    private let bar = CAShapeLayer(), panel = CAShapeLayer()
    private let trays: [Side: CAShapeLayer] = [.left: CAShapeLayer(), .right: CAShapeLayer()]
    private let mask = CALayer()
    private let barMask = CAShapeLayer()
    private let trayMasks: [Side: CAShapeLayer] = [.left: CAShapeLayer(), .right: CAShapeLayer()]
    private let slotLayer = CALayer()
    private var slots: [String: Slot] = [:]
    private var hits: [String: CGRect] = [:]
    private var wings: [Side: CGRect] = [:]
    private var trayRects: [Side: CGRect] = [:]
    private var notch = CGRect.zero
    private var height: CGFloat = 520
    /// The island draws on a fixed 520pt canvas pinned to the top of the window; the window itself
    /// stays a notch-high strip and only grows while a question panel is open, so the compositor
    /// isn't blending a big transparent sheet over whatever is underneath.
    private let holder = NSView()
    private var screenTop: CGFloat = 0, screenX: CGFloat = 0, screenW: CGFloat = 0
    private var windowTall = true
    private var shrinkToken = 0
    private var hovers: [Side: CGRect] = [:]
    private var visible = false
    /// Hidden by moving off screen. (Ordered out while a full-screen space is current, the window
    /// would come back on that one space only; ignoresMouseEvents would end the click-through of
    /// its transparent parts for good, and it spans the menu bar.)
    private var parked = true
    private var hideToken = 0
    /// Hidden along with the menu bar (full screen, or auto-hide): back when it slides down,
    /// for a question, or for a moment when an agent finishes.
    private var hushed = false
    private var menuBarDown = true
    private var flashUntil = Date.distantPast
    private var finished: Set<String> = []
    private var barTimer: DispatchSourceTimer?
    private var revealUntil = Date.distantPast
    private var screenID: CGDirectDisplayID = 0
    private var bubble: BubbleView?
    private var openSide: Side? {
        didSet {
            guard openSide != oldValue else { return }
            focusKey = nil
            zoneOrder = []
            roll = nil
            lens = nil
        }
    }
    /// The open side's sessions, one zone each: their order (frozen while open, so a zone never
    /// changes owner under the pointer) and where the zones are.
    private var zoneOrder: [String] = []
    private var zoneHits: [(rect: CGRect, key: String)] = []
    /// The open side's pets ride a strip at most `maxFlat` pets wide, through a fisheye: each has a
    /// resting spot, spread evenly across the strip, and the pointer (`lens`) magnifies its
    /// neighbourhood to full size while the rest squeeze toward the strip's fixed ends. So the pet
    /// under the pointer is always the picked one, and a short move runs through many. `roll` is
    /// the (fractional) index under the lens, in on-screen left-to-right order.
    private var strip: (area: CGRect, hit: CGRect, keys: [String], step: CGFloat)?
    private var roll: CGFloat?
    private var lens: CGFloat?
    private var compactUsage = false
    private var petY: CGFloat = 0
    /// Shrinks an open side's pets to fit under its usage line; the tallest open pet's height.
    private var petFit: CGFloat = 1, petTall: CGFloat = 0
    private var ticker: DispatchSourceTimer?
    /// Session whose zone is hovered or picked with the keys, and the app to hand keys back to.
    private var focusKey: String?
    private var keyOwner: NSRunningApplication?
    private var tray: TrayView?
    private var trayKey = ""
    private var closeWork: DispatchWorkItem?
    private let store: SessionStore
    private let config: ConfigStore
    var menu: (() -> NSMenu)?

    private let pad: CGFloat = 12, gap: CGFloat = 10, stackStep: CGFloat = 11, maxStack = 4, maxZones = 16, maxFlat = 3
    private var bodyH: CGFloat { (notch.height * 0.56).rounded() }
    /// The window pokes a few points above the screen so the topmost pixel row, where a pointer
    /// pinned to the edge sits, is inside it rather than on its border.
    private let overscan: CGFloat = 4
    private var top: CGFloat { height - overscan }

    init(store: SessionStore, config: ConfigStore) {
        self.store = store
        self.config = config
        super.init()
        window.contentView = holder
        holder.addSubview(view)
        window.acceptsMouseMovedEvents = true
        view.controller = self
        view.wantsLayer = true
        host.layer = root
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        for s in [bar, panel, barMask] + Array(trays.values) + Array(trayMasks.values) { s.fillColor = NSColor.black.cgColor }
        root.addSublayer(panel)
        for s in trays.values { root.addSublayer(s) }
        root.addSublayer(bar)
        root.addSublayer(slotLayer)
        mask.addSublayer(barMask)
        for s in trayMasks.values { mask.addSublayer(s) }
        slotLayer.mask = mask
        layoutScreen()
        // On screen for good from here; hiding parks it off screen.
        window.orderFrontRegardless()
        watchMenuBar()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutScreen()
            self?.render(animated: false)
        }
    }

    // MARK: geometry

    private func layoutScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame
        let inset = screen.safeAreaInsets.top
        // The physical notch runs about a point below the safe area; cover it fully.
        let nh = inset > 0 ? inset + 1 : max(24, f.maxY - screen.visibleFrame.maxY)
        var nx = f.width / 2 - 90, nw: CGFloat = 180
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let origin = l.minX >= f.minX - 1 ? f.minX : 0
            nx = l.maxX - origin
            nw = r.minX - l.maxX
        }
        screenTop = f.maxY
        screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        screenX = f.minX
        screenW = f.width
        view.frame = NSRect(x: 0, y: 0, width: f.width, height: height)
        host.frame = view.bounds
        for l in [root, slotLayer, mask] { l.frame = view.bounds }
        for l in [root, bar, barMask, panel, slotLayer] + Array(trays.values) + Array(trayMasks.values) {
            l.contentsScale = screen.backingScaleFactor
        }
        notch = CGRect(x: nx, y: top - nh, width: nw, height: nh)
        fitWindow(tall: store.pending.first != nil)
        for s in slots.values { s.layer.removeFromSuperlayer() }
        slots.removeAll()
        collapse()
    }

    private func fitWindow(tall: Bool) {
        let h = tall ? height : notch.height + overscan + 10
        windowTall = tall
        window.setFrame(NSRect(x: screenX - (parked ? 100_000 : 0), y: screenTop + overscan - h, width: screenW, height: h), display: false)
        view.setFrameOrigin(NSPoint(x: 0, y: h - height))
    }


    private func shape(_ minX: CGFloat, _ maxX: CGFloat, _ bottom: CGFloat, _ R: CGFloat) -> CGPath {
        let ear: CGFloat = 6
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX - ear, y: top))
        p.addQuadCurve(to: CGPoint(x: minX, y: top - ear), control: CGPoint(x: minX, y: top))
        p.addLine(to: CGPoint(x: minX, y: bottom + R))
        p.addCurve(to: CGPoint(x: minX + R, y: bottom), control1: CGPoint(x: minX, y: bottom + R * 0.45), control2: CGPoint(x: minX + R * 0.45, y: bottom))
        p.addLine(to: CGPoint(x: maxX - R, y: bottom))
        p.addCurve(to: CGPoint(x: maxX, y: bottom + R), control1: CGPoint(x: maxX - R * 0.45, y: bottom), control2: CGPoint(x: maxX, y: bottom + R * 0.45))
        p.addLine(to: CGPoint(x: maxX, y: top - ear))
        p.addQuadCurve(to: CGPoint(x: maxX + ear, y: top), control: CGPoint(x: maxX, y: top))
        p.closeSubpath()
        return p
    }

    private var barRadius: CGFloat { min(12, notch.height / 2 - 2) }
    private var notchPath: CGPath { shape(notch.minX, notch.maxX, notch.minY, barRadius) }

    private func collapse() {
        for l in [bar, barMask, panel] + Array(trays.values) + Array(trayMasks.values) { set(l, notchPath, animated: false) }
    }

    // MARK: render

    func reload() {
        for s in slots.values { s.layer.removeFromSuperlayer() }
        slots.removeAll()
        trayKey = ""
        render(animated: false)
    }

    func render(animated: Bool = true) {
        var sides: [Side: [(AgentConfig, AgentSummary)]] = [.left: [], .right: []]
        for a in config.config.agents where a.placement != .hidden {
            if let s = store.summary(a.id) { sides[a.placement]!.append((a, s)) }
        }
        let pending = store.pending.first
        let show = !sides[.left]!.isEmpty || !sides[.right]!.isEmpty || pending != nil
        let done = Set(store.sessions.values.filter { [.done, .limited].contains(store.displayState($0)) }.map(\.key))
        if !done.subtracting(finished).isEmpty && !menuBarDown { flash() }
        finished = done
        hush(!menuBarDown && pending == nil && Date() >= flashUntil)
        if show && !visible {
            visible = true
            collapse()
            if !hushed { park(false) }
        }
        if openSide.map({ sides[$0]!.isEmpty }) ?? false { openSide = nil }

        // Collapsed wings: bodies sit in a row, popping out from under the notch.
        var targets: [String: (center: CGPoint, scale: CGFloat)] = [:]
        hits = [:]
        let cy = notch.midY
        var edges: [Side: CGFloat] = [:]
        for side in [Side.left, .right] {
            let dir: CGFloat = side == .left ? -1 : 1
            var x = side == .left ? notch.minX - pad : notch.maxX + pad
            for (a, sum) in sides[side]! {
                let sp = SpriteLibrary.sprite(for: a)
                let w = (bodyH * sp.weight * sp.bodyAspect).rounded()
                // Extra sessions tuck in behind the front mascot, a few points each.
                let gw = w + CGFloat(min(sum.count, maxStack) - 1) * stackStep
                let cx = x + dir * w / 2
                targets[a.id] = (CGPoint(x: cx, y: cy), 1)
                hits[a.id] = CGRect(x: min(x, x + dir * gw) - gap / 2, y: notch.minY, width: gw + gap, height: notch.height)
                x += dir * (gw + gap)
            }
            edges[side] = sides[side]!.isEmpty ? (side == .left ? notch.minX : notch.maxX) : x - dir * gap + dir * pad
        }
        let minX = edges[.left]!, maxX = edges[.right]!
        wings = [.left: CGRect(x: minX, y: notch.minY, width: notch.minX - minX, height: notch.height),
                 .right: CGRect(x: notch.maxX, y: notch.minY, width: maxX - notch.maxX, height: notch.height)]
        // Hover targets run into the notch and meet in its middle.
        hovers = [:]
        if minX < notch.minX { hovers[.left] = CGRect(x: minX, y: notch.minY, width: notch.midX - minX, height: notch.height) }
        if maxX > notch.maxX { hovers[.right] = CGRect(x: notch.midX, y: notch.minY, width: maxX - notch.midX, height: notch.height) }
        let barPath = shape(minX, maxX, notch.minY, barRadius)
        set(bar, barPath, animated: animated)
        set(barMask, barPath, animated: animated)

        // The hovered side widens into a tray at notch height; a question then drops below it.
        if let pending, let side = config.agent(pending.session.agent)?.placement, side != .hidden, !sides[side]!.isEmpty {
            openSide = side
        }
        trayRects = [:]
        zoneHits = []
        strip = nil
        var textRect: CGRect?, petsRect: CGRect?, focusRow: TrayView.Row?
        for side in [Side.left, .right] {
            let path: CGPath
            if side == openSide {
                // Every session gets a zone of its own, its pet fanned out from the stack into it,
                // and the text beyond tells the one under the pointer.
                let rows = zoneRows(sides[side]!)
                let dir: CGFloat = side == .left ? -1 : 1
                let x0 = side == .left ? notch.minX - pad + 4 : notch.maxX + pad - 4
                petTall = rows.map { bodyH * $0.sprite.weight }.max() ?? bodyH
                let step = (rows.map { (bodyH * $0.sprite.weight * $0.sprite.bodyAspect).rounded() }.max() ?? 24) + 1
                let pets = step * CGFloat(min(rows.count, maxFlat))
                // The usage line sits above the pets, a little past them at most; when the full line
                // won't fit it names only the window nearest its limit.
                let full = TrayView.usageWidth(rows.map(\.row), compact: false)
                compactUsage = full > pets + 12
                let span = max(pets, (compactUsage ? TrayView.usageWidth(rows.map(\.row), compact: true) : full) - 12)
                let hit = CGRect(x: min(x0, x0 + dir * span), y: notch.minY, width: span, height: notch.height)
                // Left to right on screen: on the left the first zone is the one nearest the notch.
                let keys = rows.map(\.row.session.key)
                strip = (hit.insetBy(dx: (span - pets) / 2, dy: 0), hit, side == .left ? keys.reversed() : keys, step)
                if roll == nil, let f = focusKey, let i = strip!.keys.firstIndex(of: f) { roll = CGFloat(i) }
                let area = hit
                let tw = TrayView.width(rows.map(\.row))
                let x = x0 + dir * (span + 8)
                petsRect = area
                let tr = CGRect(x: side == .left ? x - tw : x, y: notch.minY, width: tw, height: notch.height)
                let outer = side == .left ? min(tr.minX - 16, minX) : max(tr.maxX + 16, maxX)
                let r = side == .left ? CGRect(x: outer, y: notch.minY, width: notch.minX - outer, height: notch.height)
                                      : CGRect(x: notch.maxX, y: notch.minY, width: outer - notch.maxX, height: notch.height)
                trayRects[side] = r
                textRect = tr
                focusRow = rows.first { $0.row.session.key == focusKey }?.row
                path = side == .left ? shape(r.minX, notch.maxX, notch.minY, barRadius) : shape(notch.minX, r.maxX, notch.minY, barRadius)
            } else {
                path = side == .left ? shape(minX, notch.maxX, notch.minY, barRadius) : shape(notch.minX, maxX, notch.minY, barRadius)
            }
            set(trays[side]!, path, animated: animated)
            set(trayMasks[side]!, path, animated: animated)
        }
        updateTrayView(focusRow, text: textRect, pets: petsRect)
        // Under a usage line, the pets fit the band between it and the bottom edge, picked one included.
        if focusRow?.usage != nil {
            let band = notch.height - 13
            petY = notch.minY + 1 + band / 2
            petFit = min(1, band / (petTall * ((strip?.keys.count ?? 1) > 1 ? 1.08 : 1)))
        } else {
            petY = notch.midY
            petFit = 1
        }

        // Questions: the island morphs wider and taller in one spring (the asking side widens with
        // it), and the content fades up into place partway through.
        if let pending {
            var span = (min: notch.midX - 210, max: notch.midX + 210)
            if let side = openSide, let r = trayRects[side] {
                span = side == .left ? (r.minX, notch.maxX) : (notch.minX, r.maxX)
            }
            if bubble?.pending !== pending { presentBubble(pending, width: span.max - span.min) }
            let size = bubble!.preferredSize
            bubble!.frame = CGRect(x: span.min, y: notch.minY - size.height, width: size.width, height: size.height)
            set(panel, shape(span.min, span.max, notch.minY - size.height, 22), animated: animated)
        } else {
            dismissBubble()
            set(panel, notchPath, animated: animated)
        }
        let tall = pending != nil
        if tall, !windowTall {
            fitWindow(tall: true)
        } else if !tall, windowTall {
            shrinkToken += 1
            let token = shrinkToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, token == self.shrinkToken, self.store.pending.isEmpty else { return }
                self.fitWindow(tall: false)
            }
        }

        // One mascot per session: the most urgent in front, the rest stacked behind it; on an open
        // side each stands in its own zone, the hovered one lit.
        var live = Set<String>()
        for side in [Side.left, .right] {
            let dir: CGFloat = side == .left ? -1 : 1
            let open = side == openSide
            for (a, _) in sides[side]! {
                let t = targets[a.id]!
                let sprite = SpriteLibrary.sprite(for: a)
                let ss = store.sessions(of: a.id)
                for (k, s) in (open ? ss : Array(ss.prefix(maxStack))).enumerated() {
                    live.insert(s.key)
                    let slot: Slot
                    if let old = slots[s.key], !old.leaving {
                        slot = old
                        if slot.sprite !== sprite { slot.sprite = sprite; dress(slot); slot.anim = nil }
                    } else {
                        slots[s.key]?.layer.removeFromSuperlayer()
                        slot = Slot(id: s.key, sprite: sprite)
                        dress(slot)
                        slot.layer.position = behindNotch(sprite, left: side == .left)
                        slotLayer.addSublayer(slot.layer)
                        slots[s.key] = slot
                    }
                    if open {
                        let p = place(s.key)
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        slot.layer.zPosition = p?.z ?? 0
                        CATransaction.commit()
                        if let p {
                            fade(slot.layer, to: p.opacity, animated: animated)
                            move(slot.layer, to: p.pos, animated: animated)
                            scale(slot.layer, to: p.scale, animated: animated)
                        } else {
                            fade(slot.layer, to: 0, animated: animated)   // more sessions than zones
                        }
                        apply(slot, store.displayState(s), front: true)
                        continue
                    }
                    let back = CGFloat(k)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    slot.layer.zPosition = -back
                    CATransaction.commit()
                    fade(slot.layer, to: k == 0 ? 1 : Float(max(0.22, 0.55 - 0.15 * back)), animated: animated)
                    move(slot.layer, to: CGPoint(x: t.center.x + dir * back * stackStep * t.scale, y: t.center.y), animated: animated)
                    scale(slot.layer, to: t.scale * (k == 0 ? 1 : 0.8), animated: animated)
                    apply(slot, store.displayState(s), front: k == 0)
                }
            }
        }
        for (id, slot) in slots where !live.contains(id) && !slot.leaving {
            slot.leaving = true
            move(slot.layer, to: behindNotch(slot.sprite, left: slot.layer.position.x < notch.midX), animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let s = self.slots[id], s === slot, s.leaving else { return }
                s.layer.removeFromSuperlayer()
                self.slots.removeValue(forKey: id)
            }
        }
        trackPointer()

        hideToken += 1
        if !show && visible {
            let token = hideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, token == self.hideToken else { return }
                self.visible = false
                self.park(true)
            }
        }
    }

    private func behindNotch(_ s: Sprite, left: Bool) -> CGPoint {
        let w = bodyH * s.weight * s.bodyAspect
        return CGPoint(x: left ? notch.minX + w / 2 + 4 : notch.maxX - w / 2 - 4, y: notch.midY)
    }

    /// Sizes the layer so the resting body is `bodyH` tall, anchored on the body's centre.
    private func dress(_ slot: Slot) {
        let l = slot.layer, s = slot.sprite
        let h = bodyH * s.weight / s.body.height, w = h * s.aspect
        l.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        l.anchorPoint = CGPoint(x: s.body.midX, y: 1 - s.body.midY)
        l.contents = s.image
        l.contentsGravity = .resize
        l.contentsRect = s.rect(s.anims[.idle]?.first?.frame ?? 0)
        l.magnificationFilter = s.pixelated ? .nearest : .linear
        l.minificationFilter = s.pixelated ? .nearest : .trilinear
        l.contentsScale = window.backingScaleFactor
        slot.dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        slot.dot.cornerRadius = 2.5
        slot.dot.opacity = 0
        slot.dot.position = CGPoint(x: s.body.maxX * w + 3, y: (1 - s.body.maxY) * h + 1)
        if slot.dot.superlayer == nil { l.addSublayer(slot.dot) }
    }

    static func anim(_ state: AgentState) -> Anim {
        switch state {
        case .question: return .question
        case .working: return .working
        case .done: return .done
        case .idle: return .idle
        case .interrupted: return .interrupted
        case .limited: return .limited
        case .waiting: return .waiting
        }
    }

    private func apply(_ slot: Slot, _ state: AgentState, front: Bool) {
        let anim = Self.anim(state)
        if slot.anim != anim {
            slot.anim = anim
            play(slot)
        }
        slot.dot.isHidden = !front
        guard slot.dotState != state else { return }
        slot.dotState = state
        slot.dot.removeAllAnimations()
        switch state {
        case .question:
            slot.dot.backgroundColor = NSColor.systemOrange.cgColor
            slot.dot.opacity = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
            slot.dot.add(pulse, forKey: "pulse")
        case .waiting:
            // A slow breath: alive, but nothing for you yet.
            slot.dot.backgroundColor = NSColor.systemTeal.cgColor
            slot.dot.opacity = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.9
            pulse.toValue = 0.3
            pulse.duration = 1.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 8)
            slot.dot.add(pulse, forKey: "pulse")
        case .done, .interrupted, .limited:
            slot.dot.backgroundColor = Self.color(state, tint: .white).cgColor
            slot.dot.opacity = 1
        default:
            slot.dot.opacity = 0
        }
    }

    static func color(_ s: AgentState, tint: NSColor) -> NSColor {
        switch s {
        case .question: return .systemOrange
        case .working: return tint
        case .done: return .systemGreen
        case .idle: return NSColor(white: 1, alpha: 0.28)
        case .interrupted: return NSColor(white: 1, alpha: 0.7)
        case .limited: return .systemRed
        case .waiting: return .systemTeal
        }
    }

    private func play(_ slot: Slot) {
        guard let anim = slot.anim else {
            slot.layer.removeAnimation(forKey: "frames")
            slot.layer.removeAnimation(forKey: "once")
            return
        }
        Self.play(anim, on: slot.layer, sprite: slot.sprite)
    }

    static func play(_ anim: Anim, on l: CALayer, sprite s: Sprite) {
        l.removeAnimation(forKey: "frames")
        l.removeAnimation(forKey: "once")
        // Idle fidgets a few times, then holds still on its first frame: resting mascots cost nothing.
        switch anim {
        case .done:
            l.add(track(s, .idle, repeats: 3), forKey: "frames")
            l.add(track(s, .done, repeats: 2), forKey: "once")
        case .idle:
            l.add(track(s, .idle, repeats: 2), forKey: "frames")
        case .interrupted, .limited:
            // Once through, then hold the last pose until the next turn.
            let k = track(s, anim, repeats: 1)
            k.fillMode = .forwards
            k.isRemovedOnCompletion = false
            l.add(k, forKey: "once")
        default:
            l.add(track(s, anim, repeats: .infinity), forKey: "frames")
        }
    }

    private static func track(_ s: Sprite, _ a: Anim, repeats: Float) -> CAKeyframeAnimation {
        let frames = s.anims[a] ?? s.anims[.idle] ?? [(0, 1000)]
        let total = frames.reduce(0) { $0 + $1.ms }
        let k = CAKeyframeAnimation(keyPath: "contentsRect")
        k.values = frames.map { NSValue(rect: s.rect($0.frame)) }
        var t = 0.0, times: [NSNumber] = []
        for f in frames { times.append(NSNumber(value: t / total)); t += f.ms }
        times.append(1)
        k.keyTimes = times
        k.calculationMode = .discrete
        k.duration = total / 1000 * s.tempo
        k.repeatCount = repeats
        k.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 12, preferred: 10)  // frames hold ≥110ms
        return k
    }

    // MARK: tray

    /// Every session on the side, nearest agent first, in the order they had when the side opened
    /// (newcomers join at the end). Focus starts on the most urgent.
    private func zoneRows(_ agents: [(AgentConfig, AgentSummary)]) -> [(row: TrayView.Row, sprite: Sprite)] {
        var all: [String: (row: TrayView.Row, sprite: Sprite)] = [:], natural: [String] = []
        for (a, _) in agents {
            let sprite = SpriteLibrary.sprite(for: a), usage = Usage.read(a.id)
            for s in store.sessions(of: a.id) {
                natural.append(s.key)
                all[s.key] = (TrayView.Row(agent: a, session: s, state: store.displayState(s), usage: usage, jobs: store.jobs(s)), sprite)
            }
        }
        zoneOrder = zoneOrder.filter { all[$0] != nil } + natural.filter { !zoneOrder.contains($0) }
        let rows = zoneOrder.prefix(maxZones).compactMap { all[$0] }
        if focusKey.map({ k in !rows.contains { $0.row.session.key == k } }) ?? true {
            focusKey = rows.max { $0.row.state < $1.row.state }?.row.session.key
        }
        return rows
    }

    private func updateTrayView(_ row: TrayView.Row?, text tr: CGRect?, pets pr: CGRect?) {
        guard let side = openSide, let row, let tr, let pr else {
            trayKey = ""
            ticker?.cancel()
            ticker = nil
            releaseKeys()
            if let t = tray {
                tray = nil
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; t.animator().alphaValue = 0 }, completionHandler: { t.removeFromSuperview() })
            }
            return
        }
        // Rebuild only when something visible changed; the clock refreshes it in place.
        let s = row.session
        let r = tr.union(pr)
        let key = "\(side)|\(r)|\(compactUsage)|\(s.key)|\(row.state)|\(s.task)|\(s.action ?? "")|\(s.reason ?? "")|\(row.jobs)|"
            + (row.usage.map { $0.windows.map { "\($0.label)\(Int($0.used.rounded()))" }.joined() } ?? "")
        guard key != trayKey else { return }
        let fresh = tray == nil || !trayKey.hasPrefix("\(side)|")
        trayKey = key
        tray?.removeFromSuperview()
        let t = TrayView(frame: r, text: tr.offsetBy(dx: -r.minX, dy: 0), pets: pr.offsetBy(dx: -r.minX, dy: 0), left: side == .left,
                         row: row, compactUsage: compactUsage)
        view.addSubview(t)
        tray = t
        if fresh {
            t.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.22; t.animator().alphaValue = 1 }
            }
        }
        if ticker == nil {
            let tk = DispatchSource.makeTimerSource(queue: .main)
            tk.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            tk.setEventHandler { [weak self] in self?.tray?.refresh() }
            tk.resume()
            ticker = tk
        }
    }

    private func focus(_ key: String) {
        guard focusKey != key else { return }
        focusKey = key
        if let st = strip, let i = st.keys.firstIndex(of: key) { roll = CGFloat(i); lens = nil }
        render()
    }

    /// The span the picked pet's centre travels: first pet's resting spot to the last one's.
    private func track(_ st: (area: CGRect, hit: CGRect, keys: [String], step: CGFloat)) -> (lo: CGFloat, hi: CGFloat) {
        (st.area.minX + st.step / 2, st.area.maxX - st.step / 2)
    }

    /// Where an open side's pet stands under the fisheye, how large (the picked one largest) and
    /// how faint, and how far back.
    private func place(_ key: String) -> (pos: CGPoint, scale: CGFloat, opacity: Float, z: CGFloat)? {
        guard let st = strip, let i = st.keys.firstIndex(of: key) else { return nil }
        let n = st.keys.count
        guard n > 1 else { return (CGPoint(x: st.area.midX, y: petY), petFit, 1, 0) }
        let (lo, hi) = track(st)
        let gap = (hi - lo) / CGFloat(n - 1)           // between resting spots
        let p = min(hi, max(lo, lens ?? lo + (roll ?? 0) * gap))
        let r = (p - lo) / gap
        // Sarkar–Brown fisheye, magnified so the pets either side of the lens have room to
        // breathe; the strip's ends stay put. Three or fewer need none.
        let home = lo + CGFloat(i) * gap, k = n <= maxFlat ? 0 : max(0, 1.3 * st.step / gap - 1)
        var x = home
        if k > 0, home != p {
            let edge = home < p ? lo : hi, span = abs(edge - p)
            let d = span > 0 ? abs(home - p) / span : 0
            x = p + (home < p ? -1 : 1) * span * (k + 1) * d / (k * d + 1)
        }
        let dd = CGFloat(i) - r, a = abs(dd)
        let scale = 0.62 + 0.46 * exp(-dd * dd / 0.7)
        let opacity = Float(n <= maxFlat ? max(0.3, min(1, 1.1 - 0.6 * a)) : max(0, min(1, 1.1 - 0.55 * a)))
        return (CGPoint(x: x, y: petY), scale * petFit, opacity, -a)
    }

    /// Moves the lens with the pointer, in soft detents: each pet holds for the middle of its
    /// stretch, then the next snaps in with a little overshoot. Picking a new one updates the text.
    private func scroll(to px: CGFloat) {
        guard let st = strip, st.keys.count > 1 else { return }
        let (lo, hi) = track(st)
        let gap = (hi - lo) / CGFloat(st.keys.count - 1)
        let raw = (min(hi, max(lo, px)) - lo) / gap, i = raw.rounded(.down)
        let t = min(1, max(0, (raw - i - 0.3) / 0.4))
        let r = i + t * t * (3 - 2 * t)
        guard r != roll || lens == nil else { return }
        roll = r
        lens = lo + r * gap
        for k in st.keys {
            guard let slot = slots[k], let p = place(k) else { continue }
            for a in ["position", "transform.scale", "opacity"] { slot.layer.removeAnimation(forKey: a) }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 1.45, 0.55, 1))
            slot.layer.position = p.pos
            slot.layer.setValue(p.scale, forKeyPath: "transform.scale")
            slot.layer.opacity = p.opacity
            slot.layer.zPosition = p.z
            CATransaction.commit()
        }
        let pick = st.keys[Int(roll!.rounded())]
        if pick != focusKey {
            focusKey = pick
            render()
        }
    }

    private func refreshTitles() {
        Focus.titles { [weak self] titles in
            guard let self, !titles.isEmpty else { return }
            for s in self.store.sessions.values where s.inGhostty && s.parent == nil {
                if s.terminalID == nil {
                    // Not seen being typed into yet: adopt the only terminal sitting in its directory.
                    let here = titles.filter { Focus.same($0.cwd, s.cwd) }
                    if here.count == 1 { s.terminalID = here[0].id }
                }
                if let id = s.terminalID, let t = titles.first(where: { $0.id == id }) { s.title = t.name }
            }
            if self.openSide != nil { self.render() }
        }
    }

    // MARK: animation helpers

    private func spring(_ l: CALayer, _ key: String, from: Any, to: Any) {
        let a = CASpringAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.mass = 1
        a.stiffness = 240
        a.damping = 22
        a.duration = a.settlingDuration
        l.add(a, forKey: key)
    }

    private func set(_ l: CAShapeLayer, _ p: CGPath, animated: Bool) {
        let from = l.presentation()?.path ?? l.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.path = p
        CATransaction.commit()
        if animated, let from, from != p { spring(l, "path", from: from, to: p) } else if !animated { l.removeAnimation(forKey: "path") }
    }

    private func move(_ l: CALayer, to pos: CGPoint, animated: Bool) {
        let from = l.presentation()?.position ?? l.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.position = pos
        CATransaction.commit()
        if animated && from != pos { spring(l, "position", from: NSValue(point: from), to: NSValue(point: pos)) }
    }

    private func fade(_ l: CALayer, to o: Float, animated: Bool) {
        let from = l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.opacity = o
        CATransaction.commit()
        guard animated, abs(from - o) > 0.01 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = o
        a.duration = 0.25
        l.add(a, forKey: "opacity")
    }

    private func scale(_ l: CALayer, to s: CGFloat, animated: Bool) {
        let from = (l.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (l.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.setValue(s, forKeyPath: "transform.scale")
        CATransaction.commit()
        if animated && abs(from - s) > 0.001 { spring(l, "transform.scale", from: from, to: s) }
    }

    // MARK: bubble

    private func presentBubble(_ p: Pending, width: CGFloat) {
        bubble?.removeFromSuperview()
        let agent = config.agent(p.session.agent) ?? AgentConfig(id: p.session.agent)
        let b = BubbleView(pending: p, agent: agent, sprite: SpriteLibrary.sprite(for: agent), width: max(360, width))
        b.onAnswer = { [weak self] out in self?.store.answer(p, output: out) }
        b.onChat = { [weak self] in self?.openChat(p.session) }
        b.onResize = { [weak self] in self?.render() }
        b.alphaValue = 0
        b.wantsLayer = true
        view.addSubview(b)
        bubble = b
        // Content rises out of the growing shape: fade in with a slight lift once it has room.
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = CATransform3DMakeTranslation(0, 6, 0)
        lift.toValue = CATransform3DIdentity
        lift.duration = 0.32
        lift.beginTime = CACurrentMediaTime() + 0.17
        lift.fillMode = .backwards
        lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        b.layer?.add(lift, forKey: "lift")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.24
                $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
                b.animator().alphaValue = 1
            }
        }
    }

    private func dismissBubble() {
        guard let b = bubble else { return }
        bubble = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; b.animator().alphaValue = 0 }, completionHandler: { b.removeFromSuperview() })
    }

    // MARK: input

    /// Pointer in island coordinates; anything above the screen's top counts as its top row.
    private var pointer: CGPoint {
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return CGPoint(x: p.x, y: min(p.y, top - 0.5))
    }

    private func trackPointer() {
        for a in view.trackingAreas { view.removeTrackingArea(a) }
        let p = pointer
        var rects = trayRects.map { $0.value.union(hovers[$0.key] ?? $0.value) }
        for (side, r) in hovers where trayRects[side] == nil { rects.append(r) }
        // One area over the whole island that also reports movement inside it, so the open side
        // always follows the pointer, however fast it crosses the notch. Silent once outside.
        if var all = rects.first.map({ rects.dropFirst().reduce($0) { $0.union($1) } }) {
            all.size.height = height - all.minY   // up through the overscan, to the window's top
            var opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways]
            if all.contains(p) { opts.insert(.assumeInside) }
            view.addTrackingArea(NSTrackingArea(rect: all, options: opts, owner: view, userInfo: nil))
        }
        // Areas rebuilt under a resting pointer never report "entered"; check by hand.
        if side(at: p) != openSide { DispatchQueue.main.async { [weak self] in self?.pointerMoved() } }
    }

    private func side(at p: CGPoint) -> Side? {
        if let s = openSide, let r = trayRects[s], r.union(hovers[s] ?? r).contains(p) { return s }
        return hovers.first { $0.value.contains(p) }?.key
    }

    func pointerMoved() {
        let s = side(at: pointer)
        if store.pending.first != nil { return }
        if let s {
            closeWork?.cancel()
            if s != openSide {
                openSide = s
                takeKeys()
                refreshTitles()
                // Looking counts as reading: finished sessions on this side go quiet.
                for a in config.config.agents where a.placement == s { store.markSeen(a.id) }
                render()
            } else if let st = strip, st.hit.contains(pointer) {
                scroll(to: pointer.x)
            } else if let hit = zoneHits.first(where: { $0.rect.contains(pointer) }) {
                focus(hit.key)
            }
        } else if openSide != nil {
            closeWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.side(at: self.pointer) == nil else { return }
                self.openSide = nil
                self.render()
            }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    // MARK: menu bar

    /// Follows the menu bar on the island's screen. Where macOS auto-hides it (by default in
    /// full-screen spaces), the island hides too and comes back when the pointer reaches the top
    /// edge, staying while it's within the bar or the island. The window list can't tell a hidden
    /// menu bar from a shown one, so this mirrors the rule rather than watching the bar.
    private func watchMenuBar() {
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.updateAutoHide()
                // The space's type can settle after the switch animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.updateAutoHide() }
            }
        }
        updateAutoHide()
    }

    private func updateAutoHide() {
        let hides = Spaces.isFullScreen(screenID) ? Spaces.menuBarHidesInFullScreen : Spaces.menuBarHidesOnDesktop
        if hides, barTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(30))
            t.setEventHandler { [weak self] in self?.checkMenuBar() }
            t.resume()
            barTimer = t
            menuBarDown = false
            render()
        } else if !hides, let t = barTimer {
            t.cancel()
            barTimer = nil
            menuBarDown = true
            render()
        }
    }

    private func checkMenuBar() {
        let m = NSEvent.mouseLocation
        let across = m.x >= screenX && m.x <= screenX + screenW
        let p = view.convert(window.convertPoint(fromScreen: m), from: nil)
        let down: Bool
        if across && m.y >= screenTop - 1 { down = true }
        else if menuBarDown && across && (m.y >= screenTop - notch.height - 4 || (!hushed && side(at: p) != nil)) { down = true }
        else { down = false }
        if down { revealUntil = Date() + 0.4 }
        let next = down || Date() < revealUntil
        guard next != menuBarDown else { return }
        menuBarDown = next
        render()
    }

    /// Something just finished while the island is hidden: pop in, then go again.
    private func flash() {
        flashUntil = Date() + 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.render() }
    }

    private func hush(_ on: Bool) {
        guard on != hushed else { return }
        hushed = on
        if on { openSide = nil }
        // Fade, then take the window off screen.
        if !on && visible { park(false) }
        NSAnimationContext.runAnimationGroup({ $0.duration = on ? 0.25 : 0.18; window.animator().alphaValue = on ? 0 : 1 }) { [weak self] in
            guard let self, self.hushed else { return }
            self.park(true)
        }
    }

    private func park(_ on: Bool) {
        guard on != parked else { return }
        parked = on
        fitWindow(tall: windowTall)
    }

    // MARK: keyboard

    /// While a tray is open the island takes the keyboard (without activating the app),
    /// so ←/→ walk its zones, Return opens the one picked, Esc closes.
    private func takeKeys() {
        guard !window.isKeyWindow else { return }
        keyOwner = NSWorkspace.shared.frontmostApplication
        window.makeKey()
        window.makeFirstResponder(view)
    }

    private func releaseKeys() {
        guard window.isKeyWindow, bubble == nil else { return }
        window.resignKey()
        keyOwner?.activate()
        keyOwner = nil
    }

    func key(_ e: NSEvent) -> Bool {
        guard openSide != nil else { return false }
        let order = strip?.keys ?? []
        switch e.keyCode {
        case 123, 124: // ← →
            guard !order.isEmpty else { return true }
            let step = e.keyCode == 124 ? 1 : -1
            let next = focusKey.flatMap { order.firstIndex(of: $0) }.map { ($0 + step + order.count) % order.count } ?? 0
            focus(order[next])
        case 36, 76: // Return
            if let k = focusKey ?? order.first, let s = store.sessions[k] { openChat(s) }
        case 53: // Esc
            openSide = nil
            render()
        default:
            return false
        }
        return true
    }

    func click(_ raw: CGPoint) {
        let p = CGPoint(x: raw.x, y: min(raw.y, top - 0.5))
        if let hit = zoneHits.first(where: { $0.rect.contains(p) }), let s = store.sessions[hit.key] { return openChat(s) }
        // The text tells the focused session; a click there opens it.
        if let side = openSide, side == self.side(at: p), let k = focusKey, let s = store.sessions[k] { return openChat(s) }
        // Anywhere else that hovers a side (padding, gaps, its half of the notch) clicks through to
        // that side's agent: the one picked with the arrows, else the one nearest the notch.
        var id = hits.first(where: { $0.value.contains(p) })?.key
        if id == nil, let side = side(at: p) {
            let mine = config.config.agents.filter { $0.placement == side && store.summary($0.id) != nil }.map(\.id)
            id = mine.first
        }
        guard let id else { return }
        if let s = store.sessions(of: id).first { openChat(s) }
    }

    func openChat(_ s: Session) {
        for p in store.pending where p.session === s { store.release(p) }
        store.markSeen(s.agent)
        Focus.open(s, agent: config.agent(s.agent))
    }

    // MARK: demo driver

    /// Where an agent's front mascot is, in view coordinates.
    func mascot(_ agent: String) -> CGPoint? {
        store.sessions(of: agent).lazy.compactMap { self.slots[$0.key]?.layer.position }.first
    }

    /// Centre of the question panel's button labelled `title`.
    func button(_ title: String) -> CGPoint? {
        func find(_ v: NSView) -> NSView? {
            if let b = v as? HoverButton, Self.labels(b).contains(title) { return b }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let b = bubble.flatMap(find) else { return nil }
        let r = view.convert(b.bounds, from: b)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// For the demo driver: `mascot:<agent>`, `button:<label>` or `zone:<agent>:<n>` as a screen point (top-left origin,
    /// as CGEvent wants), or `state` for sessions and pending questions. JSON either way.
    func locate(_ what: String) -> String {
        func json(_ o: Any) -> String { (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
        if what == "state" {
            let ss = store.sessions.values.map { ["key": $0.key, "agent": $0.agent, "state": "\(store.displayState($0))"] }
            return json(["sessions": ss, "pending": store.pending.count, "open": openSide.map { "\($0)" } ?? "", "hushed": hushed])
        }
        let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "{}" }
        var p: CGPoint?
        switch parts[0] {
        case "mascot": p = mascot(parts[1])
        case "button": p = button(parts[1])
        case "pip", "zone":   // zone:<agent>:<n>, the agent's n-th session zone in the open tray
            let q = parts[1].split(separator: ":").map(String.init)
            let mine = zoneHits.filter { store.sessions[$0.key]?.agent == q.first }
            if q.count == 2, let n = Int(q[1]), n < mine.count { p = CGPoint(x: mine[n].rect.midX, y: mine[n].rect.midY) }
        default: break
        }
        guard let p else { return "{}" }
        let s = window.convertPoint(toScreen: view.convert(p, to: nil))
        let h = NSScreen.screens.first?.frame.height ?? 0
        return json(["x": s.x, "y": h - s.y])
    }

    private static func labels(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels)
    }

    func showMenu(_ e: NSEvent, in v: NSView) {
        guard let m = menu?() else { return }
        NSMenu.popUpContextMenu(m, with: e, for: v)
    }
}
