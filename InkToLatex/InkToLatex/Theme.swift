// Colors, grid paper and button styles (mirrors styles.css).

import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static let paper = Color(hex: 0xEEF2E6)
    static let grid = Color(hex: 0xDCE5D0)         // every 20 pt
    static let gridMajor = Color(hex: 0xC9D6BA)    // every 100 pt
    static let sheet = Color(hex: 0xFAFBF6)        // panels and bars
    static let rule = Color(hex: 0xCBD5C0)         // borders
    static let ink = Color(hex: 0x22302A)
    static let muted = Color(hex: 0x66746B)
    static let padGreen = Color(hex: 0x2F5D44)
    static let padGreenTint = Color(hex: 0xDDE8D3)
    static let brick = Color(hex: 0x9E3B3B)
}

// MARK: - Grid paper background

struct GridPaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.paper))
            drawLines(in: &context, size: size, every: 20, color: .grid)
            drawLines(in: &context, size: size, every: 100, color: .gridMajor)
        }
    }

    private func drawLines(in context: inout GraphicsContext, size: CGSize, every step: CGFloat, color: Color) {
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(color), lineWidth: 1)
    }
}

// MARK: - Pen button squiggle

struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0.05 * w, y: 0.65 * h))
        p.addCurve(to: CGPoint(x: 0.55 * w, y: 0.45 * h),
                   control1: CGPoint(x: 0.2 * w, y: 0.05 * h),
                   control2: CGPoint(x: 0.35 * w, y: 0.95 * h))
        p.addCurve(to: CGPoint(x: 0.95 * w, y: 0.5 * h),
                   control1: CGPoint(x: 0.75 * w, y: 0.05 * h),
                   control2: CGPoint(x: 0.85 * w, y: 0.2 * h))
        return p
    }
}

// MARK: - Button styles

struct FilledButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .footnote.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(compact ? Color.padGreen : Color.ink)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 10)
            .background(configuration.isPressed ? Color.paper : Color.clear,
                        in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 8).stroke(Color.rule))
    }
}

/// The floating sheet behind the toolbars
extension View {
    func floatingSheet(cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(5)
            .background(Color.sheet, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.rule))
            .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
    }
}

