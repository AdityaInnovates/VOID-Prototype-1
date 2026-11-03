import SwiftUI

/// VOID's face: clean glowing rings, not a globe.
///
/// - Idle: one bright ring and a faint one inside it, breathing slowly.
/// - Listening: the ring turns into a soft wave that follows your voice.
/// - Thinking: rings appear inside and spin like a gyroscope. The harder VOID thinks,
///   the more rings appear, and waves pulse outward.
/// - Speaking: the ring waves with VOID's real voice, and loud moments send ripples out.
struct OrbView: View {
    let state: AppState
    let signal: OrbSignal

    @State private var driver = OrbDriver()

    var body: some View {
        let phase = state.phase
        let depth = state.thinkingDepth
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !state.orbVisible)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                driver.update(now: now, phase: phase, depth: depth, signal: signal)
                driver.draw(&context, size: size)
            }
        }
        .contentShape(Circle())
        .accessibilityLabel("VOID")
    }
}

/// Holds the orb's smoothed motion and draws it. Lives outside SwiftUI state on purpose:
/// it changes every frame and nothing else needs to observe it.
final class OrbDriver {
    private struct Ripple {
        var age: Double        // 0...1
        var strength: Double
    }

    private static let segments = 180
    private static let maxInnerRings = 3

    private let calm = SIMD3<Double>(0.86, 0.89, 0.96)
    private let accentColor = SIMD3<Double>(0.40, 0.82, 1.0)
    private let deepColor = SIMD3<Double>(0.72, 0.62, 1.0)

    private var lastTime: TimeInterval = 0
    private var time = 0.0
    private var spin = 0.0

    private var accent = 0.0
    private var deepTint = 0.0
    private var waveGain = 0.0
    private var waveVisible = 0.0
    private var glow = 0.0
    private var level = 0.0
    private var previousLevel = 0.0
    private var hist = [Double](repeating: 0, count: OrbSignal.historyCount)
    private var inner = [Double](repeating: 0, count: OrbDriver.maxInnerRings)
    private var innerAlpha = 0.75
    private var thinkTime = 0.0
    private var ripples: [Ripple] = []
    private var sinceRipple = 0.0

    // MARK: - Motion

    func update(now: TimeInterval, phase: OrbPhase, depth: Int, signal: OrbSignal) {
        var dt = lastTime == 0 ? 1.0 / 60.0 : now - lastTime
        dt = min(max(dt, 0.001), 0.1)
        lastTime = now
        time += dt

        signal.decay()
        let live = signal.snapshot()

        var targetAccent = 0.0
        var targetDeep = 0.0
        var targetGain = 0.0
        var targetWave = 0.0
        var targetGlow = 0.0
        var targetInner = [Double](repeating: 0, count: Self.maxInnerRings)
        var targetInnerAlpha = 0.75
        var spinSpeed = 1.0
        var useAudio = false

        if phase == .thinking { thinkTime += dt } else { thinkTime = 0 }

        switch phase {
        case .loading:
            targetAccent = 0.25
            targetInner = [0.6, 0.35, 0]
            targetInnerAlpha = 0.5
            spinSpeed = 0.5
            targetGlow = 0.1
        case .idle:
            break
        case .listening:
            targetAccent = 0.45
            targetGain = 0.10
            targetWave = 1
            targetGlow = 0.2
            useAudio = true
        case .thinking:
            targetAccent = 1
            targetDeep = depth >= 2 ? 0.45 : 0
            targetInner[0] = 1
            targetInner[1] = thinkTime > 0.6 ? 1 : 0
            targetInner[2] = (depth >= 2 && thinkTime > 1.4) ? 1 : 0
            spinSpeed = depth >= 2 ? 1.35 : 1.0
            targetGlow = 0.35
        case .speaking:
            targetAccent = 1
            targetGain = 0.10
            targetWave = 1
            targetInner[0] = 1
            targetInnerAlpha = 0.32
            targetGlow = 0.3
            useAudio = true
        }

        let follow = min(1, dt * 14)
        for i in 0..<hist.count {
            let target = useAudio ? Double(live.history[i]) : 0
            hist[i] += (target - hist[i]) * follow
        }
        previousLevel = level
        level += ((useAudio ? Double(live.level) : 0) - level) * follow

        let slow = min(1, dt * 3)
        accent += (targetAccent - accent) * slow
        deepTint += (targetDeep - deepTint) * slow
        waveGain += (targetGain - waveGain) * min(1, dt * 5)
        waveVisible += (targetWave - waveVisible) * min(1, dt * 5)
        glow += (targetGlow + 0.5 * level - glow) * min(1, dt * 6)
        innerAlpha += (targetInnerAlpha - innerAlpha) * min(1, dt * 4)
        for i in 0..<inner.count {
            inner[i] += (targetInner[i] - inner[i]) * min(1, dt * 3.5)
        }
        spin += dt * spinSpeed

        // Waves pulse outward while thinking (faster when thinking deep),
        // and on loud moments while speaking or listening.
        sinceRipple += dt
        if phase == .thinking {
            let every = depth >= 2 ? 0.75 : 1.1
            if sinceRipple > every {
                ripples.append(Ripple(age: 0, strength: depth >= 2 ? 0.9 : 0.6))
                sinceRipple = 0
            }
        } else if useAudio, level - previousLevel > 0.02, level > 0.25, sinceRipple > 0.35 {
            ripples.append(Ripple(age: 0, strength: min(1, level)))
            sinceRipple = 0
        }
        for i in ripples.indices { ripples[i].age += dt / 1.6 }
        ripples.removeAll { $0.age >= 1 }
    }

