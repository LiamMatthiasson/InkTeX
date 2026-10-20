// Saving notes. Each note is a PencilKit drawing stored as its own file, plus one small
// index file listing every note's title and when it was last changed:
//
//   Documents/Notes/notes.json        [{ id, title, modified }, ...]
//   Documents/Notes/<id>.drawing      the ink (PKDrawing's own format)
//
// Only the INK is saved, not the LaTeX: opening a note replays its strokes through the
// recognizer, so the LaTeX always reflects your current templates and rules. (The ink
// keeps each stroke's timing, so symbols group exactly as when you wrote them.)

import Foundation
import Observation
import PencilKit

/// One entry in the notes list.
struct NoteInfo: Codable, Identifiable {
    let id: UUID
    var title: String
    var modified: Date
}

@Observable
final class NoteStore {
    /// Every note, most recently changed first.
    private(set) var notes: [NoteInfo] = []

    /// What each note looked like when last saved, so saving an unchanged note does
    /// nothing (just opening a note shouldn't move it to the top of the list).
    private var lastSaved: [UUID: Data] = [:]

    private var folder: URL { URL.documentsDirectory.appending(path: "Notes") }
    private var indexURL: URL { folder.appending(path: "notes.json") }
    private func drawingURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).drawing") }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([NoteInfo].self, from: data) {
            notes = saved.sorted { $0.modified > $1.modified }
        }
    }

    /// A new, empty note at the top of the list.
    func create() -> NoteInfo {
        let title = "Note " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let note = NoteInfo(id: UUID(), title: title, modified: .now)
        notes.insert(note, at: 0)
        saveIndex()
        return note
    }

    /// A note's ink (empty if it has never been saved).
    func drawing(for id: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(id)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        lastSaved[id] = data
        return drawing
    }

    /// Writes a note's ink to disk (if it changed) and moves the note to the top.
    func save(_ drawing: PKDrawing, for id: UUID) {
        let data = drawing.dataRepresentation()
        guard data != lastSaved[id] else { return }
        do {
            try data.write(to: drawingURL(id), options: .atomic)   // all or nothing
            lastSaved[id] = data
            if let i = notes.firstIndex(where: { $0.id == id }) {
                var note = notes.remove(at: i)
                note.modified = .now
                notes.insert(note, at: 0)
            }
            saveIndex()
        } catch {
            print("Couldn't save note: \(error.localizedDescription)")
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].title = title
        saveIndex()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: drawingURL(id))
        notes.removeAll { $0.id == id }
        lastSaved[id] = nil
        saveIndex()
    }

    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Couldn't save the notes list: \(error.localizedDescription)")
        }
    }
}
