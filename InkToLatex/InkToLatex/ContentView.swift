// The screen: notebook with pen hotbar and toolbar, and in split view the resizable
// LaTeX panel. Notes autosave a second after the last change.

import SwiftUI
import PencilKit

struct ContentView: View {
    @State private var model = NoteModel()
    @State private var store = NoteStore()

    @State private var currentNote: UUID?
    @State private var canvasLoad = CanvasLoad()
    @State private var latestDrawing = PKDrawing()        // what gets saved
    @State private var saveTask: Task<Void, Never>?

    @State private var pen: PenKind = .pen
    @State private var widths: [PenKind: CGFloat] = [:]

    @State private var label = ""
    @State private var splitView = false
    @AppStorage("latexPanelWidth") private var panelWidth: Double = 420
    @State private var dragStartWidth: Double?
    @State private var showNotes = false
    @State private var showTemplates = false
    @State private var confirmErase = false
    @State private var correcting: Symbol?                 // for "Type another…"
    @State private var correctionText = ""

    @Environment(\.scenePhase) private var scenePhase

    /// The size preview dot, scaled down for big erasers
    private var preview: CGFloat {
        pen == .eraser ? max(6, width.wrappedValue * 30 / 80) : width.wrappedValue
    }

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
            if phase != .active { saveNow() }
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
                        if pen == kind {
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

            HStack(spacing: 10) {
                Slider(value: width, in: pen.widthRange)
                    .frame(width: 130)
                    .tint(Color.padGreen)
                    .id(pen)                          // ranges differ per tool
                ZStack {
                    if pen == .eraser {
                        Circle().stroke(Color.muted, lineWidth: 1.5)
                            .frame(width: preview, height: preview)
                    } else {
                        Circle().fill(pen.color)
                            .frame(width: preview, height: preview)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .padding(.trailing, 8)
        }
        .floatingSheet(cornerRadius: 14)
    }

    // MARK: - Bottom toolbar

    /// One row, or two in a narrow split view.
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

    private var teachControls: some View {
        HStack(spacing: 6) {
            TextField("Last symbol is… e.g. 2 (not ^2)", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(width: 220)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.rule))

            // The label stays filled in, to teach several in a row
            Button("Teach") { _ = model.saveTemplate(label: label) }
            .buttonStyle(FilledButtonStyle(color: .padGreen))

            Button("Undo Teach") { model.undoTemplate() }
                .buttonStyle(OutlineButtonStyle())

            Button("Templates") { showTemplates = true }
                .buttonStyle(OutlineButtonStyle())
                .sheet(isPresented: $showTemplates) { TemplatesView(model: model) }
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

    /// At least 280 pt, leaving the notebook at least 480.
    private func clampedPanelWidth(_ total: CGFloat) -> CGFloat {
        let widest = max(280, total - 480)
        return min(max(panelWidth, 280), widest)
    }

    private func splitHandle(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.rule).frame(width: 1)
            Capsule().fill(Color.muted).frame(width: 5, height: 44)
        }
        .frame(width: 18)
        .frame(maxHeight: .infinity)
        .background(Color.sheet)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = dragStartWidth ?? Double(clampedPanelWidth(totalWidth))
                    dragStartWidth = start
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
                    if model.docBlocks.isEmpty {
                        model.status = "Nothing to copy yet"
                    } else {
                        UIPasteboard.general.string = model.document
                        model.status = "Copied the LaTeX document"
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))

                // Export the note as a .tex file: AirDrop, Files, Mail, upload to Overleaf…
                ShareLink(item: TexFile(name: fileName(for: currentNoteTitle), text: model.document),
                          preview: SharePreview("\(fileName(for: currentNoteTitle)).tex")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(model.docBlocks.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            symbolChips

            Divider()

            LatexView(blocks: model.docBlocks)
                .frame(maxHeight: .infinity)

            Divider()

            ScrollView {
                Text(model.docBlocks.isEmpty ? "The LaTeX document appears here." : model.document)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.docBlocks.isEmpty ? Color.muted : Color.ink)
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

    /// One row of chips per line; tap a chip to correct it.
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
                    let line = lines[n]
                    HStack(spacing: 6) {
                        lineKindMenu(line)
                        if model.kind(of: line) == .text {
                            Text(model.textReading(of: line)?.text ?? "reading…")
                                .font(.callout)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(line.flatMap { $0.children.isEmpty ? [$0] : $0.children },
                                            id: \.id) { symbol in
                                        symbolChip(symbol)
                                    }
                                }
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
                if symbol.role != .normal {
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

    /// Math (ƒ) or text (¶) for a line; tap to overrule.
    private func lineKindMenu(_ line: [Symbol]) -> some View {
        let isText = model.kind(of: line) == .text
        return Menu {
            Button("Read as math") { model.setKind(.math, for: line) }
            Button("Read as text") { model.setKind(.text, for: line) }
            Button("Decide automatically") { model.setKind(nil, for: line) }
        } label: {
            Image(systemName: isText ? "text.alignleft" : "function")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.padGreen)
                .frame(width: 28, height: 26)
                .background(Color.padGreenTint, in: RoundedRectangle(cornerRadius: 6))
        }
    }

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
                        // ids first: deleting shifts positions
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

    /// The open note's title (for the exported file's name).
    private var currentNoteTitle: String {
        store.notes.first { $0.id == currentNote }?.title ?? "Note"
    }

    private var currentTitle: Binding<String> {
        Binding(
            get: { store.notes.first { $0.id == currentNote }?.title ?? "" },
            set: { title in if let id = currentNote { store.rename(id, to: title) } }
        )
    }

    // MARK: - Opening and saving notes

    private func openMostRecentNote() {
        guard currentNote == nil else { return }       // onAppear can run twice
        if let recent = store.notes.first {
            open(recent.id)
        } else {
            newNote()
        }
    }

    private func newNote() {
        open(store.create().id)
    }

    /// Saves the open note and loads another; the canvas replays its strokes into the model.
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
            saveTask?.cancel()
            currentNote = nil
        }
        store.delete(id)
        if wasOpen { openMostRecentNote() }
    }

    /// Once per pause, not per stroke.
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
