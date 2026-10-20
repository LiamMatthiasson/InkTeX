// The writing surface: PencilKit (ink, pressure, palm rejection) over notebook pages,
// with zoom, undo/redo gestures, and a callback for every finished stroke.

import SwiftUI
import PencilKit

enum PenKind: String, CaseIterable, Identifiable {
    case pencil, pen, marker, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pencil: "Pencil"
        case .pen: "Pen"
        case .marker: "Marker"
        case .eraser: "Eraser"
        }
    }

    var color: Color {
        switch self {
        case .pencil: Color(hex: 0x5A6472)
        case .pen: Color(hex: 0x1F3A68)
        case .marker: Color(hex: 0x1C2B22)
        case .eraser: Color.muted
        }
    }

    /// The hotbar squiggle's thickness
    var sampleWidth: CGFloat {
        switch self {
        case .pencil: 1.75
        case .pen: 3.5
        case .marker: 7
        case .eraser: 0
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .pencil: 3
        case .pen: 4
        case .marker: 9
        case .eraser: 24
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        self == .eraser ? 6...80 : 1...20
    }

    func pkTool(width: CGFloat) -> PKTool {
        switch self {
        case .pencil: PKInkingTool(.pencil, color: UIColor(color), width: width)
        case .pen: PKInkingTool(.pen, color: UIColor(color), width: width)
        case .marker: PKInkingTool(.monoline, color: UIColor(color), width: width)
        // .bitmap can cut strokes in half; .vector deletes whole strokes
        case .eraser: PKEraserTool(.bitmap, width: width)
        }
    }
}

/// iPadOS's own three-finger edit gestures off, so ours get those touches.
final class NoteCanvasView: PKCanvasView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }
}

/// One finished stroke, in page coordinates (unaffected by zoom).
struct StrokeInfo {
    var points: [Point]
    var start: TimeInterval
    var end: TimeInterval
}

// MARK: - Page layout

/// In page coordinates (unzoomed), the coordinates strokes are stored in.
enum PageLayout {
    static let pageWidth: CGFloat = 768
    static let pageHeight: CGFloat = pageWidth * 11 / 8.5   // US Letter
    static let gap: CGFloat = 28
    static let contentWidth: CGFloat = pageWidth + 2 * gap
    static let pageStride: CGFloat = pageHeight + gap

    static func pageRect(_ i: Int) -> CGRect {
        CGRect(x: gap, y: gap + CGFloat(i) * pageStride, width: pageWidth, height: pageHeight)
    }

    static func contentHeight(pages: Int) -> CGFloat {
        gap + CGFloat(pages) * pageStride
    }

    /// Every page with ink, plus one blank page after.
    static func pageCount(for drawing: PKDrawing) -> Int {
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return 1 }
        let lastUsedPage = Int(floor((bounds.maxY - gap) / pageStride))
        return max(1, lastUsedPage + 2)
    }
}

// MARK: - The pages behind the ink

