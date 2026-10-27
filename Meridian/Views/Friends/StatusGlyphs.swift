import SwiftUI

// MARK: - Status glyphs

/// The Steam statuses' four glyphs, drawn rather than taken from SF Symbols
/// so each can move the way Control Center's do: Online's figure hops and
/// sends out a ripple, Away's moon passes through an eclipse, Invisible's
/// eye blinks and is struck through, Offline's power ring turns.
///
/// A pose is a pure function of two clocks, so every frame is exact:
/// `reveal` (0...1) draws the glyph in as the panel opens, and `pick` counts
/// choices, its fraction being the move in flight. Every whole number is the
/// resting pose, so moves chain without a reset.
struct StatusGlyph: View, Animatable {
    enum Kind: Sendable {
        case presence, eclipse, hide, power

        /// How long the move after a pick plays.
        var moveDuration: Double {
            switch self {
            case .presence: 1.0
            case .eclipse: 1.3
            case .hide:    1.0
            case .power:   1.0
            }
        }
    }

    let kind: Kind
    var reveal: Double
    var pick: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(reveal, pick) }
        set { reveal = newValue.first; pick = newValue.second }
    }

    var body: some View {
        let kind = kind
        let reveal = reveal
        let move = pick - pick.rounded(.down)
        Canvas { context, size in
            // The 18-unit design box at 55 % of the frame, centred. The rest
            // is room for moves that reach past it.
            let scale = min(size.width, size.height) * 0.55 / 18
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -9, y: -9)
            switch kind {
            case .presence: GlyphDrawing.presence(in: &context, reveal: reveal, move: move)
            case .eclipse: GlyphDrawing.eclipse(in: &context, reveal: reveal, move: move)
            case .hide:    GlyphDrawing.hide(in: &context, reveal: reveal, move: move)
            case .power:   GlyphDrawing.power(in: &context, reveal: reveal, move: move)
            }
        }
    }
}

