import SwiftUI

struct ConfettiOverlay: View {
    @Binding var isPresented: Bool
    @State private var startTime: Date?
    @State private var bursts: [ConfettiBurst] = []

    private static let duration: TimeInterval = 3.5
    private let colors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink,
        .mint, .cyan, .indigo
    ]

    var body: some View {
        GeometryReader { geo in
        TimelineView(.animation) { timeline in
            let elapsed = startTime.map { timeline.date.timeIntervalSince($0) } ?? 0

            Canvas { context, size in
                if bursts.isEmpty { return }
                for burst in bursts {
                    let bt = elapsed - burst.delay
                    guard bt > 0 else { continue }

                    // Flash
                    if bt < 0.3 {
                        let flashAlpha = 1.0 - bt / 0.3
                        let flashRect = CGRect(
                            x: burst.originX - 60,
                            y: burst.originY - 60,
                            width: 120, height: 120
                        )
                        context.opacity = flashAlpha * 0.4
                        context.fill(Circle().path(in: flashRect), with: .color(.white))
                        context.opacity = 1
                    }

                    // Particles
                    for p in burst.particles {
                        let t = min(bt, 3.0)
                        let expandT = min(t / 0.5, 1.0) // explosion over 0.5s
                        let eased = 1 - pow(1 - expandT, 3) // ease out cubic

                        let gravity = 120.0 * t * t // accelerating fall
                        let drag = 1.0 - min(t * 0.15, 0.7) // slow down horizontally

                        let x = burst.originX + p.dx * eased * drag
                        let y = burst.originY + p.dy * eased * drag + gravity
                        let rotation = Angle.degrees(p.spin * eased)

                        let fade = max(0, 1.0 - max(0, (t - 1.5) / 1.5))
                        let scale = max(0.2, 1.0 - max(0, (t - 1.0) / 2.0) * 0.8)

                        guard fade > 0 else { continue }

                        context.opacity = fade
                        context.translateBy(x: x, y: y)
                        context.rotate(by: rotation)
                        context.scaleBy(x: scale, y: scale)

                        let w = p.size
                        let h = p.size * p.aspectRatio
                        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                        let path = p.shapeType == 0
                            ? Circle().path(in: rect)
                            : Rectangle().path(in: rect)
                        context.fill(path, with: .color(p.color))

                        // Reset transform
                        context.scaleBy(x: 1 / scale, y: 1 / scale)
                        context.rotate(by: -rotation)
                        context.translateBy(x: -x, y: -y)
                        context.opacity = 1
                    }
                }
            }
            .onChange(of: elapsed >= Self.duration) {
                if elapsed >= Self.duration {
                    isPresented = false
                }
            }
        }
        .onAppear {
            startTime = .now
            generateBursts(in: geo.size)
        }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func generateBursts(in size: CGSize) {
        let origins: [(CGFloat, CGFloat, Double)] = [
            (0.50, 0.35, 0.0),
            (0.25, 0.28, 0.25),
            (0.75, 0.32, 0.45),
        ]

        bursts = origins.map { (xPct, yPct, delay) in
            ConfettiBurst(
                originX: size.width * xPct,
                originY: size.height * yPct,
                delay: delay,
                particles: (0..<40).map { _ in
                    let angle = Double.random(in: 0...(2 * .pi))
                    let radius = CGFloat.random(in: 80...200)
                    return ConfettiParticle(
                        color: colors.randomElement()!,
                        size: CGFloat.random(in: 5...12),
                        aspectRatio: CGFloat.random(in: 0.5...2.0),
                        dx: cos(angle) * radius,
                        dy: sin(angle) * radius - 40, // bias upward
                        spin: Double.random(in: -540...540),
                        shapeType: Int.random(in: 0...1)
                    )
                }
            )
        }
    }
}

// MARK: - Models

private struct ConfettiBurst: Identifiable {
    let id = UUID()
    let originX: CGFloat
    let originY: CGFloat
    let delay: TimeInterval
    let particles: [ConfettiParticle]
}

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGFloat
    let aspectRatio: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let spin: Double
    let shapeType: Int
}
