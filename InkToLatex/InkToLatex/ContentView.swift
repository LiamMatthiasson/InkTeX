// The screen: the notebook (pages + PencilKit) with the pen hotbar on top and the
// toolbar at the bottom, and, in split view, the LaTeX panel beside it with a handle
// you drag to resize. Notes save themselves a second after you stop writing.

import SwiftUI
import PencilKit

struct ContentView: View {
    @State private var model = NoteModel()
    @State private var store = NoteStore()

    // The open note
    @State private var currentNote: UUID?
    @State private var canvasLoad = CanvasLoad()          // bump to show a different drawing
    @State private var latestDrawing = PKDrawing()        // the ink right now (what gets saved)
    @State private var saveTask: Task<Void, Never>?       // the pending autosave

    // Pens
    @State private var pen: PenKind = .pen
    @State private var widths: [PenKind: CGFloat] = [:]   // thickness chosen for each pen

    // Panels and dialogs
    @State private var label = ""
    @State private var splitView = false
    @AppStorage("latexPanelWidth") private var panelWidth: Double = 420   // remembered between launches
    @State private var dragStartWidth: Double?            // panel width when a drag began
    @State private var showNotes = false
    @State private var confirmErase = false
    @State private var correcting: Symbol?                 // the symbol "Type another…" is for
    @State private var correctionText = ""

    @Environment(\.scenePhase) private var scenePhase

    /// Size of the preview dot: the real width, scaled down for big erasers so it fits
    private var preview: CGFloat {
        pen == .eraser ? max(6, width.wrappedValue * 30 / 80) : width.wrappedValue
    }