    // MARK: - Drawing

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let breathe = 1 + 0.008 * sin(time * 1.2)
        let radius = Double(min(size.width, size.height)) * 0.30 * breathe

        var mixed = calm * (1 - accent) + accentColor * accent
        mixed = mixed * (1 - deepTint) + deepColor * deepTint
        let color = mixed

        func rgb(_ a: Double) -> Color {
            Color(red: color.x, green: color.y, blue: color.z).opacity(max(0, min(1, a)))
        }

        // Soft light in the middle.
        let coreRect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [rgb(0.05 + 0.08 * accent + 0.25 * glow), rgb(0)]),
                center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: CGFloat(radius)
            )
        )

        // Ripples moving outward.
        for ripple in ripples {
            let r = radius * (1.0 + 0.55 * ripple.age)
            let fade = (1 - ripple.age) * (1 - ripple.age)
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(rgb(ripple.strength * fade * 0.5)), lineWidth: 0.8)
        }

        // The main ring: a circle at rest, a wave when there's a voice.
        let main = wavePath(cx: cx, cy: cy, radius: radius, t: time, gain: waveGain, flip: false)
        glowStroke(&context, main, color: rgb(0.85), width: 1.5, glow: 0.6 + glow)

        // Second line: a quiet inner ring at rest, an interwoven wave when there's a voice.
        if waveVisible > 0.02 {
            let second = wavePath(cx: cx, cy: cy, radius: radius, t: time * 1.3 + 2.0, gain: waveGain * 0.8, flip: true)
            context.stroke(second, with: .color(rgb(0.35 * waveVisible)), lineWidth: 0.9)
        }
        if waveVisible < 0.98 {
            let r = radius * 0.90
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(rgb(0.18 * (1 - waveVisible))), lineWidth: 0.7)
        }

        // Spinning rings inside: VOID is thinking.
        for i in 0..<inner.count where inner[i] > 0.02 {
            let r = radius * (0.72 - 0.12 * Double(i))
            let direction: Double = i % 2 == 0 ? 1 : -1
            let tiltX = 0.72 + 0.22 * Double(i) + 0.18 * sin(time * 0.7 + Double(i))
            let tiltY = spin * (1.1 + 0.45 * Double(i)) * direction
            let tiltZ = 0.6 * Double(i) + spin * 0.2
            let rings = tiltedRing(cx: cx, cy: cy, radius: r, ax: tiltX, ay: tiltY, az: tiltZ)
            let alpha = inner[i] * innerAlpha
            context.stroke(rings.back, with: .color(rgb(alpha * 0.35)), lineWidth: 0.9)
            glowStroke(&context, rings.front, color: rgb(alpha), width: 1.1, glow: 0.4 * inner[i])
        }
    }

    /// A line with a soft blurred glow under it.
    private func glowStroke(_ context: inout GraphicsContext, _ path: Path, color: Color, width: CGFloat, glow: Double) {
        let glowColor = color.opacity(min(1, 0.55 * glow))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.stroke(path, with: .color(glowColor), lineWidth: width * 3)
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// A closed wavy ring whose bumps come from the recent audio levels.
    private func wavePath(cx: Double, cy: Double, radius: Double, t: Double, gain: Double, flip: Bool) -> Path {
        var path = Path()
        let n = Self.segments
        let last = hist.count - 1
        // Six smooth harmonics, each driven by a different moment of recent audio.
        var amps = [Double](repeating: 0, count: 6)
        for k in 0..<6 {
            let recent = hist[min(k * 5, last)]
            amps[k] = flip ? hist[max(last - k * 5, 0)] * 0.7 + recent * 0.3 : recent
        }
        for s in 0...n {
            let phi = 2 * Double.pi * Double(s) / Double(n)
            var w = 0.0
            for k in 0..<6 {
                let harmonic = Double(k + 2)
                w += amps[k] * sin(harmonic * phi + t * (0.9 + 0.35 * harmonic) + harmonic * 1.7) / (1 + 0.25 * harmonic)
            }
            let idle = 0.010 * sin(3 * phi + 0.8 * t) + 0.006 * sin(5 * phi - 1.1 * t)
            let r = radius * (1 + idle + gain * w)
            let point = CGPoint(x: cx + cos(phi) * r, y: cy + sin(phi) * r)
            if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A circle turned in 3D and flattened onto the screen. Returns the near half
    /// and the far half separately so the far side can be dimmer.
    private func tiltedRing(
        cx: Double, cy: Double, radius: Double, ax: Double, ay: Double, az: Double
    ) -> (front: Path, back: Path) {
        var front = Path()
        var back = Path()
        let n = 120
        let cosX = cos(ax), sinX = sin(ax)
        let cosY = cos(ay), sinY = sin(ay)
        let cosZ = cos(az), sinZ = sin(az)

        var lastPoint = CGPoint.zero
        var lastZ = 0.0
        for s in 0...n {
            let phi = 2 * Double.pi * Double(s) / Double(n)
            // A flat unit circle, turned around X, then Y, then Z.
            let x0 = cos(phi), y0 = sin(phi)
            let y1 = y0 * cosX
            let z1 = y0 * sinX
            let x2 = x0 * cosY + z1 * sinY
            let z2 = -x0 * sinY + z1 * cosY
            let x3 = x2 * cosZ - y1 * sinZ
            let y3 = x2 * sinZ + y1 * cosZ
            let point = CGPoint(x: cx + x3 * radius, y: cy + y3 * radius)
            if s > 0 {
                if (lastZ + z2) / 2 >= 0 {
                    front.move(to: lastPoint); front.addLine(to: point)
                } else {
                    back.move(to: lastPoint); back.addLine(to: point)
                }
            }
            lastPoint = point
            lastZ = z2
        }
        return (front, back)
    }
}
