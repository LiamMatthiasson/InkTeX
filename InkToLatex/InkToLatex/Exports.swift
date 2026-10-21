// Files the app can hand to the share sheet (AirDrop, Files, Mail, Overleaf's upload…):
//   TexFile        a note's LaTeX document, as <title>.tex
//   TemplatesFile  your taught templates, as a .json backup (import it on another device,
//                  or after reinstalling: free-account apps expire after 7 days)
//
// `Transferable` is how SwiftUI's ShareLink asks for the file. The file is only written
// when someone actually shares, not every time the screen redraws.

import SwiftUI
import UniformTypeIdentifiers

/// The file types we export. (Inside a nonisolated enum so the share sheet can use them
/// off the main thread.)
nonisolated enum ExportTypes {
    static let tex = UTType(filenameExtension: "tex", conformingTo: .plainText) ?? .plainText
}

/// A note's LaTeX document as a .tex file.
nonisolated struct TexFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: ExportTypes.tex) { file in
            let url = URL.temporaryDirectory.appending(path: "\(file.name).tex")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// Your templates as a .json backup (the same format as the app's templates.json).
nonisolated struct TemplatesFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = URL.temporaryDirectory.appending(path: "InkTeX templates.json")
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// A note title as a file name: no slashes or colons (not allowed in file names).
func fileName(for title: String) -> String {
    let cleaned = title
        .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Note" : cleaned
}