/// Desk, pages and grid, lined up with the canvas's zoom and scroll.
final class PageBackgroundView: UIView {
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { setNeedsDisplay() } } }
    var offset: CGPoint = .zero { didSet { if offset != oldValue { setNeedsDisplay() } } }
    var pageCount = 1 { didSet { if pageCount != oldValue { setNeedsDisplay() } } }

    private let deskColor = UIColor(Color(hex: 0xC9D0C2))
    private let paperColor = UIColor(Color.paper)
    private let fineLine = UIColor(Color.grid)
    private let majorLine = UIColor(Color.gridMajor)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = deskColor
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A page point p shows up on screen at p * zoom - offset.
    private func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom - offset.x, y: r.minY * zoom - offset.y,
               width: r.width * zoom, height: r.height * zoom)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        for i in 0..<pageCount {
            let page = PageLayout.pageRect(i)
            let onScreen = toScreen(page)
            guard onScreen.intersects(bounds) else { continue }

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                              color: UIColor.black.withAlphaComponent(0.18).cgColor)
            context.setFillColor(paperColor.cgColor)
            context.fill(onScreen)
            context.restoreGState()

            context.saveGState()
            context.clip(to: onScreen)
            drawGrid(context, page: page, every: 20, color: fineLine)
            drawGrid(context, page: page, every: 100, color: majorLine)
            context.restoreGState()
        }
    }

    private func drawGrid(_ context: CGContext, page: CGRect, every step: CGFloat, color: UIColor) {
        guard step * zoom >= 4 else { return }        // too dense

        var x = page.minX
        while x <= page.maxX {
            let sx = x * zoom - offset.x
            context.move(to: CGPoint(x: sx, y: page.minY * zoom - offset.y))
            context.addLine(to: CGPoint(x: sx, y: page.maxY * zoom - offset.y))
            x += step
        }
        var y = page.minY
        while y <= page.maxY {
            let sy = y * zoom - offset.y
            context.move(to: CGPoint(x: page.minX * zoom - offset.x, y: sy))
            context.addLine(to: CGPoint(x: page.maxX * zoom - offset.x, y: sy))
            y += step
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}

/// Pages behind, PencilKit canvas in front.
final class InkContainerView: UIView {
    let pages = PageBackgroundView()
    let canvas = NoteCanvasView()
    private var didFirstLayout = false

    // Room for the hotbar and toolbar
    static let topInset: CGFloat = 84
    static let bottomInset: CGFloat = 90

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(pages)
        addSubview(canvas)
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentInset = UIEdgeInsets(top: Self.topInset, left: 0, bottom: Self.bottomInset, right: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pages.frame = bounds
        canvas.frame = bounds
        guard bounds.width > 0 else { return }

        // "Fit" zoom: the page fills the width; zoom in up to 4x from there
        let fit = bounds.width / PageLayout.contentWidth
        if abs(canvas.minimumZoomScale - fit) > 0.0001 {
            let wasAtFit = canvas.zoomScale <= canvas.minimumZoomScale + 0.001
            canvas.minimumZoomScale = fit
            canvas.maximumZoomScale = fit * 4
            if wasAtFit || canvas.zoomScale < fit {
                canvas.zoomScale = fit
            }
        }

        updateContentSize()

        if !didFirstLayout {
            didFirstLayout = true
            scrollToTop()
        }
        syncPages()
    }

    func updateContentSize() {
        let count = PageLayout.pageCount(for: canvas.drawing)
        pages.pageCount = count
        let zoom = canvas.zoomScale
        canvas.contentSize = CGSize(width: PageLayout.contentWidth * zoom,
                                    height: PageLayout.contentHeight(pages: count) * zoom)
    }

    func scrollToTop() {
        canvas.setContentOffset(CGPoint(x: 0, y: -canvas.contentInset.top), animated: false)
    }

    func syncPages() {
        pages.zoom = canvas.zoomScale
        pages.offset = canvas.contentOffset
    }
}

// MARK: - SwiftUI wrapper

/// Bump `token` to load `drawing` (a saved note, or an empty one to erase).
struct CanvasLoad {
    var token = 0
    var drawing = PKDrawing()
}

struct InkCanvas: UIViewRepresentable {
    var pen: PenKind
    var width: CGFloat
    var load: CanvasLoad
    var onStroke: (StrokeInfo) -> Void            // one new stroke
    var onStrokesReplaced: ([StrokeInfo]) -> Void // undo/redo/load: all strokes
    var onDrawingChanged: (PKDrawing) -> Void     // any change (for saving)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InkContainerView {
        let container = InkContainerView()
        let canvas = container.canvas

        // Follows the iPad's setting: with a Pencil paired, fingers pan and zoom
        canvas.drawingPolicy = .default
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = pen.pkTool(width: width)
        canvas.delegate = context.coordinator

        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true

        let undoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.undo))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 1
        canvas.addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.redo))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 1
        canvas.addGestureRecognizer(redoTap)

        context.coordinator.container = container
        return container
    }

    func updateUIView(_ container: InkContainerView, context: Context) {
        context.coordinator.parent = self
        container.canvas.tool = pen.pkTool(width: width)

        if context.coordinator.loadToken != load.token {
            context.coordinator.loadToken = load.token
            context.coordinator.knownStrokes = []
            // PencilKit reports this change mid-update, where changing the model isn't
            // allowed: ignore it and hand the strokes over just after the update instead.
            context.coordinator.isLoading = true
            container.canvas.drawing = load.drawing
            context.coordinator.isLoading = false
            container.canvas.undoManager?.removeAllActions()    // undo can't cross notes
            container.updateContentSize()
            container.scrollToTop()
            let coordinator = context.coordinator
            let canvas = container.canvas
            DispatchQueue.main.async {
                coordinator.canvasViewDrawingDidChange(canvas)
            }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: InkCanvas
        var loadToken: Int
        weak var container: InkContainerView?
        var knownStrokes: [PKStroke] = []   // already told to the model
        var isLoading = false

        init(parent: InkCanvas) {
            self.parent = parent
            self.loadToken = parent.load.token
        }

        // MARK: Gestures

        @objc func undo() {
            container?.canvas.undoManager?.undo()
        }

        @objc func redo() {
            container?.canvas.undoManager?.redo()
        }

        // MARK: Drawing changes

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading else { return }    // see updateUIView
            container?.updateContentSize()

            let strokes = canvasView.drawing.strokes

            // One stroke appended: recognize it. Anything else: replay everything.
            if strokes.count == knownStrokes.count + 1, isSamePrefix(strokes, knownStrokes) {
                parent.onStroke(Coordinator.info(for: strokes[strokes.count - 1]))
            } else if strokes.count != knownStrokes.count || !isSamePrefix(strokes, knownStrokes) {
                parent.onStrokesReplaced(strokes.map { Coordinator.info(for: $0) })
            }
            knownStrokes = strokes
            parent.onDrawingChanged(canvasView.drawing)
        }

        /// Compared by creation date and bounds (an erased stroke changes). Not by point
        /// count: PencilKit adjusts that after drawing, which replayed the whole page.
        private func isSamePrefix(_ strokes: [PKStroke], _ known: [PKStroke]) -> Bool {
            guard strokes.count >= known.count else { return false }
            for i in known.indices {
                if strokes[i].path.creationDate != known[i].path.creationDate { return false }
                if !roughlyEqual(strokes[i].renderBounds, known[i].renderBounds) { return false }
            }
            return true
        }

        private func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
                && abs(a.maxX - b.maxX) < 1 && abs(a.maxY - b.maxY) < 1
        }

        static func info(for stroke: PKStroke) -> StrokeInfo {
            var points: [Point] = []
            for p in stroke.path {
                let location = p.location.applying(stroke.transform)
                points.append(Point(x: Double(location.x), y: Double(location.y)))
            }
            let start = stroke.path.creationDate.timeIntervalSince1970
            let end = start + (stroke.path.last?.timeOffset ?? 0)
            return StrokeInfo(points: points, start: start, end: end)
        }

        // MARK: Zoom and scroll

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.syncPages()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.syncPages()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            container?.updateContentSize()
            container?.syncPages()
        }
    }
}
