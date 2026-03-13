import Foundation

class SpotifyService {
    static func currentTrack() -> (artist: String, track: String)? {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        process.arguments = [
            "-e", "tell application \"Spotify\" to artist of current track",
            "-e", "tell application \"Spotify\" to name of current track"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = output
            .split(separator: "\n")
            .map { String($0) }

        if lines.count >= 2 {
            return (artist: lines[0], track: lines[1])
        }

        return nil
    }
}
