// The writing surface: Apple's PencilKit canvas with grid paper behind it, wrapped
// for SwiftUI. PencilKit handles low-latency ink, pressure and palm rejection.
// On top of that this file adds:
//   - notebook pages (US Letter shape) stacked vertically, with a new blank page
//     appearing whenever you write on the last one
//   - pinch to zoom (the pages zoom along with the ink)
//   - two-finger double-tap = undo, three-finger double-tap = redo
//   - an eraser with an adjustable size
// and tells the model about every finished stroke.

import SwiftUI
import PencilKit

/// The tools in the hotbar: three pens (from the web version) and an eraser.
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

    /// Ink color for each pen (same colors as the web version)
    var color: Color {
        switch self {
        case .pencil: Color(hex: 0x5A6472)
        case .pen: Color(hex: 0x1F3A68)
        case .marker: Color(hex: 0x1C2B22)
        case .eraser: Color.muted
        }
    }

    /// Thickness of the sample squiggle on each hotbar button
    var sampleWidth: CGFloat {
        switch self {
        case .pencil: 1.75
        case .pen: 3.5
        case .marker: 7
        case .eraser: 0
        }
    }

    /// Starting size for each tool (the slider can change it)
    var defaultWidth: CGFloat {
        switch self {
        case .pencil: 3
        case .pen: 4
        case .marker: 9
        case .eraser: 24
        }
    }

    /// How far the size slider goes for this tool
    var widthRange: ClosedRange<CGFloat> {
        self == .eraser ? 6...80 : 1...20
    }

    /// The PencilKit tool for this hotbar item, at a given size
    func pkTool(width: CGFloat) -> PKTool {
        switch self {
        case .pencil: PKInkingTool(.pencil, color: UIColor(color), width: width)
        case .pen: PKInkingTool(.pen, color: UIColor(color), width: width)
        case .marker: PKInkingTool(.monoline, color: UIColor(color), width: width)
        // .bitmap erases like a real eraser (it can cut strokes in half);
        // .vector would delete whole strokes at a touch instead.
        case .eraser: PKEraserTool(.bitmap, width: width)
        }
    }
}

/// The PencilKit canvas with iPadOS's own three-finger edit gestures turned off
/// (three-finger double-tap = undo, three-finger swipes), so ours get those touches.
final class NoteCanvasView: PKCanvasView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }
}

/// One finished stroke, in page coordinates (unaffected by zoom).
struct StrokeInfo {
    var points: [Point]
    var start: TimeInterval   // when the pen touched down
    var end: TimeInterval     // when it lifted
}

// MARK: - Page layout

/// Where the pages sit, in page coordinates (the coordinates strokes are stored in).
/// Everything is measured unzoomed; zooming just scales it on screen.
enum PageLayout {
    static let pageWidth: CGFloat = 768
    static let pageHeight: CGFloat = pageWidth * 11 / 8.5   // US Letter shape (A4: 297 / 210)
    static let gap: CGFloat = 28            // space between pages, and around them
    static let contentWidth: CGFloat = pageWidth + 2 * gap

    /// Distance from the top of one page to the top of the next
    static let pageStride: CGFloat = pageHeight + gap

    /// Page i's rectangle (page 0 is the first)
    static func pageRect(_ i: Int) -> CGRect {
        CGRect(x: gap, y: gap + CGFloat(i) * pageStride, width: pageWidth, height: pageHeight)
    }

    /// Total height needed for this many pages
    static func contentHeight(pages: Int) -> CGFloat {
        gap + CGFloat(pages) * pageStride
    }

    /// How many pages to show: every page that has ink, plus one blank page after the
    /// last one. A brand-new notebook has a single page; writing on the last page adds
    /// the next, like Notability.
    static func pageCount(for drawing: PKDrawing) -> Int {
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return 1 }
        let lastUsedPage = Int(floor((bounds.maxY - gap) / pageStride))
        return max(1, lastUsedPage + 2)
    }
}

// MARK: - The pages behind the ink

