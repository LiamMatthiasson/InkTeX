// The screen: scrolling notebook pages with the PencilKit canvas on top,
// the pen hotbar at the top, teach controls bottom left, LaTeX and Erase bottom right,
// and the LaTeX panel floating over the right side. (The Swift version of index.html.)

import SwiftUI

struct ContentView: View {
    @State private var model = NoteModel()
    @State private var pen: PenKind = .pen
    @State private var widths: [PenKind: CGFloat] = [:]   // thickness chosen for each pen
    @State private var clearToken = 0      // bump to wipe the canvas
    @State private var label = ""
    @State private var showLatex = false

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
        ZStack {
            // Notebook pages + PencilKit. Scroll with two fingers (one with a mouse/finger
            // when no Pencil is paired); pinch to zoom; two-finger double-tap = undo,
            // three-finger double-tap = redo.
            InkCanvas(
                pen: pen,
                width: width.wrappedValue,
                clearToken: clearToken,
                onStroke: { stroke in
                    model.strokeFinished(stroke.points, startTime: stroke.start, endTime: stroke.end)
                },
                onStrokesReplaced: { strokes in
                    model.replaceStrokes(strokes)
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

            if showLatex {
                HStack {
                    Spacer()
                    latexPanel
                }
                .padding(.top, 90)
                .padding(.bottom, 84)
                .padding(.trailing, 16)
            }
        }
        .onAppear {
            runRecognizerChecks()   // prints ✅/❌ lines in Xcode's console
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

    private var bottomBar: some View {
        HStack(alignment: .center) {
            // Left: teach mode
            HStack(spacing: 6) {
                TextField("Label as LaTeX, e.g. 2 or \\alpha", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(width: 240)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.rule))

                Button("Save") {
                    if model.saveTemplate(label: label) {
                        erase()
                    }
                }
                .buttonStyle(FilledButtonStyle(color: .padGreen))

                // Removes the last saved template (stroke undo is the two-finger double-tap)
                Button("Undo Save") { model.undoTemplate() }
                    .buttonStyle(OutlineButtonStyle())
            }
            .floatingSheet()

            Spacer()

            Text(model.status)
                .font(.footnote)
                .foregroundStyle(Color.muted)

            Spacer()

            // Right: view and erase
            HStack(spacing: 6) {
                Button(showLatex ? "Hide LaTeX" : "Show LaTeX") {
                    showLatex.toggle()
                }
                .buttonStyle(OutlineButtonStyle())

                Button("Erase") { erase() }
                    .buttonStyle(FilledButtonStyle(color: .brick))
            }
            .floatingSheet()
        }
    }

    // MARK: - LaTeX panel

    private var latexPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LaTeX")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("Copy") {
                    if model.latex.isEmpty {
                        model.status = "Nothing to copy yet"
                    } else {
                        UIPasteboard.general.string = model.latex
                        model.status = "Copied LaTeX"
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            LatexView(latex: model.latex)
                .frame(maxHeight: .infinity)

            Divider()

            Text(model.latex.isEmpty ? "The LaTeX code appears here." : model.latex)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(model.latex.isEmpty ? Color.muted : Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: 0xF1F4EC))
        }
        .frame(width: 420)
        .background(Color.sheet)
        .overlay(alignment: .leading) {    // the pad's green margin line
            Rectangle().fill(Color.padGreen).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.rule))
        .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
    }

    // MARK: - Actions

    private func erase() {
        model.clearPage()
        clearToken += 1
    }
}

#Preview {
    ContentView()
}
