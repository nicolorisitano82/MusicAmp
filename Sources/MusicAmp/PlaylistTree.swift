import Foundation

/// Artist → album → track view of the playlist (Preferences → Playlist, "Raggruppa per artista e album").
/// Artists and albums appear in the order they first occur; tracks keep playlist order inside them.
/// Albums with several artists go under "Artisti vari"; tracks without an album sit right under their
/// artist; tracks with neither (radio streams) stay plain rows. Playback order is always the playlist's.
struct PlaylistTree {
    struct Node {
        enum Kind { case artist, album }
        let kind: Kind
        let key: String       // stable id for the collapsed set
        let title: String
        var tracks: [Int]     // playlist indices, in order
        var variousArtists = false
    }

    enum Row: Equatable {
        case header(Int)              // index into `nodes`
        case track(Int, depth: Int)   // playlist index
    }

    var nodes: [Node] = []
    var rows: [Row] = []
    /// Row of every track, or of the header that hides it.
    var rowOfTrack: [Int] = []

    static let various = "Artisti vari", unknownArtist = "Artista sconosciuto"

    init() {}

    init(_ tracks: [Track], collapsed: Set<String>) {
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
        // Albums tagged with more than one artist are compilations.
        var albumArtists: [String: Set<String>] = [:]
        for t in tracks { if let al = clean(t.album) { albumArtists[al.lowercased(), default: []].insert(clean(t.artist)?.lowercased() ?? "") } }

        struct AlbumAcc { var title: String; var tracks: [Int] }
        struct ArtistAcc { var title: String; var loose: [Int] = []; var albums: [String: AlbumAcc] = [:]; var albumOrder: [String] = []; var order: [(Bool, String)] = [] }
        var artists: [String: ArtistAcc] = [:]
        var top: [(isArtist: Bool, key: String, track: Int)] = []   // top-level order: artists and plain tracks

        for (i, t) in tracks.enumerated() {
            let album = clean(t.album)
            var artist = clean(t.artist)
            if let al = album, (albumArtists[al.lowercased()]?.count ?? 0) > 1 { artist = PlaylistTree.various }
            if artist == nil, album != nil { artist = PlaylistTree.unknownArtist }
            guard let a = artist else { top.append((false, "", i)); continue }
            let ak = a.lowercased()
            if artists[ak] == nil {
                artists[ak] = ArtistAcc(title: a)
                top.append((true, ak, -1))
            }
            if let al = album {
                let bk = al.lowercased()
                if artists[ak]!.albums[bk] == nil {
                    artists[ak]!.albums[bk] = AlbumAcc(title: al, tracks: [])
                    artists[ak]!.order.append((true, bk))
                }
                artists[ak]!.albums[bk]!.tracks.append(i)
            } else {
                // Album-less tracks of an artist: one block where the first one appeared.
                if artists[ak]!.loose.isEmpty { artists[ak]!.order.append((false, "")) }
                artists[ak]!.loose.append(i)
            }
        }

        rowOfTrack = Array(repeating: 0, count: tracks.count)
        for item in top {
            guard item.isArtist else {
                rowOfTrack[item.track] = rows.count
                rows.append(.track(item.track, depth: 0))
                continue
            }
            let acc = artists[item.key]!
            let artistKey = "a:" + item.key
            let all = acc.order.flatMap { $0.0 ? acc.albums[$0.1]!.tracks : acc.loose }
            let artistNode = nodes.count
            nodes.append(Node(kind: .artist, key: artistKey, title: acc.title, tracks: all, variousArtists: acc.title == PlaylistTree.various))
            let artistRow = rows.count
            rows.append(.header(artistNode))
            let artistOpen = !collapsed.contains(artistKey)
            for (isAlbum, bk) in acc.order {
                if isAlbum {
                    let al = acc.albums[bk]!
                    let key = "b:" + item.key + "|" + bk
                    let n = nodes.count
                    nodes.append(Node(kind: .album, key: key, title: al.title, tracks: al.tracks, variousArtists: acc.title == PlaylistTree.various))
                    let albumRow = rows.count
                    if artistOpen { rows.append(.header(n)) }
                    let open = artistOpen && !collapsed.contains(key)
                    for i in al.tracks {
                        if open { rowOfTrack[i] = rows.count; rows.append(.track(i, depth: 2)) } else { rowOfTrack[i] = artistOpen ? albumRow : artistRow }
                    }
                } else {
                    for i in acc.loose {
                        if artistOpen { rowOfTrack[i] = rows.count; rows.append(.track(i, depth: 1)) } else { rowOfTrack[i] = artistRow }
                    }
                }
            }
        }
    }

    /// The album (or artist) node directly containing a track.
    func parent(of track: Int) -> Int? {
        nodes.indices.last { nodes[$0].tracks.contains(track) && (nodes[$0].kind == .album || !nodes.contains { $0.kind == .album && $0.tracks.contains(track) }) }
    }

    /// Keys of the headers that hide `track` (to open them).
    func hiding(_ track: Int) -> [String] {
        nodes.filter { $0.tracks.contains(track) }.map(\.key)
    }
}
