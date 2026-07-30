import Foundation

enum PlaybackStatus: Sendable {
    case playing
    case paused
}

struct PlaybackSnapshot: Sendable {
    let source: String
    let status: PlaybackStatus
    let artist: String
    let track: String
    let album: String
    let duration: Double
    let position: Double
    let trackID: String
    let sampledAt: Date
}

enum MusicServiceError: LocalizedError {
    case appleScriptFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let message):
            return message
        case .malformedResponse:
            return "El reproductor devolvió una respuesta incompleta."
        }
    }
}

enum MusicService {
    private static let fieldSeparator = "\u{001E}"

    private static let playbackScript = """
    set fieldSeparator to ASCII character 30
    set pausedOutput to ""

    try
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing or player state is paused then
                    set playbackState to "PAUSED"
                    if player state is playing then set playbackState to "PLAYING"

                    set trackAlbum to ""
                    try
                        set trackAlbum to album of current track as text
                    end try

                    set trackDuration to 0
                    try
                        set trackDuration to duration of current track
                        if trackDuration > 10000 then set trackDuration to trackDuration / 1000
                    end try

                    set trackIdentifier to ""
                    try
                        set trackIdentifier to id of current track as text
                    end try

                    set trackOutput to "SPOTIFY" & fieldSeparator & playbackState & fieldSeparator & (artist of current track as text) & fieldSeparator & (name of current track as text) & fieldSeparator & trackAlbum & fieldSeparator & (trackDuration as text) & fieldSeparator & (player position as text) & fieldSeparator & trackIdentifier

                    if playbackState is "PLAYING" then return trackOutput
                    set pausedOutput to trackOutput
                end if
            end tell
        end if
    end try

    try
        if application "Music" is running then
            tell application "Music"
                if player state is playing or player state is paused then
                    set playbackState to "PAUSED"
                    if player state is playing then set playbackState to "PLAYING"

                    set trackAlbum to ""
                    try
                        set trackAlbum to album of current track as text
                    end try

                    set trackDuration to 0
                    try
                        set trackDuration to duration of current track
                    end try

                    set trackIdentifier to ""
                    try
                        set trackIdentifier to persistent ID of current track as text
                    end try

                    set trackOutput to "MUSIC" & fieldSeparator & playbackState & fieldSeparator & (artist of current track as text) & fieldSeparator & (name of current track as text) & fieldSeparator & trackAlbum & fieldSeparator & (trackDuration as text) & fieldSeparator & (player position as text) & fieldSeparator & trackIdentifier

                    if playbackState is "PLAYING" then return trackOutput
                    if pausedOutput is "" then set pausedOutput to trackOutput
                end if
            end tell
        end if
    end try

    if pausedOutput is not "" then return pausedOutput
    return "NOTHING"
    """

    static func currentPlayback() async throws -> PlaybackSnapshot? {
        let output = try await runAppleScript(playbackScript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty, output != "NOTHING" else {
            return nil
        }

        let fields = output.components(separatedBy: fieldSeparator)
        guard fields.count >= 8,
              let duration = Double(fields[5]),
              let position = Double(fields[6]) else {
            throw MusicServiceError.malformedResponse
        }

        let identifier = fields[7].isEmpty
            ? "\(fields[0])|\(fields[2])|\(fields[3])|\(fields[4])|\(fields[5])"
            : fields[7]

        return PlaybackSnapshot(
            source: fields[0],
            status: fields[1] == "PLAYING" ? .playing : .paused,
            artist: fields[2],
            track: fields[3],
            album: fields[4],
            duration: duration,
            position: max(position, 0),
            trackID: identifier,
            sampledAt: Date()
        )
    }

    private static func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = standardOutput
            process.standardError = standardError

            process.terminationHandler = { finishedProcess in
                let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

                if finishedProcess.terminationStatus == 0 {
                    continuation.resume(
                        returning: String(data: outputData, encoding: .utf8) ?? ""
                    )
                } else {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: MusicServiceError.appleScriptFailed(
                            message?.isEmpty == false ? message! : "No pude consultar Spotify o Música."
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
