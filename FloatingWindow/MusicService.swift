import Foundation

class MusicService {
    static func getCurrentTrack() -> (artist: String, track: String)? {
        let script = """
        try
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is playing then
                        return artist of current track & "|" & name of current track
                    end if
                end tell
            end if
            
            if application "Music" is running then
                tell application "Music"
                    if player state is playing then
                        return artist of current track & "|" & name of current track
                    end if
                end tell
            end if
        end try
        return ""
        """
        
        var error: NSDictionary?
        if let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, output != "" {
            let parts = output.components(separatedBy: "|")
            if parts.count == 2 {
                return (artist: parts[0], track: parts[1])
            }
        }
        return nil
    }
}
