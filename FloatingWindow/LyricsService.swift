import Foundation

struct LyricLine: Equatable, Sendable {
    let time: Double
    let text: String
}

enum LyricsLookupResult: Sendable {
    case synced([LyricLine])
    case instrumental
    case unsynced
    case notFound
}

enum LyricsServiceError: LocalizedError {
    case invalidRequest
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "No pude construir la búsqueda de la letra."
        case .server(let status):
            return "LRCLIB respondió con el código \(status)."
        }
    }
}

private struct LyricsRecord: Decodable, Sendable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsService {
    private static let clientHeader =
        "Wpop/1.0 (https://github.com/EmmanuelCanto/wpop)"

    static func findLyrics(
        artist: String,
        track: String,
        album: String,
        duration: Double
    ) async throws -> LyricsLookupResult {
        let cleanTrack = cleanTrackName(track)
        var fallbackRecords: [LyricsRecord] = []

        if !album.isEmpty, duration > 0,
           let exactURL = makeURL(
               path: "/api/get",
               items: [
                   URLQueryItem(name: "artist_name", value: artist),
                   URLQueryItem(name: "track_name", value: cleanTrack),
                   URLQueryItem(name: "album_name", value: album),
                   URLQueryItem(name: "duration", value: String(format: "%.3f", duration))
               ]
           ),
           let exact: LyricsRecord = try await request(exactURL, allowNotFound: true) {
            fallbackRecords.append(exact)

            if let lines = synchronizedLines(from: exact), !lines.isEmpty {
                return .synced(lines)
            }
        }

        guard let searchURL = makeURL(
            path: "/api/search",
            items: [
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "track_name", value: cleanTrack)
            ]
        ) else {
            throw LyricsServiceError.invalidRequest
        }

        let searchRecords: [LyricsRecord] =
            try await request(searchURL, allowNotFound: false) ?? []
        fallbackRecords.append(contentsOf: searchRecords)

        let ranked = fallbackRecords
            .compactMap { record -> (record: LyricsRecord, score: Int)? in
                guard let score = matchScore(
                    record,
                    artist: artist,
                    track: cleanTrack,
                    album: album,
                    duration: duration
                ) else {
                    return nil
                }
                return (record, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                let leftDifference = abs((lhs.record.duration ?? duration) - duration)
                let rightDifference = abs((rhs.record.duration ?? duration) - duration)
                return leftDifference < rightDifference
            }

        for candidate in ranked {
            if let lines = synchronizedLines(from: candidate.record), !lines.isEmpty {
                return .synced(lines)
            }
        }

        if ranked.first?.record.instrumental == true {
            return .instrumental
        }

        if ranked.contains(where: {
            ($0.record.plainLyrics?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }) {
            return .unsynced
        }

        return .notFound
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let timestampPattern = #"\[(\d{1,3}):(\d{2}(?:[.:]\d{1,3})?)\]"#
        let offsetPattern = #"\[offset:([+-]?\d+)\]"#

        guard let timestampRegex = try? NSRegularExpression(pattern: timestampPattern),
              let offsetRegex = try? NSRegularExpression(
                  pattern: offsetPattern,
                  options: [.caseInsensitive]
              ) else {
            return []
        }

        let wholeLRC = lrc as NSString
        let offsetMatch = offsetRegex.firstMatch(
            in: lrc,
            range: NSRange(location: 0, length: wholeLRC.length)
        )
        let offsetMilliseconds: Double
        if let offsetMatch, offsetMatch.numberOfRanges > 1 {
            offsetMilliseconds =
                Double(wholeLRC.substring(with: offsetMatch.range(at: 1))) ?? 0
        } else {
            offsetMilliseconds = 0
        }

        var parsed: [LyricLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine as NSString
            let fullRange = NSRange(location: 0, length: line.length)
            let matches = timestampRegex.matches(in: rawLine, range: fullRange)
            guard !matches.isEmpty else { continue }

            let text = timestampRegex.stringByReplacingMatches(
                in: rawLine,
                range: fullRange,
                withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            for match in matches where match.numberOfRanges >= 3 {
                let minutes = Double(line.substring(with: match.range(at: 1))) ?? 0
                let secondsText = line
                    .substring(with: match.range(at: 2))
                    .replacingOccurrences(of: ":", with: ".")
                let seconds = Double(secondsText) ?? 0
                let time = max(minutes * 60 + seconds + offsetMilliseconds / 1000, 0)
                parsed.append(LyricLine(time: time, text: text))
            }
        }

        parsed.sort { $0.time < $1.time }

        var merged: [LyricLine] = []
        for line in parsed {
            guard let last = merged.last, abs(last.time - line.time) < 0.001 else {
                merged.append(line)
                continue
            }

            if last.text.isEmpty, !line.text.isEmpty {
                merged[merged.count - 1] = line
            } else if !line.text.isEmpty, line.text != last.text {
                merged[merged.count - 1] = LyricLine(
                    time: last.time,
                    text: "\(last.text)\n\(line.text)"
                )
            }
        }

        return merged
    }

    private static func synchronizedLines(from record: LyricsRecord) -> [LyricLine]? {
        if let synced = record.syncedLyrics,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parseLRC(synced)
        }

        // Algunos registros antiguos guardan marcas LRC dentro de plainLyrics.
        if let plain = record.plainLyrics, plain.contains("[") {
            let lines = parseLRC(plain)
            return lines.isEmpty ? nil : lines
        }

        return nil
    }

    private static func request<T: Decodable>(
        _ url: URL,
        allowNotFound: Bool
    ) async throws -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(clientHeader, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsServiceError.server(0)
        }

        if allowNotFound, httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LyricsServiceError.server(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func makeURL(path: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = items
        return components.url
    }

    private static func matchScore(
        _ record: LyricsRecord,
        artist: String,
        track: String,
        album: String,
        duration: Double
    ) -> Int? {
        let wantedTrack = normalized(track)
        let resultTrack = normalized(record.trackName ?? "")
        let wantedArtist = normalized(artist)
        let resultArtist = normalized(record.artistName ?? "")

        guard !wantedTrack.isEmpty,
              !wantedArtist.isEmpty,
              !resultTrack.isEmpty,
              !resultArtist.isEmpty else {
            return nil
        }

        var score = 0

        if resultTrack == wantedTrack {
            score += 120
        } else if resultTrack.contains(wantedTrack) || wantedTrack.contains(resultTrack) {
            score += 55
        } else {
            return nil
        }

        if resultArtist == wantedArtist {
            score += 100
        } else if resultArtist.contains(wantedArtist) || wantedArtist.contains(resultArtist) {
            score += 55
        } else {
            return nil
        }

        let wantedAlbum = normalized(album)
        let resultAlbum = normalized(record.albumName ?? "")
        if !wantedAlbum.isEmpty, wantedAlbum == resultAlbum {
            score += 30
        }

        if duration > 0, let resultDuration = record.duration {
            switch abs(resultDuration - duration) {
            case ...2.5:
                score += 70
            case ...6:
                score += 45
            case ...15:
                score += 20
            case ...30:
                break
            default:
                // Una versión live, remix o radio edit puede compartir título y
                // artista, pero sus marcas no sirven para esta reproducción.
                return nil
            }
        }

        return score
    }

    private static func cleanTrackName(_ track: String) -> String {
        track
            .replacingOccurrences(
                of: #"\s+-\s+(Single|EP)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: #"\([^)]*\)|\[[^]]*\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b(feat|featuring|ft)\.?\b.*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
