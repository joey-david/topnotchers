import AppKit
import ImageIO

enum Anim { case idle, working, question, done, interrupted, limited, waiting }

/// All of a sprite's frames side by side in one small strip, so an animation is
/// just a discrete `contentsRect` keyframe track the render server plays itself.
final class Sprite {
    let image: CGImage
    let frameCount: Int
    let pixelated: Bool
    let anims: [Anim: [(frame: Int, ms: Double)]]
    /// Playback slowdown applied to every frame duration.
    let tempo: Double
    /// Opaque bounds of the resting pose in unit frame coordinates (y from the top),
    /// so every mascot can be sized and centred by its body rather than its canvas.
    private(set) var body = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(image: CGImage, frameCount: Int, pixelated: Bool, tempo: Double = 1, anims: [Anim: [(frame: Int, ms: Double)]]) {
        self.image = image; self.frameCount = frameCount; self.pixelated = pixelated; self.tempo = tempo; self.anims = anims
        body = measure(anims[.idle]?.first?.frame ?? 0)
    }

    var aspect: CGFloat { CGFloat(image.width) / CGFloat(frameCount) / CGFloat(image.height) }
    /// Relative display size, so a round pet and a boxy crab read as the same size.
    var weight: CGFloat { pixelated ? 0.84 : 1.15 }
    /// Width over height of the body, in points.
    var bodyAspect: CGFloat { body.width * aspect / body.height }

    private func measure(_ frame: Int) -> CGRect {
        guard let still = still(frame) else { return body }
        let w = still.width, h = still.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return body }
        ctx.draw(still, in: CGRect(x: 0, y: 0, width: w, height: h))
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 40 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= x0, y1 >= y0 else { return body }
        return CGRect(x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h),
                      width: CGFloat(x1 - x0 + 1) / CGFloat(w), height: CGFloat(y1 - y0 + 1) / CGFloat(h))
    }

    func rect(_ i: Int) -> CGRect {
        CGRect(x: CGFloat(i) / CGFloat(frameCount), y: 0, width: 1 / CGFloat(frameCount), height: 1)
    }

    func still(_ i: Int = 0) -> CGImage? {
        let w = image.width / frameCount
        return image.cropping(to: CGRect(x: i * w, y: 0, width: w, height: image.height))
    }
}

enum SpriteLibrary {
    private static var cache: [String: Sprite] = [:]
    static let dir = islandHome.appendingPathComponent("sprites")

    static func reset() { cache.removeAll() }

    static func sprite(for a: AgentConfig) -> Sprite {
        let name = a.sprite ?? ""
        let key = name + "|" + (a.color ?? "")
        if let s = cache[key] { return s }
        let s: Sprite
        if name == "clawd" || name.isEmpty {
            s = PixelPet.make(color: name == "clawd" ? (NSColor(hex: a.color) ?? NSColor(hex: "#D77757")!) : a.tint)
        } else {
            s = url(for: name).flatMap(PetAtlas.load) ?? PixelPet.make(color: a.tint)
        }
        cache[key] = s
        return s
    }

    static func url(for name: String) -> URL? {
        let fm = FileManager.default
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        }
        for ext in ["webp", "png"] {
            let u = dir.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let pet = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/pets/\(name)")
        if let data = try? Data(contentsOf: pet.appendingPathComponent("pet.json")),
           let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return pet.appendingPathComponent(j["spritesheetPath"] as? String ?? "spritesheet.webp")
        }
        return nil
    }

    static func available() -> [String] {
        let fm = FileManager.default
        var names = ["clawd"]
        names += ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".webp") || $0.hasSuffix(".png") }
            .map { ($0 as NSString).deletingPathExtension }.sorted()
        let pets = NSHomeDirectory() + "/.codex/pets"
        names += ((try? fm.contentsOfDirectory(atPath: pets)) ?? [])
            .filter { fm.fileExists(atPath: "\(pets)/\($0)/pet.json") }.sorted()
        return names
    }
}

/// Codex v2 pet atlases: 8×11 cells of 192×208, rows per state.
enum PetAtlas {
    private static let rows: [(row: Int, ms: [Double])] = [
        (0, [1200, 110, 110, 140, 140, 700]),        // idle, resting longer between fidgets
        (4, [140, 140, 140, 140, 280]),               // jumping
        (5, [90, 90, 120, 120, 90, 90, 120, 160]),    // failed: a flustered shake
        (6, [150, 150, 150, 150, 150, 260]),          // waiting (on you, or on a job)
        (7, [120, 120, 120, 120, 120, 220]),          // running
        (9, [260, 160, 160, 160, 200, 260, 320, 1]),  // flopping over, out of steam
    ]
    private static let map: [Anim: Int] = [.idle: 0, .done: 4, .interrupted: 5, .question: 6, .working: 7, .limited: 9, .waiting: 6]
    static let height = 96

