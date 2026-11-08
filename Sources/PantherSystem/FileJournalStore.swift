import Foundation
import PantherCore

/// Journal as JSON, written atomically (temp file + rename), owner-only permissions.
public struct FileJournalStore: JournalStore {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("journal.json")
    }

    public static let systemDirectory = URL(fileURLWithPath: "/Library/Application Support/Panther", isDirectory: true)

    public func load() throws(PantherError) -> Journal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let journal = try Self.decoder.decode(Journal.self, from: data)
            guard journal.version <= Journal.currentVersion else {
                throw PantherError.journal("written by a newer Panther (version \(journal.version))")
            }
            return journal
        } catch let error as PantherError {
            throw error
        } catch {
            throw .journal("can't read \(url.path): \(error.localizedDescription)")
        }
    }

    public func save(_ journal: Journal) throws(PantherError) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder.encode(journal)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .journal("can't write \(url.path): \(error.localizedDescription)")
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