    /// The current tool's size, for the slider (each tool remembers its own)
    private var width: Binding<CGFloat> {
        Binding(
            get: { widths[pen] ?? pen.defaultWidth },
            set: { widths[pen] = $0 }
        )
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                notebook
                if splitView {
                    splitHandle(totalWidth: geo.size.width)
                    latexPanel
                        .frame(width: clampedPanelWidth(geo.size.width))
                }
            }
        }
        .background(Color.sheet)
        .onAppear {
            runRecognizerChecks()   // prints ✅/❌ lines in Xcode's console
            openMostRecentNote()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveNow() }   // leaving the app: save right away
        }
        .confirmationDialog("Erase everything in this note?", isPresented: $confirmErase,
                            titleVisibility: .visible) {
            Button("Erase", role: .destructive) { erase() }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - The notebook (left side, or the whole screen)

    private var notebook: some View {
        ZStack {
            // Notebook pages + PencilKit. Scroll with two fingers (one with a mouse/finger
            // when no Pencil is paired); pinch to zoom; two-finger tap = undo,
            // three-finger tap = redo.
            InkCanvas(
                pen: pen,
                width: width.wrappedValue,
                load: canvasLoad,
                onStroke: { stroke in
                    model.strokeFinished(stroke.points, startTime: stroke.start, endTime: stroke.end)
                },
                onStrokesReplaced: { strokes in
                    model.replaceStrokes(strokes)
                },
                onDrawingChanged: { drawing in
                    latestDrawing = drawing
                    scheduleSave()
                }
            )
            .ignoresSafeArea()

            VStack {
                penBar
                    .padding(.top, 8)
                Spacer()
                bottomBar
                    .padding(16)
            }
        }
    }

    // MARK: - Pen hotbar (top center)

    private var penBar: some View {
        HStack(spacing: 4) {
            ForEach(PenKind.allCases) { kind in
                Button {
                    pen = kind
                } label: {
                    VStack(spacing: 4) {
                        if kind == .eraser {
                            Image(systemName: "eraser")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(kind.color)
                                .frame(width: 56, height: 18)
                        } else {
                            Squiggle()
                                .stroke(kind.color, style: StrokeStyle(lineWidth: kind.sampleWidth, lineCap: .round))
                                .frame(width: 56, height: 18)
                        }
                        Text(kind.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(pen == kind ? Color.padGreenTint : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) {
                        if pen == kind {   // the chosen pen gets a green underline
                            Capsule()
                                .fill(Color.padGreen)
                                .frame(height: 2)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 40)
                .padding(.horizontal, 6)

            // Size slider for the current tool, with a dot showing the size
            HStack(spacing: 10) {
                Slider(value: width, in: pen.widthRange)
                    .frame(width: 130)
                    .tint(Color.padGreen)
                    .id(pen)                          // fresh slider per tool, since ranges differ
                ZStack {
                    if pen == .eraser {
                        Circle().stroke(Color.muted, lineWidth: 1.5)       // eraser: an outline
                            .frame(width: preview, height: preview)
                    } else {
                        Circle().fill(pen.color)
                            .frame(width: preview, height: preview)
                    }
                }
                .frame(width: 30, height: 30)       // fixed space so the bar doesn't jump around
            }
            .padding(.trailing, 8)
        }
        .floatingSheet(cornerRadius: 14)
    }

    // MARK: - Bottom toolbar

    /// One row when there's room; in a narrow split view, two rows instead.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                teachControls
                Spacer()
                statusText
                Spacer()
                noteControls
            }
            VStack(alignment: .leading, spacing: 8) {
                teachControls
                HStack {
                    statusText
                    Spacer()
                    noteControls
                }
            }
        }
    }

    /// Teach: type what your LAST symbol should be, tap Teach, and it becomes a template.
    private var teachControls: some View {
        HStack(spacing: 6) {
            TextField("Last symbol is… e.g. 2 or \\alpha", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(width: 220)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.rule))

            // The label stays filled in, so you can teach five "b"s in a row
            Button("Teach") { _ = model.saveTemplate(label: label) }
            .buttonStyle(FilledButtonStyle(color: .padGreen))

            // Removes the last template you taught (stroke undo is the two-finger tap)
            Button("Undo Teach") { model.undoTemplate() }
                .buttonStyle(OutlineButtonStyle())
        }
        .floatingSheet()
    }

    private var statusText: some View {
        Text(model.status)
            .font(.footnote)
            .foregroundStyle(Color.muted)
            .lineLimit(1)
    }

    private var noteControls: some View {
        HStack(spacing: 6) {
            Button("Notes") { showNotes = true }
                .buttonStyle(OutlineButtonStyle())
                .popover(isPresented: $showNotes) { notesList }

            Button(splitView ? "Close LaTeX" : "Split View") {
                withAnimation(.easeInOut(duration: 0.2)) { splitView.toggle() }
            }
            .buttonStyle(OutlineButtonStyle())

            Button("Erase") { confirmErase = true }
                .buttonStyle(FilledButtonStyle(color: .brick))
        }
        .floatingSheet()
    }

    // MARK: - Split view: the handle and the LaTeX panel

    /// The panel can't get narrower than 280 points, or leave the notebook less than 480.
    private func clampedPanelWidth(_ total: CGFloat) -> CGFloat {
        let widest = max(280, total - 480)
        return min(max(panelWidth, 280), widest)
    }

    /// The bar between notebook and panel. Drag it left to widen the panel, right to
    /// narrow it.
    private func splitHandle(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.rule).frame(width: 1)
            Capsule().fill(Color.muted).frame(width: 5, height: 44)
        }
        .frame(width: 18)
        .frame(maxHeight: .infinity)
        .background(Color.sheet)
        .contentShape(Rectangle())                 // the whole strip is grabbable
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = dragStartWidth ?? Double(clampedPanelWidth(totalWidth))
                    dragStartWidth = start
                    // moving left (negative translation) makes the panel wider
                    panelWidth = start - drag.translation.width
                    panelWidth = Double(clampedPanelWidth(totalWidth))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }

    private var latexPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LaTeX")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("Copy") {
                    if model.lineLatex.isEmpty {
                        model.status = "Nothing to copy yet"
                    } else {
                        UIPasteboard.general.string = model.document   // the whole .tex document
                        model.status = "Copied the LaTeX document"
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            symbolChips

            Divider()

            LatexView(lines: model.lineLatex)
                .frame(maxHeight: .infinity)

            Divider()

            // The full document's source (what Copy copies)
            ScrollView {
                Text(model.lineLatex.isEmpty ? "The LaTeX document appears here." : model.document)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.lineLatex.isEmpty ? Color.muted : Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: 260)
            .background(Color(hex: 0xF1F4EC))
        }
        .background(Color.sheet)
    }

    // MARK: - Correcting symbols (chips in the LaTeX panel)

    /// Every symbol as a chip, one row per line. Tap one to pick from the recognizer's
    /// top guesses or type the right LaTeX; the app learns it as a template.
    private var symbolChips: some View {
        let lines = model.lines
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if lines.isEmpty {
                    Text("Symbols appear here. Tap one to correct it.")
                        .font(.footnote)
                        .foregroundStyle(Color.muted)
                }
                ForEach(lines.indices, id: \.self) { n in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(lines[n], id: \.id) { symbol in
                                symbolChip(symbol)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 150)
        .alert("What is this symbol?", isPresented: Binding(
            get: { correcting != nil },
            set: { if !$0 { correcting = nil } }
        )) {
            TextField("LaTeX, e.g. b or \\theta", text: $correctionText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Learn it") {
                if let symbol = correcting { model.correct(symbol.id, to: correctionText) }
                correcting = nil
            }
            Button("Cancel", role: .cancel) { correcting = nil }
        } message: {
            Text("It will be saved as a template, so it's recognized next time.")
        }
    }

    private func symbolChip(_ symbol: Symbol) -> some View {
        Menu {
            // The recognizer's top 3 guesses; the current one is checked
            ForEach(Array(symbol.guesses.prefix(3).enumerated()), id: \.offset) { _, guess in
                Button {
                    model.correct(symbol.id, to: guess.label)
                } label: {
                    if guess.label == symbol.label {
                        Label(guess.label, systemImage: "checkmark")
                    } else {
                        Text(guess.label)
                    }
                }
            }
            Divider()
            Button("Type another…") {
                correctionText = ""
                correcting = symbol
            }
        } label: {
            HStack(spacing: 2) {
                if symbol.role != .normal {             // ^ or _ for scripts
                    Text(symbol.role == .sup ? "^" : "_")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.muted)
                }
                Text(symbol.label)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.ink)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isUnsure(symbol) ? Color(hex: 0xF6E7C8) : Color.white,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.rule))
        }
    }

    /// Unsure symbols are tinted, so you know which chips to check first.
    private func isUnsure(_ symbol: Symbol) -> Bool {
        !isConfident(symbol)
    }

    // MARK: - Notes list (a popover from the Notes button)

    private var notesList: some View {
        NavigationStack {
            List {
                Section("This note") {
                    TextField("Title", text: currentTitle)
                }
                Section("All notes") {
                    ForEach(store.notes) { note in
                        Button {
                            open(note.id)
                            showNotes = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .foregroundStyle(Color.ink)
                                Text(note.modified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(Color.muted)
                            }
                        }
                        .listRowBackground(note.id == currentNote ? Color.padGreenTint : Color.white)
                    }
                    .onDelete { offsets in
                        // look up the ids first: deleting shifts the positions of the rest
                        let ids = offsets.map { store.notes[$0].id }
                        ids.forEach { delete($0) }
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("New Note") {
                    newNote()
                    showNotes = false
                }
            }
        }
        .frame(width: 360, height: 480)
    }

    /// The open note's title, editable in the notes list.
    private var currentTitle: Binding<String> {
        Binding(
            get: { store.notes.first { $0.id == currentNote }?.title ?? "" },
            set: { title in if let id = currentNote { store.rename(id, to: title) } }
        )
    }

    // MARK: - Opening and saving notes

    private func openMostRecentNote() {
        guard currentNote == nil else { return }       // onAppear can run more than once
        if let recent = store.notes.first {
            open(recent.id)
        } else {
            newNote()
        }
    }

    private func newNote() {
        open(store.create().id)
    }

    /// Saves the open note, then shows another. The canvas replays the new note's strokes
    /// into the model, which rebuilds its symbols and LaTeX from scratch.
    private func open(_ id: UUID) {
        saveNow()
        currentNote = id
        model.clearPage()
        latestDrawing = store.drawing(for: id)
        canvasLoad = CanvasLoad(token: canvasLoad.token + 1, drawing: latestDrawing)
    }

    private func delete(_ id: UUID) {
        let wasOpen = id == currentNote
        if wasOpen {
            saveTask?.cancel()                         // don't save a note we're deleting
            currentNote = nil
        }
        store.delete(id)
        if wasOpen { openMostRecentNote() }            // open another (or a fresh one)
    }

    /// Save a second after the last change, so we write once per pause, not per stroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard let id = currentNote else { return }
        store.save(latestDrawing, for: id)
    }

    private func erase() {
        model.clearPage()
        latestDrawing = PKDrawing()
        canvasLoad = CanvasLoad(token: canvasLoad.token + 1, drawing: PKDrawing())
        saveNow()
    }
}

#Preview {
    ContentView()
}
