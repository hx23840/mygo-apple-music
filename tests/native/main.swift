import Foundation

func decode(_ method: String, _ params: [String: Any]) throws -> Request {
    let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
    return try JSONDecoder().decode(Request.self, from: data)
}
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected an error") } catch {}
}

let library = SongReference.library("i.abc/中文")
let decodedLibrary = try SongReference(encoded: library.encoded)
assert(decodedLibrary == library)
let playlist = SongReference.playlist(playlist: "p.test", entry: "entry:duplicate:1")
let decodedPlaylist = try SongReference(encoded: playlist.encoded)
assert(decodedPlaylist == playlist)
rejects { _ = try SongReference(encoded: "catalog:123") }
rejects { _ = try SongReference(encoded: "am1:not-base64") }
rejects { _ = try decode("play", ["id": "", "position": 0]) }
rejects { _ = try decode("seek", ["position": -1]) }
rejects { _ = try decode("play", ["id": library.encoded, "position": -1]) }

let request = try decode("play", ["id": library.encoded, "position": 100000])
guard case .play(let play) = request.command else { fatalError("Expected play") }
assert(play.id == library.encoded)
let selectedReference = try play.selectedReference()
assert(selectedReference == library)
assert(play.position == 100000)
let invalidStart = try decode("play", ["id": "unavailable-or-video", "position": 0])
guard case .play(let invalidPlay) = invalidStart.command else { fatalError("Expected play") }
rejects { _ = try invalidPlay.selectedReference() }

assert(milliseconds(.nan) == 0)
assert(milliseconds(-1) == 0)
assert(milliseconds(1.234) == 1234)
print("Native identity, queue selection, and protocol validation passed.")

for (page, kind, offset) in [("library:0", LibraryKind.tracks, 0), ("albums:100", .albums, 100), ("artists:20", .artists, 20), ("playlists:0", .playlists, 0)] {
    let request = try decode("browse", ["page": page])
    guard case .browse(let route) = request.command else { fatalError("Expected browse route") }
    assert(route == LibraryRoute(kind: kind, offset: offset))
    assert(route.page == page)
}
for page in ["albums:-1", "albums:1:2", "albums:", "albums:1000001", "catalog:0", "artists:١"] {
    rejects { _ = try decode("browse", ["page": page]) }
}
for method in ["album", "artist"] {
    rejects { _ = try decode(method, ["id": ""]) }
    _ = try decode(method, ["id": "library-native-id"])
}
rejects { _ = try decode("savedAlbums", ["offset": -1]) }
rejects { _ = try decode("search", ["query": "  ", "kind": "albums", "offset": 0]) }
rejects { _ = try decode("search", ["query": "song", "kind": "shows", "offset": 0]) }
rejects { _ = try decode("search", ["query": "song", "kind": "tracks", "offset": -1]) }
let searchRequest = try decode("search", ["query": "  artist  ", "kind": "artists", "offset": 100])
guard case .search(let search) = searchRequest.command else { fatalError("Expected library search") }
assert(search.query == "artist" && search.kind == .artists && search.offset == 100)
let artist = ArtistDTO(id: "artist-id", name: "Artist")
let album = AlbumDTO(id: "album-id", name: "Album", imageUrl: "file:///private/cache/cover.jpg", artists: [artist])
let albumPage = AlbumPageDTO(album: album, tracks: [])
let albumJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(albumPage)) as! [String: Any]
let albumMetadata = albumJSON["album"] as! [String: Any]
assert(albumMetadata["id"] as? String == "album-id")
assert((albumMetadata["artists"] as! [[String: Any]])[0]["id"] as? String == "artist-id")
var section = BrowseDTO.Section(title: "Albums", albums: [album], empty: "Empty")
section.morePage = "albums:100"
let searchJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SearchResultDTO(section: section))) as! [String: Any]
assert(searchJSON["more"] as? Bool == true)
assert((searchJSON["albums"] as? [[String: Any]])?.count == 1)
assert(searchJSON["tracks"] == nil)
print("Library routes, search validation, native IDs, and MyGo collection DTOs passed.")
let restoredID = SongReference.library("i.saved").encoded
let restoredRequest = try decode("tracks", ["ids": [restoredID]])
guard case .tracks(let references) = restoredRequest.command else { fatalError("Expected saved track lookup") }
assert(references.count == 1 && references[0].encoded == restoredID)
rejects { _ = try decode("tracks", ["ids": []]) }
rejects { _ = try decode("tracks", ["ids": ["invalid"]]) }
rejects { _ = try decode("tracks", ["ids": Array(repeating: restoredID, count: 101)]) }
print("Saved track lookup validates identities and request bounds.")
