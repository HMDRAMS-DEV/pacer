import AppKit

/// Draws the menu bar glyph: one ring per tool, filled to the share of the weekly limit used.
///
/// A notch marks where the plan says you should be now. When the fill passes the notch you are
/// ahead of plan. The glyph is a monochrome template image unless a tool will run out early,
/// in which case that ring turns orange.
enum MenuBarIcon {
    struct Ring: Equatable {
        var used: Double
        var expected: Double?
        var alert: Bool
    }

    static func image(rings: [Ring]) -> NSImage {
        let alert = rings.contains(where: \.alert)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let base: NSColor = alert ? .labelColor : .black
            let specs: [(radius: CGFloat, width: CGFloat)] = rings.count > 1 ? [(7, 2), (3.6, 2)] : [(6.5, 2.4)]

            guard !rings.isEmpty else {
                let empty = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
                empty.lineWidth = 1.5
                empty.setLineDash([2, 2], count: 2, phase: 0)
                base.withAlphaComponent(0.6).setStroke()
                empty.stroke()
                return true
            }

            for (ring, spec) in zip(rings, specs) {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: spec.radius, startAngle: 0, endAngle: 360)
                track.lineWidth = spec.width
                base.withAlphaComponent(0.3).setStroke()
                track.stroke()

                let used = min(max(ring.used, 0), 1)
                if used > 0.005 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: spec.radius, startAngle: 90, endAngle: 90 - 360 * used, clockwise: true)
                    arc.lineWidth = spec.width
                    arc.lineCapStyle = used < 0.995 ? .round : .butt
                    (ring.alert ? NSColor.systemOrange : base).setStroke()
                    arc.stroke()
                }

                if let expected = ring.expected, expected > 0.01, expected < 0.99 {
                    let angle = (90 - 360 * expected) * .pi / 180
                    func point(_ radius: CGFloat) -> NSPoint {
                        NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    }
                    let notch = NSBezierPath()
                    notch.move(to: point(spec.radius - spec.width / 2 - 0.5))
                    notch.line(to: point(spec.radius + spec.width / 2 + 0.5))
                    notch.lineWidth = 1.4
                    NSGraphicsContext.current?.compositingOperation = .clear
                    notch.stroke()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                }
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }
}