/// The glyphs in an 18-unit box, y down. Strokes match SF Symbols' semibold
/// weight at the panel's size. Each reaches its resting pose at `reveal` 1
/// with `move` 0, and again as `move` nears 1.
private enum GlyphDrawing {
    static var line: StrokeStyle { StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round) }

    // MARK: Online: the figure hops and sends out a ripple

    static func presence(in context: inout GraphicsContext, reveal r: Double, move t: Double) {
        var rise = 0.0, opacity = 1.0, head = 1.0, lift = 0.0, squash = 0.0
        if r < 1 {
            // Opening: the shoulders rise into place, then the head pops on.
            rise = 5 * (1 - easeOut(span(r, 0, 0.5)))
            opacity = span(r, 0, 0.25)
            head = overshoot(span(r, 0.3, 0.65))
        } else if t > 0 {
            // Crouch, hop, land; a ripple leaves as it takes off.
            squash = bump(t, 0, 0.26) + 0.6 * bump(t, 0.6, 0.86)
            lift = 1.8 * bump(t, 0.2, 0.62)
            // Ripples keep clear of the figure: they start outside its widest
            // squashed shoulders, and the second waits for the head to come down.
            for (k, (from, to)) in [(0.28, 0.84), (0.56, 1.0)].enumerated() {
                let p = span(t, from, to)
                guard p > 0, p < 1 else { continue }
                var ripple = context
                ripple.opacity = (k == 0 ? 0.8 : 0.5) * (1 - p)
                var style = line
                style.lineWidth = lerp(1.5, 0.8, p)
                ripple.stroke(circle(CGPoint(x: 9, y: 9), lerp(10.4, 14, easeOut(p))), with: .foreground, style: style)
            }
        }

        // SF Symbols' person.fill proportions: the head clear of the shoulders.
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: 2.8, y: 15))
        shoulders.addCurve(to: CGPoint(x: 9, y: 10.4), control1: CGPoint(x: 2.8, y: 12.2), control2: CGPoint(x: 5.6, y: 10.4))
        shoulders.addCurve(to: CGPoint(x: 15.2, y: 15), control1: CGPoint(x: 12.4, y: 10.4), control2: CGPoint(x: 15.2, y: 12.2))
        shoulders.addQuadCurve(to: CGPoint(x: 14, y: 16.2), control: CGPoint(x: 15.2, y: 16.2))
        shoulders.addLine(to: CGPoint(x: 4, y: 16.2))
        shoulders.addQuadCurve(to: CGPoint(x: 2.8, y: 15), control: CGPoint(x: 2.8, y: 16.2))
        shoulders.closeSubpath()

        var figure = context
        figure.opacity = opacity
        // Squash and stretch about the feet, which stay on the ground line.
        figure.translateBy(x: 9, y: 16.2 + rise - lift)
        figure.scaleBy(x: 1 + 0.08 * squash, y: 1 - 0.12 * squash)
        figure.translateBy(x: -9, y: -16.2)
        figure.fill(shoulders, with: .foreground)
        if head > 0 { figure.fill(circle(CGPoint(x: 9, y: 5.6), 3.4 * head), with: .foreground) }
    }

    // MARK: Away: the moon passes through an eclipse

    static func eclipse(in context: inout GraphicsContext, reveal r: Double, move t: Double) {
        let radius = 7.2
        // The shadow disc's centre, from the moon's. At rest it leaves SF
        // Symbols' crescent, lit side to the lower left.
        let rest = CGVector(dx: 4.6, dy: -3.4)
        let clear = scaled(rest, 2.3 * radius / hypot(rest.dx, rest.dy))
        // The eclipse's path: in from the left (starting just clear of the
        // disc), passing 2.5 units off centre so a sliver stays lit, then on
        // to rest.
        let travel = CGVector(dx: 0.983, dy: -0.184)
        let farSide = CGVector(dx: rest.dx - 19.8 * travel.dx, dy: rest.dy - 19.8 * travel.dy)

        var shadow = rest
        var scale = 1.0
        var opacity = 1.0
        if r < 1 {
            // Opening: the full disc grows in, then the shadow slides over it.
            scale = lerp(0.4, 1, overshoot(span(r, 0, 0.45), 1.2))
            opacity = span(r, 0, 0.2)
            shadow = mix(clear, rest, easeOut(span(r, 0.2, 0.9)))
        } else if t > 0 {
            if t < 0.16 {
                // The shadow slips off: a full moon.
                shadow = mix(rest, clear, easeIn(span(t, 0, 0.16)))
            } else {
                // It comes back from the far side; both ends are clear of
                // the disc, so the jump can't show.
                shadow = mix(farSide, rest, easeInOut(span(t, 0.16, 1)))
            }
            scale = 1 + 0.1 * bump(t, 0.04, 0.45)
        }

        var moon = context
        moon.opacity = opacity
        moon.translateBy(x: 9, y: 9)
        moon.scaleBy(x: scale, y: scale)
        moon.drawLayer { layer in
            layer.fill(circle(.zero, radius), with: .foreground)
            layer.blendMode = .destinationOut
            layer.fill(circle(CGPoint(x: shadow.dx, y: shadow.dy), radius), with: .color(.black))
        }
        // The corona flares as the shadow passes closest to centre (the
        // pass's midpoint by distance falls at t ≈ 0.68).
        let corona = 0.55 * bump(t, 0.5, 0.86)
        if r >= 1, corona > 0 {
            var ring = moon
            ring.opacity = corona
            var style = line
            style.lineWidth = 1
            ring.stroke(circle(.zero, radius + 1.7), with: .foreground, style: style)
        }
    }

    // MARK: Invisible: the eye looks, blinks and is struck through

    /// At rest the struck-through eye has no pupil: the stroke's gap would
    /// cut a pupil into slivers. The pupil only shows while the stroke is
    /// off, during the move.
    static func hide(in context: inout GraphicsContext, reveal r: Double, move t: Double) {
        var lens = 1.0, pupil = 0.0, slash = 1.0, shut = 0.0
        if r < 1 {
            lens = easeOut(span(r, 0, 0.55))
            slash = easeOut(span(r, 0.5, 0.9))
        } else if t > 0 {
            // The stroke lifts off and the eye looks out; it blinks, then the
            // pupil goes as the stroke draws back across.
            slash = t < 0.14 ? 1 - easeIn(span(t, 0, 0.14)) : easeOut(span(t, 0.6, 0.88))
            pupil = t < 0.5 ? overshoot(span(t, 0.1, 0.24), 0.8) : 1 - easeIn(span(t, 0.5, 0.6))
            shut = bump(t, 0.24, 0.5)
        }
        // The upper lid fades as it nears the lower one and is gone before
        // their strokes would come within 0.75 of each other (past shut
        // 0.73), so the closed eye is the lower lid alone, never a thick band.
        let upperOpacity = 1 - span(shut, 0.58, 0.72)
        // The upper lid closes down toward the lower one: its curve's control
        // point travels toward the lower lid's, so the lids never cross.
        let upper = lerp(0, 18, shut)

        context.drawLayer { layer in
            for (control, opacity) in [(upper, upperOpacity), (18, 1)] where lens > 0 && opacity > 0 {
                var lid = Path()
                lid.move(to: CGPoint(x: 1.2, y: 9))
                lid.addQuadCurve(to: CGPoint(x: 16.8, y: 9), control: CGPoint(x: 9, y: control))
                var pen = layer
                pen.opacity = opacity
                pen.stroke(lid.trimmedPath(from: 0, to: lens), with: .foreground, style: line)
            }
            // The pupil stays a clear gap inside both lids: it's clipped to
            // the opening inset by half the stroke plus 0.75 (a quad curve's
            // peak moves half as far as its control point, hence 3.2).
            if pupil > 0, upper + 3.2 < 18 - 3.2 {
                var opening = Path()
                opening.move(to: CGPoint(x: 3.2, y: 9))
                opening.addQuadCurve(to: CGPoint(x: 14.8, y: 9), control: CGPoint(x: 9, y: upper + 3.2))
                opening.addQuadCurve(to: CGPoint(x: 3.2, y: 9), control: CGPoint(x: 9, y: 18 - 3.2))
                var iris = layer
                iris.clip(to: opening)
                iris.fill(circle(CGPoint(x: 9, y: 9), 2.9 * pupil), with: .foreground)
            }

            guard slash > 0 else { return }
            var stroke = Path()
            stroke.move(to: CGPoint(x: 3.2, y: 2.4))
            stroke.addLine(to: CGPoint(x: 14.8, y: 15.6))
            stroke = stroke.trimmedPath(from: 0, to: slash)
            // Cut a gap through the eye either side of the stroke, as SF
            // Symbols' slashes do, whatever sits behind the glyph.
            var gap = line
            gap.lineWidth += 2.6
            layer.blendMode = .destinationOut
            layer.stroke(stroke, with: .color(.black), style: gap)
            layer.blendMode = .normal
            layer.stroke(stroke, with: .foreground, style: line)
        }
    }

    // MARK: Offline: the power ring turns

    static func power(in context: inout GraphicsContext, reveal r: Double, move t: Double) {
        let center = CGPoint(x: 9, y: 9.9)
        // The ring's gap faces up; its middle is the bottom of the ring.
        let ring = arc(center, 6.7, from: -54, to: 234)
        var drawn = 1.0, drop = 0.0, barOpacity = 1.0, bar = 1.0, press = 0.0, turn = 0.0
        if r < 1 {
            // Opening: the ring draws out both ways from the bottom, the bar drops in.
            drawn = easeOut(span(r, 0, 0.6))
            drop = -5 * (1 - overshoot(span(r, 0.35, 0.85), 1.4))
            barOpacity = span(r, 0.35, 0.55)
        } else if t > 0 {
            // Pressed in; the bar draws up out of the ring, the ring turns once
            // round, and the bar draws back down once the gap is home. The
            // ring only turns while the bar is gone, so they never cross.
            press = bump(t, 0, 0.25)
            bar = t < 0.5 ? 1 - easeIn(span(t, 0.06, 0.28)) : easeOut(span(t, 0.8, 1))
            barOpacity = min(1, bar * 4)
            turn = 360 * easeInOut(span(t, 0.28, 0.8))
        }

        var glyph = context
        let scale = 1 - 0.14 * press
        glyph.translateBy(x: center.x, y: center.y)
        glyph.scaleBy(x: scale, y: scale)
        glyph.translateBy(x: -center.x, y: -center.y)

        if drawn > 0 {
            var ringContext = glyph
            ringContext.translateBy(x: center.x, y: center.y)
            ringContext.rotate(by: .degrees(turn))
            ringContext.translateBy(x: -center.x, y: -center.y)
            ringContext.stroke(ring.trimmedPath(from: 0.5 - drawn / 2, to: 0.5 + drawn / 2), with: .foreground, style: line)
        }
        if barOpacity > 0, bar > 0 {
            var stemContext = glyph
            stemContext.opacity = barOpacity
            stemContext.translateBy(x: 0, y: drop)
            // Its top stays put, in the ring's gap; it grows and shrinks from below.
            var stem = Path()
            stem.move(to: CGPoint(x: 9, y: 1.7))
            stem.addLine(to: CGPoint(x: 9, y: 1.7 + 7.2 * bar))
            stemContext.stroke(stem, with: .foreground, style: line)
        }
    }

    // MARK: Geometry

    private static func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// An arc from `start` to `end` degrees, clockwise on screen from three
    /// o'clock. Built from short segments so its direction can't flip with
    /// the coordinate system, and so it trims by length.
    private static func arc(_ center: CGPoint, _ radius: Double, from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, Int(abs(end - start) / 3))
        for i in 0...steps {
            let angle = (start + (end - start) * Double(i) / Double(steps)) * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private static func scaled(_ v: CGVector, _ k: Double) -> CGVector {
        CGVector(dx: v.dx * k, dy: v.dy * k)
    }

    private static func mix(_ a: CGVector, _ b: CGVector, _ t: Double) -> CGVector {
        CGVector(dx: lerp(a.dx, b.dx, t), dy: lerp(a.dy, b.dy, t))
    }
}

// MARK: - Easing

/// Where `t` is between `from` and `to`, as 0...1.
private func span(_ t: Double, _ from: Double, _ to: Double) -> Double {
    min(max((t - from) / (to - from), 0), 1)
}

/// 0 at both ends of the span, 1 in its middle.
private func bump(_ t: Double, _ from: Double, _ to: Double) -> Double {
    sin(span(t, from, to) * .pi)
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func easeIn(_ x: Double) -> Double { x * x * x }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

/// Eases out past 1 and settles back (the "back" curve).
private func overshoot(_ x: Double, _ amount: Double = 1.7) -> Double {
    let c = amount + 1
    return 1 + c * pow(x - 1, 3) + amount * pow(x - 1, 2)
}