    /// Prepared strips are cached as small PNGs, so later launches skip decoding the full atlas.
    private static func cacheURL(_ url: URL) -> URL {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let name = url.deletingPathExtension().lastPathComponent + "-\(Int(mtime))-h\(height)-v2.png"
        return islandHome.appendingPathComponent("cache").appendingPathComponent(name)
    }

    private static func sprite(_ strip: CGImage) -> Sprite {
        var anims: [Anim: [(frame: Int, ms: Double)]] = [:]
        var i = 0
        for (row, ms) in rows {
            let seq = ms.enumerated().map { (frame: i + $0.offset, ms: $0.element) }
            i += ms.count
            for (anim, r) in map where r == row { anims[anim] = seq }
        }
        // Interrupted: shake it off, then settle with eyes closed (idle's blink frame).
        anims[.interrupted]?.append((frame: 1, ms: 1))
        return Sprite(image: strip, frameCount: i, pixelated: false, tempo: 2.2, anims: anims)
    }

    static func load(_ url: URL) -> Sprite? {
        let cached = cacheURL(url)
        if let src = CGImageSourceCreateWithURL(cached as CFURL, nil), let strip = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return sprite(strip)
        }
        guard let strip = prepare(url) else { return nil }
        try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(cached as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, strip, nil)
            CGImageDestinationFinalize(dest)
        }
        return sprite(strip)
    }

    private static func prepare(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let W = img.width, H = img.height
        let cw = W / 8, ch = cw * 208 / 192
        guard cw > 0, H >= ch * 8 else { return nil }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

        // One crop box shared by every frame, so the pet doesn't jitter.
        var minX = cw, minY = ch, maxX = 0, maxY = 0
        for (row, ms) in rows {
            for col in 0..<ms.count {
                for y in 0..<ch {
                    let line = base + ((row * ch + y) * W + col * cw) * 4
                    for x in 0..<cw where line[x * 4 + 3] > 24 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        minX = max(0, minX - 2); minY = max(0, minY - 2); maxX = min(cw - 1, maxX + 2); maxY = min(ch - 1, maxY + 2)
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let fh = height, fw = Int((CGFloat(bw) * CGFloat(fh) / CGFloat(bh)).rounded())
        let total = rows.reduce(0) { $0 + $1.ms.count }
        guard let full = ctx.makeImage(),
              let out = CGContext(data: nil, width: fw * total, height: fh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.interpolationQuality = .high
        var anims: [Anim: [(frame: Int, ms: Double)]] = [:]
        var i = 0
        for (row, ms) in rows {
            var seq: [(frame: Int, ms: Double)] = []
            for col in 0..<ms.count {
                if let cell = full.cropping(to: CGRect(x: col * cw + minX, y: row * ch + minY, width: bw, height: bh)) {
                    out.draw(cell, in: CGRect(x: i * fw, y: 0, width: fw, height: fh))
                }
                seq.append((i, ms[col]))
                i += 1
            }
            for (anim, r) in map where r == row { anims[anim] = seq }
        }
        return out.makeImage()
    }
}

/// Clawd, Claude Code's mascot, from the welcome-screen block art
/// (" ▐▛███▜▌ " / "▝▜█████▛▘" / "  ▘▘ ▝▝ "), at one pixel per quadrant, posed.
enum PixelPet {
    struct Pose {
        enum Eyes { case open, shut, up, left, right }
        var dy = 0
        var eyes = Eyes.open
        var leftUp = false, rightUp = false
        var legs = 0          // 0 planted, 1 stepping, -1 tucked
        var crouch = false
        var slump = false     // melted flat, arms out
    }

    private static let W = 20, H = 9, sx = 4, sy = 8

    private static func pixels(_ p: Pose) -> Set<[Int]> {
        var px = Set<[Int]>()
        if p.slump {
            for r in 5...7 { for c in 3...14 { px.insert([c, r]) } }
            for c in [1, 2, 15, 16] { px.insert([c, 7]) }
            px.remove([5, 6]); px.remove([12, 6])
            return px
        }
        let top = 3 + p.dy + (p.crouch ? 1 : 0)
        let torso = p.crouch ? 3 : 4
        for r in 0..<torso { for c in 3...14 { px.insert([c, top + r]) } }
        let eyeRow = p.eyes == .up ? top : top + 1
        let eyeCols: [Int]
        switch p.eyes {
        case .open, .up: eyeCols = [5, 12]
        case .left: eyeCols = [4, 11]
        case .right: eyeCols = [6, 13]
        case .shut: eyeCols = []
        }
        for c in eyeCols { px.remove([c, eyeRow]) }
        let armRow = top + 2 - (p.crouch ? 1 : 0)
        if p.leftUp { px.insert([2, armRow - 1]); px.insert([1, armRow - 2]) } else { px.insert([1, armRow]); px.insert([2, armRow]) }
        if p.rightUp { px.insert([15, armRow - 1]); px.insert([16, armRow - 2]) } else { px.insert([15, armRow]); px.insert([16, armRow]) }
        if p.legs >= 0 && !p.crouch {
            for c in (p.legs == 0 ? [4, 6, 11, 13] : [3, 5, 12, 14]) { px.insert([c, top + torso]) }
        }
        return px
    }

    static func make(color: NSColor) -> Sprite {
        typealias F = (Pose, Double)
        func P(_ f: (inout Pose) -> Void) -> Pose { var p = Pose(); f(&p); return p }
        let idle: [F] = [(Pose(), 2600), (P { $0.eyes = .shut }, 140), (Pose(), 1400), (P { $0.eyes = .right }, 1100),
                         (Pose(), 800), (P { $0.eyes = .shut }, 140)]
        var working: [F] = []
        for i in 0..<8 {
            working.append((P { $0.legs = i % 2; $0.dy = i % 2 == 0 ? 0 : -1; $0.eyes = i < 4 ? .right : .left }, 190))
        }
        let question: [F] = [(P { $0.leftUp = true; $0.eyes = .up }, 360), (P { $0.eyes = .up }, 320),
                             (P { $0.rightUp = true; $0.eyes = .up }, 360), (P { $0.eyes = .up }, 320),
                             (P { $0.leftUp = true; $0.eyes = .up }, 360), (P { $0.eyes = .up }, 1100)]
        let done: [F] = [(P { $0.crouch = true; $0.eyes = .shut }, 180),
                         (P { $0.dy = -2; $0.legs = -1; $0.leftUp = true; $0.rightUp = true; $0.eyes = .shut }, 130),
                         (P { $0.dy = -3; $0.legs = -1; $0.leftUp = true; $0.rightUp = true; $0.eyes = .shut }, 240),
                         (P { $0.dy = -2; $0.legs = -1; $0.leftUp = true; $0.rightUp = true; $0.eyes = .shut }, 130),
                         (P { $0.crouch = true }, 160), (Pose(), 400)]
        // Played once; the last pose holds.
        let interrupted: [F] = [(P { $0.crouch = true; $0.eyes = .shut }, 110),
                                (P { $0.dy = -1; $0.leftUp = true; $0.rightUp = true; $0.eyes = .up }, 420),
                                (P { $0.leftUp = true; $0.rightUp = true; $0.eyes = .shut }, 120),
                                (P { $0.leftUp = true; $0.rightUp = true; $0.eyes = .up }, 360),
                                (P { $0.eyes = .shut }, 1)]
        let limited: [F] = [(P { $0.eyes = .left }, 380), (P { $0.eyes = .right }, 380), (P { $0.eyes = .shut }, 300),
                            (P { $0.crouch = true; $0.eyes = .shut }, 420), (P { $0.slump = true }, 1)]
        // Sitting it out, glancing up and around now and then: a job is running elsewhere.
        let waiting: [F] = [(P { $0.crouch = true }, 1800), (P { $0.crouch = true; $0.eyes = .up }, 900),
                            (P { $0.crouch = true; $0.eyes = .shut }, 140), (P { $0.crouch = true }, 1400),
                            (P { $0.crouch = true; $0.eyes = .right }, 700), (P { $0.crouch = true; $0.eyes = .left }, 700)]
        let all: [(Anim, [F])] = [(.idle, idle), (.working, working), (.question, question), (.done, done),
                                  (.interrupted, interrupted), (.limited, limited), (.waiting, waiting)]
        let total = all.reduce(0) { $0 + $1.1.count }
        let fw = W * sx, fh = H * sy
        let ctx = CGContext(data: nil, width: fw * total, height: fh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.cgColor)
        var anims: [Anim: [(frame: Int, ms: Double)]] = [:]
        var i = 0
        for (anim, frames) in all {
            var seq: [(frame: Int, ms: Double)] = []
            for (pose, ms) in frames {
                for p in pixels(pose) {
                    ctx.fill(CGRect(x: i * fw + (p[0] + 1) * sx, y: (H - 1 - p[1]) * sy, width: sx, height: sy))
                }
                seq.append((i, ms))
                i += 1
            }
            anims[anim] = seq
        }
        return Sprite(image: ctx.makeImage()!, frameCount: total, pixelated: true, anims: anims)
    }
}
