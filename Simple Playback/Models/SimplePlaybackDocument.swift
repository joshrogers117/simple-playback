import SwiftUI
import UniformTypeIdentifiers

struct SimplePlaybackDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.simplePlaybackProject] }
    static var writableContentTypes: [UTType] { [.simplePlaybackProject] }

    var project: PlayoutProject

    init(project: PlayoutProject = .empty) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder.simplePlayback.encode(project)
        return FileWrapper(regularFileWithContents: data)
    }
}

extension JSONEncoder {
    static var simplePlayback: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var simplePlayback: JSONDecoder {
        JSONDecoder()
    }
}
