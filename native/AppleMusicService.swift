import AppKit
import MusicKit

@MainActor
final class AppleMusicService {
    private let defaults = UserDefaults.standard
    private let artworkCache = ArtworkCache()
    private var player: ApplicationMusicPlayer?
    private var currentTrack: (id: String, duration: Int)?
    private var playlistCache: [String: [Playlist.Entry]] = [:]
    private var songCache: [String: Song] = [:]
    private var songAliases: [String: Song] = [:]
    private var aliasTasks: [String: Task<Song, Error>] = [:]
    private var albumCache: [String: Album] = [:]
    private var missingAlbumIDs: Set<String> = []
    private var albumTasks: [String: Task<Album?, Error>] = [:]
    private struct LibraryCredits {
        var albums: [String: [Artist]] = [:]
        var songs: [String: [Artist]] = [:]
    }
    private var libraryCredits: LibraryCredits?
    private var creditsTask: Task<LibraryCredits?, Never>?
    private var authorizationTask: Task<Void, Never>?
    private let chinese = CommandLine.arguments.contains("zh-CN")

    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    private var connected: Bool {
        get { defaults.bool(forKey: "connected") }
        set { defaults.set(newValue, forKey: "connected"); defaults.synchronize() }
    }
    private func requireConnected() throws {
        guard configured else {
            throw PluginError(code: "setup", message: text("This is a diagnostic build. Build with your local developer signing identity first.", "这是诊断构建。请先使用本机开发者证书签名。"))
        }
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return
        case .notDetermined:
            if authorizationTask == nil {
                authorizationTask = Task { @MainActor in
                    defer { authorizationTask = nil }
                    NSApp.activate(ignoringOtherApps: true)
                    if await MusicAuthorization.request() == .authorized { connected = true }
                }
            }
            throw PluginError(code: "setup", message: text("Allow music access in the MyGo Apple Music permission dialog, then try again.", "请在 MyGo Apple Music 的音乐访问弹窗中点击允许，然后重试。"))
        case .denied, .restricted:
            throw PluginError(code: "setup", message: text("Allow music access in System Settings > Privacy & Security > Media & Apple Music, then try again.", "请在系统设置 > 隐私与安全性 > 媒体与 Apple Music 中允许访问，然后重试。"))
        @unknown default:
            throw PluginError(code: "setup", message: text("Check music access in System Settings > Privacy & Security > Media & Apple Music, then try again.", "请在系统设置 > 隐私与安全性 > 媒体与 Apple Music 中检查访问权限，然后重试。"))
        }
    }
    private func requirePlayer() throws -> ApplicationMusicPlayer {
        try requireConnected()
        guard let player else { throw PluginError.invalid(text("Choose a song first.", "请先选择歌曲。")) }
        return player
    }

    func execute(_ request: Request) async {
        do {
            switch request.command {
            case .diagnostics:
                Output.result(request.id, ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2", "bundleId": Bundle.main.bundleIdentifier ?? "", "configured": configured ? "true" : "false", "minimumOS": "14.0"])
            case .serviceCheck:
                try requireConnected()
                let requestURL = URL(string: "https://api.music.apple.com/v1/test")!
                let response = try await MusicDataRequest(urlRequest: URLRequest(url: requestURL)).response()
                Output.result(request.id, ["statusCode": response.urlResponse.statusCode])
            case .account:
                let account: AccountDTO? = connected && MusicAuthorization.currentStatus == .authorized ? AccountDTO() : nil
                Output.result(request.id, account)
            case .signIn:
                guard configured else {
                    throw PluginError(code: "setup", message: text("This is a diagnostic build. Build with your local developer signing identity first.", "这是诊断构建。请先使用本机开发者证书签名。"))
                }
                NSApp.activate(ignoringOtherApps: true)
                let permission = await MusicAuthorization.request()
                guard permission == .authorized else {
                    throw PluginError(code: "signIn", message: text("Allow music access in System Settings > Privacy & Security > Media & Apple Music.", "请在系统设置 > 隐私与安全性 > 媒体与 Apple Music 中允许访问。"))
                }
                connected = true
                Output.result(request.id, AccountDTO())
            case .signOut:
                shutdown()
                connected = false
                playlistCache.removeAll(); songCache.removeAll(); albumCache.removeAll()
                creditsTask?.cancel(); creditsTask = nil; libraryCredits = nil
                aliasTasks.values.forEach { $0.cancel() }; aliasTasks.removeAll(); songAliases.removeAll()
                albumTasks.values.forEach { $0.cancel() }; albumTasks.removeAll(); missingAlbumIDs.removeAll()
                Output.result(request.id, Optional<String>.none)
            case .browse(let route):
                try requireConnected()
                let section = try await librarySection(route)
                Output.result(request.id, BrowseDTO(title: collectionTitle(route.kind), subtitle: text("Saved in your Apple Music library", "已加入 Apple Music 资料库"), sections: [section]))
            case .savedAlbums(let offset):
                try requireConnected()
                Output.result(request.id, SearchResultDTO(section: try await librarySection(LibraryRoute(kind: .albums, offset: offset))))
            case .album(let id):
                try requireConnected()
                Output.result(request.id, try await albumPage(id))
            case .artist(let id):
                try requireConnected()
                Output.result(request.id, try await artistPage(id))
            case .search(let search):
                try requireConnected()
                let section = try await librarySection(LibraryRoute(kind: search.kind, offset: search.offset), query: search.query)
                Output.result(request.id, SearchResultDTO(section: section))
            case .playlists:
                try requireConnected()
                var query = MusicLibraryRequest<Playlist>(); query.limit = 100
                query.sort(by: \.name, ascending: true)
                let all = try await collect(query.response().items, maximum: 5000)
                Output.result(request.id, try await mapItems(all) { await self.playlist($0, tracks: nil) })
            case .tracks(let references):
                try requireConnected()
                Output.result(request.id, try await mapItems(references) { try await self.resolveTrack($0) })
            case .playlist(let id):
                try requireConnected()
                let result = try await loadPlaylist(id, refresh: true)
                let rows = try await mapItems(result.entries) { entry in
                    try await self.playlistTrack(entry, playlistID: id)
                }
                Output.result(request.id, await playlist(result.playlist, tracks: rows))
            case .play(let params):
                try requireConnected()
                let subscription: MusicSubscription
                do { subscription = try await MusicSubscription.current }
                catch { throw stagedError(error, stage: "MusicSubscription.current") }
                guard subscription.canPlayCatalogContent else {
                    throw PluginError(code: "unavailable", message: text("An active Apple Music subscription is required for full playback.", "播放完整歌曲需要有效的 Apple Music 订阅。"))
                }
                try await play(params)
                Output.result(request.id, Optional<String>.none)
            case .pause:
                try requirePlayer().pause()
                Output.result(request.id, Optional<String>.none)
            case .resume:
                try await requirePlayer().play()
                Output.result(request.id, Optional<String>.none)
            case .seek(let position):
                let player = try requirePlayer()
                player.playbackTime = Double(position) / 1000
                Output.result(request.id, Optional<String>.none)
            case .state:
                try requireConnected()
                guard let player, player.queue.currentEntry != nil, let identity = currentTrack else {
                    Output.result(request.id, Optional<StateDTO>.none)
                    return
                }
                let playing = player.state.playbackStatus == .playing || player.state.playbackStatus == .seekingForward || player.state.playbackStatus == .seekingBackward
                Output.result(request.id, StateDTO(playing: playing, trackId: identity.id, position: milliseconds(player.playbackTime), duration: identity.duration))
            }
        } catch { Output.error(request.id, error) }
    }

    private var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "MyGoMusicKitConfigured") as? Bool == true }

    func shutdown() {
        player?.stop()
        player = nil
        currentTrack = nil
    }

    private func cache(_ song: Song) {
        if songCache.count >= 1000 { songCache.removeAll() }
        songCache[song.id.rawValue] = song
    }

    private func artworkURL(_ artwork: Artwork?, key: String) async -> String? {
        await artworkCache.imageURL(artwork, key: key)
    }

    private func artist(_ artist: Artist) async -> ArtistDTO {
        ArtistDTO(id: artist.id.rawValue, name: artist.name, imageUrl: await artworkURL(artist.artwork, key: "artist:" + artist.id.rawValue))
    }

    private func credits() async -> LibraryCredits? {
        if let libraryCredits { return libraryCredits }
        if let creditsTask { return await creditsTask.value }
        let task = Task { try? await self.readCredits() }
        creditsTask = task
        let result = await task.value
        guard !task.isCancelled else { return nil }
        libraryCredits = result
        creditsTask = nil
        return result
    }

    private func readCredits() async throws -> LibraryCredits {
        var result = LibraryCredits()
        var offset = 0
        repeat {
            try Task.checkCancellation()
            var request = MusicLibrarySectionedRequest<Artist, Album>()
            request.limit = 100; request.offset = offset
            let sections = try await request.response().sections
            for section in sections {
                let artist: Artist = section[dynamicMember: \.self]
                guard !artist.id.rawValue.isEmpty else { continue }
                for album in try await collect(section.items, maximum: 5000) {
                    result.albums[album.id.rawValue, default: []].append(artist)
                }
            }
            guard result.albums.count <= 5000 else { throw PluginError.invalid("Artist metadata exceeds the supported album limit.") }
            if sections.count < 100 { break }
            offset += sections.count
            guard offset < 5000 else { throw PluginError.invalid("Artist metadata exceeds the supported artist limit.") }
        } while true
        offset = 0
        repeat {
            try Task.checkCancellation()
            var request = MusicLibrarySectionedRequest<Artist, Song>()
            request.limit = 100; request.offset = offset
            let sections = try await request.response().sections
            for section in sections {
                let artist: Artist = section[dynamicMember: \.self]
                guard !artist.id.rawValue.isEmpty else { continue }
                let nativeSongs = try await collect(section.items, maximum: 10000)
                for song in nativeSongs { result.songs[song.id.rawValue, default: []].append(artist) }
                // Sectioned queries use numeric IDs; exact-ID lookup returns the library's canonical IDs.
                for start in stride(from: 0, to: nativeSongs.count, by: 100) {
                    var canonical = MusicLibraryRequest<Song>(); canonical.limit = 100
                    canonical.filter(matching: \.id, memberOf: nativeSongs[start..<min(start + 100, nativeSongs.count)].map(\.id))
                    for song in try await collect(canonical.response().items, maximum: 10000) {
                        var artists = result.songs[song.id.rawValue, default: []]
                        if !artists.contains(where: { $0.id == artist.id }) { artists.append(artist) }
                        result.songs[song.id.rawValue] = artists
                    }
                }
            }
            guard result.songs.count <= 20000 else { throw PluginError.invalid("Artist metadata exceeds the supported song limit.") }
            if sections.count < 100 { break }
            offset += sections.count
            guard offset < 5000 else { throw PluginError.invalid("Artist metadata exceeds the supported artist limit.") }
        } while true
        return result
    }

    private func album(_ album: Album) async throws -> AlbumDTO {
        let detailed: Album
        if let cached = albumCache[album.id.rawValue] { detailed = cached }
        else if album.artists == nil { detailed = (try? await album.with(.artists, preferredSource: .library)) ?? album }
        else { detailed = album }
        let date = detailed.releaseDate.map { String(ISO8601DateFormatter().string(from: $0).prefix(10)) }
        var credits: [ArtistDTO] = []
        let relationships = await self.credits()
        let relatedArtists = detailed.artists.map { $0.filter { !$0.id.rawValue.isEmpty } }.flatMap { $0.isEmpty ? nil : $0 }
            ?? relationships?.albums[detailed.id.rawValue] ?? []
        for item in relatedArtists { credits.append(await artist(item)) }
        if credits.isEmpty { credits = [.init(name: detailed.artistName)] }
        let result = AlbumDTO(id: detailed.id.rawValue, name: detailed.title,
                              imageUrl: await artworkURL(detailed.artwork, key: "album:" + detailed.id.rawValue),
                              artists: credits, released: date)
        if albumCache.count >= 1000 { albumCache.removeAll() }
        albumCache[album.id.rawValue] = detailed
        return result
    }

    private func savedAlbum(_ related: Album) async -> Album? {
        let id = related.id.rawValue
        guard !id.isEmpty, !missingAlbumIDs.contains(id) else { return nil }
        if let cached = albumCache[id] { return cached }
        if let task = albumTasks[id] { return try? await task.value }
        let task = Task {
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: related.id)
            return try await request.response().items.first
        }
        albumTasks[id] = task
        defer { albumTasks[id] = nil }
        do {
            let found = try await task.value
            guard !task.isCancelled else { return nil }
            if let found {
                if albumCache.count >= 1000 { albumCache.removeAll() }
                albumCache[id] = found
            } else {
                if missingAlbumIDs.count >= 1000 { missingAlbumIDs.removeAll() }
                missingAlbumIDs.insert(id)
            }
            return found
        } catch { return nil }
    }

    private func track(_ song: Song, reference: SongReference, knownAlbum: AlbumDTO? = nil) async throws -> TrackDTO {
        let detailed: Song
        if let cached = songCache[song.id.rawValue], cached.artists != nil, cached.albums != nil {
            detailed = cached
        } else {
            detailed = (try? await song.with(.albums, .artists, preferredSource: .library)) ?? song
            cache(detailed)
        }
        let albumDTO: AlbumDTO
        if let knownAlbum { albumDTO = knownAlbum }
        else if let related = detailed.albums?.first, let saved = await savedAlbum(related) { albumDTO = try await album(saved) }
        else { albumDTO = AlbumDTO(name: detailed.albumTitle ?? "", imageUrl: await artworkURL(detailed.artwork, key: "song:" + detailed.id.rawValue)) }
        var credits: [ArtistDTO] = []
        let relationships = await self.credits()
        let relatedArtists = detailed.artists.map { $0.filter { !$0.id.rawValue.isEmpty } }.flatMap { $0.isEmpty ? nil : $0 }
            ?? relationships?.songs[detailed.id.rawValue] ?? relationships?.songs[song.id.rawValue] ?? []
        for item in relatedArtists { credits.append(await artist(item)) }
        if credits.isEmpty { credits = [.init(name: detailed.artistName)] }
        return TrackDTO(id: reference.encoded, name: detailed.title,
                        artists: credits,
                        album: albumDTO, duration: milliseconds(detailed.duration), url: detailed.url?.absoluteString,
                        unavailable: detailed.playParameters == nil)
    }

    private func playlistTrack(_ entry: Playlist.Entry, playlistID: String) async throws -> TrackDTO {
        let reference = SongReference.playlist(playlist: playlistID, entry: entry.id.rawValue)
        if case .song(let song) = entry.item {
            if let canonical = try? await canonicalSong(song) {
                return try await track(canonical, reference: .library(canonical.id.rawValue))
            }
            return try await track(song, reference: reference)
        }
        return TrackDTO(id: reference.encoded, name: entry.title, artists: [.init(name: entry.artistName)],
                        album: .init(name: entry.albumTitle ?? "", imageUrl: await artworkURL(entry.artwork, key: "entry:" + entry.id.rawValue)),
                        duration: milliseconds(entry.duration), url: entry.url?.absoluteString, unavailable: true)
    }

    private func mapItems<T: Sendable, R: Sendable>(_ items: [T], transform: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        var rows: [R] = []
        for start in stride(from: 0, to: items.count, by: 8) {
            let batch = Array(items[start..<min(start + 8, items.count)])
            let results = try await withThrowingTaskGroup(of: (Int, R).self) { group in
                for (index, item) in batch.enumerated() { group.addTask { (index, try await transform(item)) } }
                var results: [(Int, R)] = []
                for try await item in group { results.append(item) }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            rows.append(contentsOf: results)
        }
        return rows
    }

    private func canonicalSong(_ song: Song) async throws -> Song {
        if let cached = songAliases[song.id.rawValue] { return cached }
        if let task = aliasTasks[song.id.rawValue] { return try await task.value }
        let task = Task {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: song.id)
            guard let canonical = try await request.response().items.first else {
                throw PluginError.invalid("This song is no longer in your Apple Music library.")
            }
            return canonical
        }
        aliasTasks[song.id.rawValue] = task
        do {
            let canonical = try await task.value
            guard !task.isCancelled else { throw CancellationError() }
            if songAliases.count >= 2000 { songAliases.removeAll() }
            songAliases[song.id.rawValue] = canonical
            songAliases[canonical.id.rawValue] = canonical
            aliasTasks[song.id.rawValue] = nil
            return canonical
        } catch {
            aliasTasks[song.id.rawValue] = nil
            throw error
        }
    }

    private func tracks(_ songs: [Song], album: AlbumDTO? = nil) async throws -> [TrackDTO] {
        try await mapItems(songs) { song in
            let canonical = try await self.canonicalSong(song)
            return try await self.track(canonical, reference: .library(canonical.id.rawValue), knownAlbum: album)
        }
    }

    private func albums(_ albums: [Album]) async throws -> [AlbumDTO] {
        try await mapItems(albums) { try await self.album($0) }
    }

    private func collectionTitle(_ kind: LibraryKind) -> String {
        switch kind {
        case .tracks: return text("Songs", "歌曲")
        case .albums: return text("Albums", "专辑")
        case .artists: return text("Artists", "音乐人")
        case .playlists: return text("Playlists", "歌单")
        }
    }

    private func librarySection(_ route: LibraryRoute, query: String? = nil) async throws -> BrowseDTO.Section {
        var section = BrowseDTO.Section(title: collectionTitle(route.kind), empty: text("No matching items in your Apple Music library.", "Apple Music 资料库中没有符合条件的内容。"))
        func continuation<T: MusicItem>(_ items: MusicItemCollection<T>) -> String? {
            items.hasNextBatch ? LibraryRoute(kind: route.kind, offset: route.offset + items.count).page : nil
        }
        switch route.kind {
        case .tracks:
            var request = MusicLibraryRequest<Song>(); request.limit = 100; request.offset = route.offset
            request.sort(by: \.title, ascending: true)
            if let query { request.filter(text: query) }
            let items = try await request.response().items
            section.tracks = try await tracks(Array(items)); section.morePage = continuation(items)
        case .albums:
            var request = MusicLibraryRequest<Album>(); request.limit = 100; request.offset = route.offset
            request.sort(by: \.title, ascending: true)
            if let query { request.filter(text: query) }
            let items = try await request.response().items
            section.albums = try await albums(Array(items)); section.morePage = continuation(items)
        case .artists:
            var request = MusicLibraryRequest<Artist>(); request.limit = 100; request.offset = route.offset
            request.sort(by: \.name, ascending: true)
            if let query { request.filter(text: query) }
            let items = try await request.response().items
            section.artists = try await mapItems(Array(items)) { await self.artist($0) }; section.morePage = continuation(items)
        case .playlists:
            var request = MusicLibraryRequest<Playlist>(); request.limit = 100; request.offset = route.offset
            request.sort(by: \.name, ascending: true)
            if let query { request.filter(text: query) }
            let items = try await request.response().items
            section.playlists = try await mapItems(Array(items)) { await self.playlist($0, tracks: nil) }; section.morePage = continuation(items)
        }
        return section
    }

    private func albumPage(_ id: String) async throws -> AlbumPageDTO {
        var request = MusicLibraryRequest<Album>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first else { throw PluginError.invalid("This album is no longer in your Apple Music library.") }
        var songs = MusicLibraryRequest<Song>(); songs.limit = 100
        songs.filter(matching: \.albums, contains: found)
        let all = try await collect(songs.response().items, maximum: 10000)
        let ordered = all.enumerated().sorted {
            let lhs = ($0.element.discNumber ?? 1, $0.element.trackNumber ?? Int.max, $0.offset)
            let rhs = ($1.element.discNumber ?? 1, $1.element.trackNumber ?? Int.max, $1.offset)
            return lhs < rhs
        }.map { $0.element }
        let metadata = try await album(found)
        return AlbumPageDTO(album: metadata, tracks: try await tracks(ordered, album: metadata))
    }

    private func artistPage(_ id: String) async throws -> ArtistPageDTO {
        var request = MusicLibraryRequest<Artist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first else { throw PluginError.invalid("This artist is no longer in your Apple Music library.") }
        var albumRequest = MusicLibraryRequest<Album>(); albumRequest.limit = 100
        albumRequest.filter(matching: \.artists, contains: found); albumRequest.sort(by: \.title, ascending: true)
        var songRequest = MusicLibraryRequest<Song>(); songRequest.limit = 100
        songRequest.filter(matching: \.artists, contains: found); songRequest.sort(by: \.title, ascending: true)
        let allAlbums = try await collect(albumRequest.response().items, maximum: 5000)
        let allSongs = try await collect(songRequest.response().items, maximum: 10000)
        return ArtistPageDTO(artist: await artist(found), albums: try await albums(allAlbums), tracks: try await tracks(allSongs))
    }

    private func playlist(_ playlist: Playlist, tracks: [TrackDTO]?) async -> PlaylistDTO {
        PlaylistDTO(id: playlist.id.rawValue, name: playlist.name, imageUrl: await artworkURL(playlist.artwork, key: "playlist:" + playlist.id.rawValue),
                    description: playlist.standardDescription, tracks: tracks)
    }

    private func collect<T: MusicItem & Decodable>(_ initial: MusicItemCollection<T>, maximum: Int) async throws -> [T] {
        var batch = initial
        var all = Array(batch)
        while batch.hasNextBatch {
            guard all.count < maximum else { throw PluginError.invalid("This collection exceeds the supported \(maximum)-item limit.") }
            guard let next = try await batch.nextBatch(limit: 100), !next.isEmpty else {
                throw PluginError.invalid("Apple Music returned an incomplete collection. Please retry.")
            }
            all.append(contentsOf: next); batch = next
        }
        guard all.count <= maximum else { throw PluginError.invalid("This collection exceeds the supported \(maximum)-item limit.") }
        return all
    }

    private func loadPlaylist(_ id: String, refresh: Bool) async throws -> (playlist: Playlist, entries: [Playlist.Entry]) {
        guard !id.isEmpty, id.count <= 2048 else { throw PluginError.invalid("Invalid playlist ID.") }
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first else {
            throw PluginError(code: "unavailable", message: "This playlist is no longer in your Apple Music library.")
        }
        if !refresh, let cached = playlistCache[id] { return (found, cached) }
        let detailed = try await found.with(.entries, preferredSource: .library)
        let entries: [Playlist.Entry]
        if let collection = detailed.entries { entries = try await collect(collection, maximum: 10000) }
        else { entries = [] }
        if playlistCache.count >= 4 { playlistCache.removeAll() }
        playlistCache[id] = entries
        return (detailed, entries)
    }

    private func resolveTrack(_ reference: SongReference) async throws -> TrackDTO {
        switch reference {
        case .library(let id):
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            guard let song = try await request.response().items.first else {
                throw PluginError.invalid("This song is unavailable in your Apple Music library.")
            }
            return try await track(song, reference: reference)
        case .playlist(let playlist, let entry):
            let entries = try await loadPlaylist(playlist, refresh: false).entries
            guard let item = entries.first(where: { $0.id.rawValue == entry }), case .song(let song) = item.item else {
                throw PluginError.invalid("This playlist entry is unavailable or is not an audio song.")
            }
            return try await track(song, reference: reference)
        }
    }

    private func play(_ params: Command.Play) async throws {
        let reference = try params.selectedReference()
        let entry: MusicPlayer.Queue.Entry
        let duration: Int
        switch reference {
        case .library(let id):
            var song = songCache[id]
            if song == nil {
                var request = MusicLibraryRequest<Song>()
                request.filter(matching: \.id, equalTo: MusicItemID(id))
                song = try await request.response().items.first
            }
            guard let song, song.playParameters != nil else {
                throw PluginError.invalid("This song is unavailable in your Apple Music library.")
            }
            cache(song)
            entry = MusicPlayer.Queue.Entry(song); duration = milliseconds(song.duration)
        case .playlist(let playlist, let id):
            let entries: [Playlist.Entry]
            if let cached = playlistCache[playlist] { entries = cached }
            else { entries = try await loadPlaylist(playlist, refresh: false).entries }
            guard let item = entries.first(where: { $0.id.rawValue == id }), case .song(let song) = item.item, song.playParameters != nil else {
                throw PluginError.invalid("This playlist entry is unavailable or is not an audio song. Refresh the playlist.")
            }
            entry = MusicPlayer.Queue.Entry(song); duration = milliseconds(song.duration)
        }
        let player = self.player ?? ApplicationMusicPlayer.shared
        self.player = player
        currentTrack = nil
        player.stop()
        player.state.shuffleMode = .off; player.state.repeatMode = MusicPlayer.RepeatMode.none
        player.queue = ApplicationMusicPlayer.Queue([entry], startingAt: entry)
        do { try await player.prepareToPlay() }
        catch { throw stagedError(error, stage: "prepareToPlay") }
        player.playbackTime = Double(params.position) / 1000
        do { try await player.play() }
        catch { throw stagedError(error, stage: "player.play") }
        currentTrack = (params.id, duration)
    }

    private func stagedError(_ error: Error, stage: String) -> NSError {
        let native = error as NSError
        return NSError(domain: native.domain, code: native.code, userInfo: [
            NSLocalizedDescriptionKey: "\(stage): \(native.localizedDescription) [\(native.domain) \(native.code)]"
        ])
    }
}
