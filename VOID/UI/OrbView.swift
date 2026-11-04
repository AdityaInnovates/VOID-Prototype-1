import SwiftUI

/// VOID's face: one clean glowing ring. When it thinks, a few subtle dots fade in, one by
/// one, on three rings inside it. No lines, only dots.
///
/// The dots interlock: ring 2's dots sit in the gaps between ring 1's, and ring 3's sit in
/// the gaps between ring 2's. The whole pattern turns together, very slowly.
///
/// - Idle / listening: nothing inside; the ring breathes or bends with your voice.
/// - Thinking: dots fade in one at a time, outer ring first, spiralling inward. Each one
///   breathes faintly. Deep thinking tints them violet. The ring drifts gently like water.
/// - Opener speaking, deep brain still working: the dots stay, nothing restarts.
/// - Answer starts speaking: each ring grows outward into its parent's place, landing
///   exactly between the parent's dots; the outer ring merges into the main ring with one
///   soft pulse and ripple. The two rows of dots left behind hold briefly, then fade.
struct OrbView: View {
    let state: AppState
    let signal: OrbSignal
    /// Overrides "only animate while the full panel is open" (the mini orb in the notch).
    var animating: Bool? = nil

    @State private var driver = OrbDriver()

    var body: some View {
        let phase = state.phase
        let depth = state.thinkingDepth
        let deepWorking = state.deepWorking
        let handoff = state.handoff
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !(animating ?? state.orbVisible))) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                driver.update(now: now, phase: phase, depth: depth, deepWorking: deepWorking, handoff: handoff, signal: signal)
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
    /// The dotted rings, outer to inner. Every ring has the same few dots; each ring is
    /// turned half a step from the one outside it, so its dots sit in the parent's gaps.
    private static let dotsPerRing = 8
    private static let dotRadii = [0.80, 0.58, 0.36]
    /// When each ring starts fading in, and the gap between its dots appearing.
    private static let ringStart = [0.0, 0.6, 1.2]
    private static let dotStagger = 0.15
    private static let dotFadeIn = 0.6
    private static let dotBrightness = 0.35
    /// The outward cascade when the answer starts. First the rings settle back into the
    /// interlocked pattern; then one ring at a time, innermost first, grows out to its
    /// parent's radius while the parent holds still, so it lands exactly in the parent's
    /// gaps; only then does the parent move on to its own parent.
    private static let settleTime = 0.3
    private static let moveDelay = [1.3, 0.8, 0.3]     // outer, middle, inner
    private static let moveTime = 0.4
    private static let holdUntil = 2.1
    private static let fadeOutTime = 0.5
    /// While thinking, the rings take turns rotating by half a step, outer ring first,
    /// alternating clockwise and anticlockwise:
    /// each one turns to where its inner ring's dots are, then the next one does the same.
    private static let turnTime = 0.55
    private static let turnPause = 0.18

    private let calm = SIMD3<Double>(0.86, 0.89, 0.96)
    private let accentColor = SIMD3<Double>(0.40, 0.82, 1.0)
    private let deepColor = SIMD3<Double>(0.72, 0.62, 1.0)

    private var lastTime: TimeInterval = 0
    private var time = 0.0

    private var accent = 0.0
    private var deepTint = 0.0
    private var waveGain = 0.0
    private var waveVisible = 0.0
    private var glow = 0.0
    private var level = 0.0
    private var hist = [Double](repeating: 0, count: OrbSignal.historyCount)
    private var ripples: [Ripple] = []

    private var lastHandoff: Int?
    private var lastPhase: OrbPhase?
    private var flash = 0.0
    private var pop = 0.0
    private var flow = 0.0

    // The dotted rings.
    private var visible = 0.0
    private var thinkClock = 0.0
    private var release = -1.0         // seconds into the outward cascade, or -1
    private var landed = false
    /// True once the dots have gone out into the ring; they stay hidden until the next thought.
    private var spent = false
    /// The cascade of turns: whose turn it is, how far through it, and each ring's
    /// accumulated rotation.
    private var turnRing = 0
    private var turnProgress = 0.0
    private var ringTurned = [0.0, 0.0, 0.0]
    /// Where each ring's rotation starts and ends while settling back into the pattern.
    private var settleFrom = [0.0, 0.0, 0.0]
    private var settleTo = [0.0, 0.0, 0.0]

    // MARK: - Motion

    func update(
        now: TimeInterval, phase: OrbPhase, depth: Int, deepWorking: Bool, handoff: Int, signal: OrbSignal
    ) {
        var dt = lastTime == 0 ? 1.0 / 60.0 : now - lastTime
        dt = min(max(dt, 0.001), 0.1)
        lastTime = now
        time += dt

        signal.decay()
        let live = signal.snapshot()
        let deepMode = depth >= 2 || deepWorking

        var targetAccent = 0.0
        var targetDeep = 0.0
        var targetGain = 0.0
        var targetWave = 0.0
        var targetGlow = 0.0
        var targetFlow = 0.0
        var targetVisible = 0.0
        var useAudio = false
        var thinking = false

        switch phase {
        case .loading:
            targetAccent = 0.25
            targetGlow = 0.1
            targetFlow = 0.3
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
            targetDeep = deepMode ? 0.45 : 0
            targetGlow = 0.35
            targetFlow = deepMode ? 0.7 : 0.45
            targetVisible = 1
            thinking = true
        case .speaking:
            targetAccent = 1
            targetGain = 0.10
            targetWave = 1
            targetGlow = 0.3
            useAudio = true
            if deepWorking {
                // The opener is talking, but the real thinking carries on underneath.
                targetDeep = 0.5
                targetFlow = 0.45
                targetVisible = 0.9
                thinking = true
            }
        }

        let follow = min(1, dt * 14)
        for i in 0..<hist.count {
            let target = useAudio ? Double(live.history[i]) : 0
            hist[i] += (target - hist[i]) * follow
        }
        level += ((useAudio ? Double(live.level) : 0) - level) * follow

        // The answer begins (or a quick reflex answer lands): the dots cascade outward.
        if let last = lastHandoff, last != handoff {
            startRelease()
        } else if lastPhase == .thinking, phase == .speaking, !deepWorking {
            startRelease()
        }
        lastHandoff = handoff
        lastPhase = phase
        flash *= exp(-dt * 3)
        pop *= exp(-dt * 5)

        if release >= 0 {
            release += dt
            // The outer ring reaches the main ring: one soft pulse and a faint ripple.
            let arrival = Self.moveDelay[0] + Self.moveTime
            if !landed && release >= arrival {
                landed = true
                flash = 0.5
                pop = 0.02
                ripples.append(Ripple(age: 0, strength: 0.4))
            }
            if release >= Self.holdUntil + Self.fadeOutTime {
                release = -1
                spent = true
            }
        }
        if thinking || release >= 0 { targetVisible = 1 }

        let slow = min(1, dt * 3)
        accent += (targetAccent - accent) * slow
        deepTint += (targetDeep - deepTint) * slow
        waveGain += (targetGain - waveGain) * min(1, dt * 5)
        waveVisible += (targetWave - waveVisible) * min(1, dt * 5)
        glow += (targetGlow + 0.5 * level + 0.5 * flash - glow) * min(1, dt * 6)
        flow += (targetFlow - flow) * min(1, dt * 2.5)
        visible += (targetVisible - visible) * min(1, dt * 3)

        // The dots keep their progress through the opener; they reset only once gone.
        if thinking && spent {
            spent = false
            resetDots()
        }
        if thinking && release < 0 { thinkClock += dt }
        if !thinking && release < 0 && visible < 0.02 {
            spent = false
            resetDots()
        }

        // Rings take turns rotating while thinking, and hold still once the answer starts.
        if thinking && release < 0 {
            let pace = deepMode ? 1.3 : 1.0
            turnProgress += dt * pace / Self.turnTime
            if turnProgress >= 1 + Self.turnPause / Self.turnTime {
                ringTurned[turnRing] += 1
                turnRing = (turnRing + 1) % ringTurned.count
                turnProgress = 0
            }
        }

        for i in ripples.indices { ripples[i].age += dt / 1.8 }
        ripples.removeAll { $0.age >= 1 }
    }

    private func startRelease() {
        // A reflex answer that came instantly has no dots to send out.
        guard thinkClock > 0.3, release < 0 else { return }
        release = 0
        landed = false
        // The rings are only interlocked at the end of a full round of turns. Finish the
        // round now (the rings still due a turn all take it together) so every ring's dots
        // sit in its parent's gaps before the cascade starts.
        let roundUnderway = turnRing != 0 || turnProgress > 0
        for k in 0..<ringTurned.count {
            settleFrom[k] = displayedTurn(k)
            settleTo[k] = ringTurned[k] + ((roundUnderway && k >= turnRing) ? 1 : 0)
        }
    }

    private func resetDots() {
        thinkClock = 0
        turnRing = 0
        turnProgress = 0
        ringTurned = [0, 0, 0]
    }

    /// How many half-steps ring k has turned, including a turn in progress.
    private func displayedTurn(_ k: Int) -> Double {
        if release >= 0 {
            let m = min(release / Self.settleTime, 1)
            return settleFrom[k] + (settleTo[k] - settleFrom[k]) * m * m * (3 - 2 * m)
        }
        var turned = ringTurned[k]
        if k == turnRing {
            let m = min(turnProgress, 1)
            turned += m * m * (3 - 2 * m)          // smooth start and stop
        }
        return turned
    }

    // MARK: - Drawing

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let breathe = 1 + 0.008 * sin(time * 1.2) + pop
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

        // A soft ripple moving forward, out past the ring.
        for ripple in ripples {
            let r = radius * (1.0 + 0.5 * ripple.age)
            let fade = (1 - ripple.age) * (1 - ripple.age)
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(rgb(ripple.strength * fade * 0.5)), lineWidth: 0.8)
        }

        drawDottedRings(&context, cx: cx, cy: cy, radius: radius, rgb: rgb)

        // The ring: a circle at rest, a wave when there's a voice.
        let main = wavePath(cx: cx, cy: cy, radius: radius, t: time, gain: waveGain, flip: false)
        glowStroke(&context, main, color: rgb(0.85), width: 1.5, glow: 0.6 + glow)

        if waveVisible > 0.02 {
            let second = wavePath(cx: cx, cy: cy, radius: radius, t: time * 1.3 + 2.0, gain: waveGain * 0.8, flip: true)
            context.stroke(second, with: .color(rgb(0.30 * waveVisible)), lineWidth: 0.9)
        }
    }

    private func drawDottedRings(
        _ context: inout GraphicsContext, cx: Double, cy: Double, radius: Double,
        rgb: (Double) -> Color
    ) {
        guard visible > 0.02, !spent else { return }
        let n = Self.dotsPerRing
        let step = 2 * Double.pi / Double(n)
        let turn = time * 0.025                    // the whole pattern, very slowly
        let breatheRate = deepTint > 0.2 ? 1.8 : 1.3

        for k in 0..<Self.dotRadii.count {
            var r = Self.dotRadii[k]
            var shine = 1.0

            if release >= 0 {
                // The rings climb outward together, one level at a time. At stage n the
                // ring that is on level n (and everything already merged with it) moves up
                // to level n+1, so each ring lands in its parent's gaps and then travels on
                // with it, ending as a row at the main ring.
                let levels = [Self.dotRadii[2], Self.dotRadii[1], Self.dotRadii[0], 1.0]
                var pos = Double(2 - k)                 // ring 0 starts on level 2, ring 2 on level 0
                var moving = false
                for stage in max(2 - k, 0)..<3 {
                    let raw = (release - Self.moveDelay[2 - stage]) / Self.moveTime
                    let m = min(max(raw, 0), 1)
                    if m > 0 && m < 1 { moving = true }
                    pos += 1 - pow(1 - m, 3)
                }
                let lower = min(Int(pos), 2)
                r = levels[lower] + (levels[lower + 1] - levels[lower]) * (pos - Double(lower))
                shine = moving ? 2.0 : (release > Self.moveDelay[2 - max(2 - k, 0)] ? 1.5 : 1.0)
                if release > Self.holdUntil {
                    shine *= max(0, 1 - (release - Self.holdUntil) / Self.fadeOutTime)
                }
            }
            guard shine > 0.01 else { continue }

            let ringRadius = radius * r
            for i in 0..<n {
                // Fade in one by one, each ring starting a little after the one outside it.
                let appear = (thinkClock - Self.ringStart[k] - Double(i) * Self.dotStagger) / Self.dotFadeIn
                let shown = min(max(appear, 0), 1)
                guard shown > 0.01 else { continue }
                let breathe = 0.8 + 0.2 * sin(time * breatheRate + Double(i) * 1.7 + Double(k) * 2.3)
                let alpha = Self.dotBrightness * shown * breathe * shine * visible
                // Ring k starts k half-steps round, so its dots sit in the parent's gaps;
                // then it adds the half-steps it has turned while thinking.
                let turned = displayedTurn(k)
                // Alternate directions: outer ring clockwise, middle anticlockwise, inner
                // clockwise. A half step either way lands in the same gaps.
                let direction: Double = k % 2 == 0 ? 1 : -1
                let a = Double(i) * step + (Double(k) + direction * turned) * step / 2 + turn - Double.pi / 2
                let p = CGPoint(x: cx + cos(a) * ringRadius, y: cy + sin(a) * ringRadius)
                let size = release >= 0 ? 1.9 : 1.5
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)),
                    with: .color(rgb(alpha)))
            }
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

    /// The slow, watery drift of the ring while VOID thinks: a few low waves, never repeating.
    private func flowShape(_ phi: Double, _ t: Double) -> Double {
        0.55 * sin(2 * phi + 0.7 * t) + 0.35 * sin(3 * phi - 1.1 * t + 1.3) + 0.2 * sin(5 * phi + 1.9 * t)
    }

    /// A closed wavy ring. Bumps come from the recent audio levels, plus a faint drift
    /// while thinking.
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
            let r = radius * (1 + idle + gain * w + 0.03 * flow * flowShape(phi, t))
            let point = CGPoint(x: cx + cos(phi) * r, y: cy + sin(phi) * r)
            if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
