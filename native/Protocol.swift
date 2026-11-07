import Foundation

struct PluginError: Error, Encodable {
    let code: String
    let message: String
    static func invalid(_ message: String) -> PluginError { PluginError(code: "unavailable", message: message) }
}

enum Command {
    case account, signIn, signOut, playlists, pause, resume, state, diagnostics, serviceCheck
    case browse(LibraryRoute), playlist(String), album(String), artist(String), search(LibrarySearch), savedAlbums(Int), tracks([SongReference]), play(Play), seek(Int)

    struct Play: Decodable {
        let id: String
        let position: Int
        func selectedReference() throws -> SongReference { try SongReference(encoded: id) }
    }

    var mutates: Bool {
        switch self {
        case .signIn, .signOut, .play, .pause, .resume, .seek: return true
        default: return false
        }
    }
}

struct Request: Decodable {
    let id: Int
    let command: Command
    enum Keys: String, CodingKey { case id, method, params }
    struct Page: Decodable { let page: String }
    struct Identifier: Decodable { let id: String }
    struct Identifiers: Decodable { let ids: [String] }
    struct Position: Decodable { let position: Int }
    struct Offset: Decodable { let offset: Int }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        id = try data.decode(Int.self, forKey: .id)
        guard id >= 0, id <= 9_007_199_254_740_991 else { throw PluginError.invalid("Invalid request ID.") }
        switch try data.decode(String.self, forKey: .method) {
        case "account": command = .account
        case "signIn": command = .signIn
        case "signOut": command = .signOut
        case "playlists": command = .playlists
        case "pause": command = .pause
        case "resume": command = .resume
        case "state": command = .state
        case "diagnostics": command = .diagnostics
        case "serviceCheck": command = .serviceCheck
        case "browse": command = .browse(try LibraryRoute(page: data.decode(Page.self, forKey: .params).page))
        case "album": command = .album(try Self.identifier(data))
        case "artist": command = .artist(try Self.identifier(data))
        case "search": command = .search(try data.decode(LibrarySearch.self, forKey: .params))
        case "savedAlbums":
            let offset = try data.decode(Offset.self, forKey: .params).offset
            guard (0...1_000_000).contains(offset) else { throw PluginError.invalid("Invalid album offset.") }
            command = .savedAlbums(offset)
        case "tracks":
            let ids = try data.decode(Identifiers.self, forKey: .params).ids
            guard !ids.isEmpty, ids.count <= 100 else { throw PluginError.invalid("Resolve between one and 100 tracks.") }
            command = .tracks(try ids.map { try SongReference(encoded: $0) })
        case "playlist": command = .playlist(try data.decode(Identifier.self, forKey: .params).id)
        case "play":
            let play = try data.decode(Command.Play.self, forKey: .params)
            guard !play.id.isEmpty, play.id.count <= 8192, play.position >= 0 else {
                throw PluginError.invalid("Playback requires a valid track identifier and a nonnegative position.")
            }
            command = .play(play)
        case "seek":
            let position = try data.decode(Position.self, forKey: .params).position
            guard position >= 0 else { throw PluginError.invalid("Seek position must not be negative.") }
            command = .seek(position)
        default: throw PluginError(code: "unsupported", message: "This Apple Music command is not supported.")
        }
    }
    private static func identifier(_ data: KeyedDecodingContainer<Keys>) throws -> String {
        let value = try data.decode(Identifier.self, forKey: .params).id
        guard !value.isEmpty, value.count <= 2048 else { throw PluginError.invalid("Invalid library item identifier.") }
        return value
    }
}

enum LibraryKind: String, Decodable, CaseIterable {
    case tracks, albums, artists, playlists
    var pagePrefix: String { self == .tracks ? "library" : rawValue }
}

struct LibraryRoute: Equatable {
    let kind: LibraryKind
    let offset: Int
    var page: String { "\(kind.pagePrefix):\(offset)" }
    init(kind: LibraryKind, offset: Int) { self.kind = kind; self.offset = offset }
    init(page: String) throws {
        let parts = page.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = LibraryKind(rawValue: parts[0] == "library" ? "tracks" : String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let offset = Int(parts[1]), (0...1_000_000).contains(offset) else {
            throw PluginError.invalid("Invalid library page.")
        }
        self.init(kind: kind, offset: offset)
    }
}

struct LibrarySearch: Decodable {
    let query: String
    let kind: LibraryKind
    let offset: Int
    enum Keys: String, CodingKey { case query, kind, offset }
    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        query = try data.decode(String.self, forKey: .query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 512 else { throw PluginError.invalid("Enter a search query of up to 512 characters.") }
        let rawKind = try data.decode(String.self, forKey: .kind)
        guard let kind = LibraryKind(rawValue: rawKind) else { throw PluginError(code: "unsupported", message: "Search supports library songs, albums, artists and playlists.") }
        self.kind = kind
        offset = try data.decode(Int.self, forKey: .offset)
        guard (0...1_000_000).contains(offset) else { throw PluginError.invalid("Invalid search offset.") }
    }
}

struct ResultEnvelope<T: Encodable>: Encodable { let id: Int; let result: T }
struct ErrorEnvelope: Encodable, Sendable { let id: Int; let error: PluginError }

enum Output {
    static func result<T: Encodable>(_ id: Int, _ result: T) {
        send(ResultEnvelope(id: id, result: result))
    }
    static func error(_ id: Int, _ error: Error) {
        let error = error as? PluginError ?? PluginError(code: "unavailable", message: "Apple Music could not complete the request: \(error.localizedDescription)")
        send(ErrorEnvelope(id: id, error: error))
    }
    private static func send<T: Encodable>(_ value: T) {
        do {
            var data = try JSONEncoder().encode(value)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("Unable to write protocol response.\n".utf8))
            exit(1)
        }
    }
}