/// Draws the desk, the paper pages and their grid, lined up with the canvas's
/// current zoom and scroll position.
final class PageBackgroundView: UIView {
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { setNeedsDisplay() } } }
    var offset: CGPoint = .zero { didSet { if offset != oldValue { setNeedsDisplay() } } }
    var pageCount = 1 { didSet { if pageCount != oldValue { setNeedsDisplay() } } }

    private let deskColor = UIColor(Color(hex: 0xC9D0C2))     // the "table" around the pages
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
            guard onScreen.intersects(bounds) else { continue }   // only draw visible pages

            // The sheet of paper, with a soft shadow
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                              color: UIColor.black.withAlphaComponent(0.18).cgColor)
            context.setFillColor(paperColor.cgColor)
            context.fill(onScreen)
            context.restoreGState()

            // Its grid, kept inside the page
            context.saveGState()
            context.clip(to: onScreen)
            drawGrid(context, page: page, every: 20, color: fineLine)
            drawGrid(context, page: page, every: 100, color: majorLine)
            context.restoreGState()
        }
    }

    private func drawGrid(_ context: CGContext, page: CGRect, every step: CGFloat, color: UIColor) {
        guard step * zoom >= 4 else { return }        // lines this dense would just be noise

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

/// Holds the pages (behind) and the PencilKit canvas (in front).
final class InkContainerView: UIView {
    let pages = PageBackgroundView()
    let canvas = NoteCanvasView()
    private var didFirstLayout = false

    // Room for the hotbar at the top and the toolbar at the bottom, so the first
    // page starts below the hotbar and you can scroll the last one above the toolbar.
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

        // "Fit" zoom: the page (plus its margins) exactly fills the screen's width.
        // You can zoom in from there to 4x, but not out past it.
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

    /// Make the scrollable area exactly as tall as the pages (which grow as you write).
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

    /// Keep the pages lined up with the ink after any zoom or scroll.
    func syncPages() {
        pages.zoom = canvas.zoomScale
        pages.offset = canvas.contentOffset
    }
}

// MARK: - SwiftUI wrapper

/// What the canvas should show. Bump `token` to load `drawing` (a saved note, or an
/// empty one to erase). Compared by token alone: "load this now" happens once per bump.
struct CanvasLoad {
    var token = 0
    var drawing = PKDrawing()
}

struct InkCanvas: UIViewRepresentable {
    var pen: PenKind
    var width: CGFloat
    var load: CanvasLoad                          // bump its token to show a different drawing
    var onStroke: (StrokeInfo) -> Void            // a new stroke was drawn
    var onStrokesReplaced: ([StrokeInfo]) -> Void // undo/redo/load changed earlier strokes: here they all are
    var onDrawingChanged: (PKDrawing) -> Void     // any change at all (for saving)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InkContainerView {
        let container = InkContainerView()
        let canvas = container.canvas

        // .default follows the iPad's own setting: with an Apple Pencil paired, only the
        // Pencil draws, and fingers pan and zoom. In the simulator the mouse draws.
        canvas.drawingPolicy = .default
        canvas.backgroundColor = .clear          // let the grid show through
        canvas.isOpaque = false
        canvas.tool = pen.pkTool(width: width)
        canvas.delegate = context.coordinator

        // Pinch to zoom (the zoom range is set in InkContainerView, from the screen width)
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true

        // Two fingers, tapped twice: undo
        let undoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.undo))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 1
        canvas.addGestureRecognizer(undoTap)

        // Three fingers, tapped twice: redo
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
            context.coordinator.knownStrokes = []               // the model starts over too
            container.canvas.drawing = load.drawing             // the delegate replays its strokes
            container.canvas.undoManager?.removeAllActions()    // undo can't cross into another note
            container.updateContentSize()                       // as many pages as the note needs
            container.scrollToTop()
            // Hand the loaded strokes to the model, just after this SwiftUI update finishes
            // (changing the model in the middle of one isn't allowed). If PencilKit also
            // reports the change itself, the second report finds nothing new.
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
        var knownStrokes: [PKStroke] = []   // the strokes we've already told the model about

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

        // PencilKit calls this whenever the drawing changes: a stroke finished, or undo/redo.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            container?.updateContentSize()      // add a blank page if you wrote on the last one

            let strokes = canvasView.drawing.strokes

            // The common case: exactly one stroke was added at the end. Tell the model about it.
            if strokes.count == knownStrokes.count + 1, isSamePrefix(strokes, knownStrokes) {
                parent.onStroke(Coordinator.info(for: strokes[strokes.count - 1]))
            } else if strokes.count != knownStrokes.count || !isSamePrefix(strokes, knownStrokes) {
                // Anything else (undo removed a stroke, redo restored one in the middle...):
                // hand over the full list and let the model rebuild from scratch.
                parent.onStrokesReplaced(strokes.map { Coordinator.info(for: $0) })
            }
            knownStrokes = strokes
            parent.onDrawingChanged(canvasView.drawing)
        }

        /// Do the first `known.count` strokes match? Compared by when each stroke was created
        /// AND where it sits, so a stroke the eraser cut into counts as changed. (Not by
        /// point count: PencilKit adjusts that slightly after a stroke is drawn, which made
        /// every stroke look "changed" and replay the whole page.)
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

        /// Convert a PencilKit stroke to our Point list, in page coordinates.
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

        // MARK: Zoom and scroll: keep the pages lined up with the ink

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
