// Notes on disk:
//   Documents/Notes/notes.json        [{ id, title, modified }, ...]
//   Documents/Notes/<id>.drawing      the ink (PKDrawing)
// Only ink is saved; opening a note replays its strokes to rebuild the LaTeX.

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
    private(set) var notes: [NoteInfo] = []   // most recent first

    /// So saving an unchanged note does nothing (and doesn't move it to the top)
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

    func create() -> NoteInfo {
        let title = "Note " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let note = NoteInfo(id: UUID(), title: title, modified: .now)
        notes.insert(note, at: 0)
        saveIndex()
        return note
    }

    func drawing(for id: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(id)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        lastSaved[id] = data
        return drawing
    }

    /// Writes the ink if it changed and moves the note to the top.
    func save(_ drawing: PKDrawing, for id: UUID) {
        let data = drawing.dataRepresentation()
        guard data != lastSaved[id] else { return }
        do {
            try data.write(to: drawingURL(id), options: .atomic)
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
