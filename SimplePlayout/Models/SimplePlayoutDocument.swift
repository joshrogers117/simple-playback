import SwiftUI
import UniformTypeIdentifiers

struct SimplePlayoutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.simplePlayoutProject] }
    static var writableContentTypes: [UTType] { [.simplePlayoutProject] }

    var project: PlayoutProject

    init(project: PlayoutProject = .empty) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try JSONDecoder.simplePlayout.decode(PlayoutProject.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder.simplePlayout.encode(project)
        return FileWrapper(regularFileWithContents: data)
    }
}

extension JSONEncoder {
    static var simplePlayout: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var simplePlayout: JSONDecoder {
        JSONDecoder()
    }
}