enum SongReference: Equatable, Sendable {
    case library(String)
    case playlist(playlist: String, entry: String)

    var encoded: String {
        let fields: [String]
        switch self {
        case .library(let id): fields = ["library", id]
        case .playlist(let playlist, let entry): fields = ["playlist", playlist, entry]
        }
        return "am1:" + (try! JSONEncoder().encode(fields)).base64EncodedString()
    }

    init(encoded: String) throws {
        guard encoded.count <= 8192, encoded.hasPrefix("am1:"),
              let data = Data(base64Encoded: String(encoded.dropFirst(4))),
              let fields = try? JSONDecoder().decode([String].self, from: data),
              fields.allSatisfy({ !$0.isEmpty && $0.count <= 2048 }) else {
            throw PluginError.invalid("Invalid Apple Music track identifier.")
        }
        switch (fields.first, fields.count) {
        case ("library", 2): self = .library(fields[1])
        case ("playlist", 3): self = .playlist(playlist: fields[1], entry: fields[2])
        default: throw PluginError.invalid("Unsupported Apple Music track identifier.")
        }
    }
}

struct ArtistDTO: Encodable, Sendable {
    let id: String
    let name: String
    let imageUrl: String?
    init(id: String = "", name: String, imageUrl: String? = nil) { self.id = id; self.name = name; self.imageUrl = imageUrl }
}
struct AlbumDTO: Encodable, Sendable {
    let id: String
    let name: String
    let imageUrl: String?
    let artists: [ArtistDTO]
    let released: String?
    init(id: String = "", name: String, imageUrl: String?, artists: [ArtistDTO] = [], released: String? = nil) {
        self.id = id; self.name = name; self.imageUrl = imageUrl; self.artists = artists; self.released = released
    }
}
struct AlbumPageDTO: Encodable, Sendable { let album: AlbumDTO; let tracks: [TrackDTO] }
struct ArtistPageDTO: Encodable, Sendable { let artist: ArtistDTO; let albums: [AlbumDTO]; let tracks: [TrackDTO] }
struct SearchResultDTO: Encodable, Sendable {
    let tracks: [TrackDTO]?
    let albums: [AlbumDTO]?
    let artists: [ArtistDTO]?
    let playlists: [PlaylistDTO]?
    let more: Bool
    init(section: BrowseDTO.Section) {
        tracks = section.tracks; albums = section.albums; artists = section.artists; playlists = section.playlists
        more = section.morePage != nil
    }
}
struct TrackDTO: Encodable, Sendable {
    let id: String
    let name: String
    let artists: [ArtistDTO]
    let album: AlbumDTO
    let duration: Int
    let url: String?
    let unavailable: Bool
}
struct PlaylistDTO: Encodable, Sendable {
    let id: String
    let name: String
    let imageUrl: String?
    let description: String?
    let mine = true
    let fixed = true
    let tracks: [TrackDTO]?
    var trackCount: Int? { tracks?.count }
    enum CodingKeys: String, CodingKey { case id, name, imageUrl, description, mine, fixed, tracks, trackCount }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl); try c.encodeIfPresent(description, forKey: .description)
        try c.encode(mine, forKey: .mine); try c.encode(fixed, forKey: .fixed)
        try c.encodeIfPresent(tracks, forKey: .tracks); try c.encodeIfPresent(trackCount, forKey: .trackCount)
    }
}
struct BrowseDTO: Encodable, Sendable {
    let title: String
    let subtitle: String
    let sections: [Section]
    struct Section: Encodable, Sendable {
        let title: String
        var tracks: [TrackDTO]? = nil
        var albums: [AlbumDTO]? = nil
        var artists: [ArtistDTO]? = nil
        var playlists: [PlaylistDTO]? = nil
        var morePage: String? = nil
        let empty: String
    }
}
struct AccountDTO: Encodable, Sendable { let id = "apple-music"; let name = "Apple Music" }
struct StateDTO: Encodable, Sendable { let playing: Bool; let trackId: String; let position: Int; let duration: Int; let device = "MusicKit" }

func milliseconds(_ seconds: TimeInterval?) -> Int {
    guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds * 1000, Double(Int.max / 2)))
}
