// The writing surface: Apple's PencilKit canvas, wrapped for SwiftUI.
// PencilKit handles everything the web version had to build by hand:
// low-latency ink, pressure, palm rejection, smoothing.
// Our only job is to notice each finished stroke and hand its points to the model.

import SwiftUI
import PencilKit

/// The three pens from the web hotbar, as PencilKit tools.
enum PenKind: String, CaseIterable, Identifiable {
    case pencil, pen, marker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pencil: "Pencil"
        case .pen: "Pen"
        case .marker: "Marker"
        }
    }

    /// Ink color for each pen (same colors as the web version)
    var color: Color {
        switch self {
        case .pencil: Color(hex: 0x5A6472)
        case .pen: Color(hex: 0x1F3A68)
        case .marker: Color(hex: 0x1C2B22)
        }
    }

    /// Thickness of the sample squiggle in the hotbar
    var sampleWidth: CGFloat {
        switch self {
        case .pencil: 1.75
        case .pen: 3.5
        case .marker: 7
        }
    }

    /// The PencilKit tool that actually draws
    var inkingTool: PKInkingTool {
        switch self {
        case .pencil: PKInkingTool(.pencil, color: UIColor(color), width: 3)
        case .pen: PKInkingTool(.pen, color: UIColor(color), width: 4)
        case .marker: PKInkingTool(.monoline, color: UIColor(color), width: 9)
        }
    }
}

struct InkCanvas: UIViewRepresentable {
    var pen: PenKind
    var clearToken: Int   // change this number to wipe the canvas
    var onStroke: (_ points: [Point], _ start: TimeInterval, _ end: TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStroke: onStroke, clearToken: clearToken)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // .default follows the iPad's own setting: with an Apple Pencil paired, only the
        // Pencil draws (fingers and palms don't). In the simulator, the mouse draws.
        canvas.drawingPolicy = .default
        canvas.backgroundColor = .clear     // let the grid paper show through
        canvas.isOpaque = false
        canvas.tool = pen.inkingTool
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = pen.inkingTool
        context.coordinator.onStroke = onStroke

        if context.coordinator.clearToken != clearToken {
            context.coordinator.clearToken = clearToken
            context.coordinator.knownCount = 0
            canvas.drawing = PKDrawing()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onStroke: ([Point], TimeInterval, TimeInterval) -> Void
        var clearToken: Int
        var knownCount = 0   // how many strokes we've already handed over

        init(onStroke: @escaping ([Point], TimeInterval, TimeInterval) -> Void, clearToken: Int) {
            self.onStroke = onStroke
            self.clearToken = clearToken
        }

        // PencilKit calls this whenever the drawing changes, e.g. when a stroke finishes.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let strokes = canvasView.drawing.strokes
            guard strokes.count > knownCount else {
                knownCount = strokes.count
                return
            }

            for stroke in strokes[knownCount...] {
                // A stroke's path is its list of points. Convert them to our Point type.
                var points: [Point] = []
                for p in stroke.path {
                    let location = p.location.applying(stroke.transform)
                    points.append(Point(x: Double(location.x), y: Double(location.y)))
                }
                // Timing for the grouping rule: when the stroke started and ended
                let start = stroke.path.creationDate.timeIntervalSince1970
                let end = start + (stroke.path.last?.timeOffset ?? 0)
                onStroke(points, start, end)
            }
            knownCount = strokes.count
        }
    }
}
