import SwiftUI
import Combine

struct LyricLine {
    let time: Double
    let text: String
}

struct ContentView: View {

    @State var currentLine = "Abre spotify o apple music"
    @State var nextLine = "Esperando conexión..."
    @State var previousLine = ""
    @State private var lyrics: [LyricLine] = []
    @State private var songPosition: Double = 0
    @State private var currentTrackID = ""
    @State private var windowTitle = "Lyrics"
    
    func fetchLyrics(artist: String, track: String) {
        // Limpieza profunda para mejores resultados en LRCLIB
        let cleanTrack = track
            .replacingOccurrences(of: " - Single", with: "")
            .replacingOccurrences(of: " - EP", with: "")
            .components(separatedBy: " (").first ?? track
        
        let artistQuery = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let trackQuery = cleanTrack.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        let urlString = "https://lrclib.net/api/search?artist_name=\(artistQuery)&track_name=\(trackQuery)"
        
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { return }

            // El resto del código de parseo se mantiene igual...
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first {
                
                if let synced = first["syncedLyrics"] as? String,
                   synced.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                    parseLRC(synced)
                    return
                }
                
                // ... (resto de tu lógica de plainLyrics)
            }
        }.resume()
    
    }
    
    func parseLRC(_ lrc: String) {

        var parsed: [LyricLine] = []

        let lines = lrc.components(separatedBy: "\n")

        for line in lines {

            let parts = line.components(separatedBy: "]")

            if parts.count == 2 {

                let timeString = parts[0].replacingOccurrences(of: "[", with: "")
                let text = parts[1]

                let timeParts = timeString.split(separator: ":")

                if timeParts.count == 2 {

                    let minutes = Double(timeParts[0]) ?? 0
                    let seconds = Double(timeParts[1]) ?? 0

                    let time = minutes * 60 + seconds

                    parsed.append(LyricLine(time: time, text: text))
                }
            }
        }

        DispatchQueue.main.async {
            lyrics = parsed
        }
    }

    func runSpotifyCommand(_ command: String) {

        let script = """
        tell application "Spotify"
            \(command)
        end tell
        """

        var error: NSDictionary?

        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            print(error)
        }
    }
    func updateLyrics() {

        if lyrics.isEmpty {
            currentLine = "..."
            nextLine = ""
            previousLine = ""
            return
        }

        
        let offset = 0.25
        let adjustedPosition = songPosition + offset

        for i in 0..<lyrics.count {

            if adjustedPosition >= lyrics[i].time {

                if i + 1 < lyrics.count && adjustedPosition < lyrics[i + 1].time {

                    let newPrevious = i > 0 ? lyrics[i-1].text : ""
                    let newCurrent = lyrics[i].text
                    let newNext = i + 1 < lyrics.count ? lyrics[i+1].text : ""

                    if newCurrent != currentLine {


                        previousLine = newPrevious
                        currentLine = newCurrent
                        nextLine = newNext
                    }

                    break
                }
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 6) {

            WordAnimatedText(
                text: previousLine,
                active: false,
                animateWords: false
            )

            WordAnimatedText(
                text: currentLine,
                active: true,
                animateWords: true
            )

            WordAnimatedText(
                text: nextLine,
                active: false,
                animateWords: false
            )

        }
        .id(currentLine)
        .transition(.move(edge: .bottom))
        .animation(.easeInOut(duration: 0.35), value: currentLine)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            let script = """
            try
                if application "Spotify" is running then
                    tell application "Spotify"
                        if player state is playing then
                            set trackName to name of current track
                            set artistName to artist of current track
                            set playerPosition to player position
                            set trackID to id of current track
                            return artistName & "||" & trackName & "||" & playerPosition & "||" & trackID
                        end if
                    end tell
                end if
            end try

            try
                if application "Music" is running then
                    tell application "Music"
                        if player state is playing then
                            set trackName to name of current track
                            set artistName to artist of current track
                            set playerPosition to player position
                            set trackID to persistent ID of current track as string
                            return artistName & "||" & trackName & "||" & playerPosition & "||" & trackID
                        end if
                    end tell
                end if
            end try

            return "NOTHING"
            """
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            
            if let output = appleScript?.executeAndReturnError(&error).stringValue {
                if output == "NOTHING" { return }
                
                let parts = output.components(separatedBy: "||")
                if parts.count == 4 {
                    let artist = parts[0]
                    let track = parts[1]
                    let position = Double(parts[2]) ?? 0
                    let trackID = parts[3]

                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first {
                            window.title = "\(artist) — \(track)"
                        }
                    }
                    
                    self.songPosition = position

                    if trackID != currentTrackID {
                        currentTrackID = trackID
                        // Limpiamos la lista de letras antes de buscar la nueva
                        self.lyrics = []
                        fetchLyrics(artist: artist, track: track)
                    }
                    updateLyrics()
                }
            } else if let err = error {
                print("AppleScript Error: \(err)")
            }
        }
        
        }

}


extension Color {
    init(hex: String) {

        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255

        self.init(red: r, green: g, blue: b)
    }
}

struct LyricTextView: View {
    let text: String
    let active: Bool

    @State private var animate = false

    var body: some View {
        Text(text)
            .font(active ? .system(size: 22, weight: .bold) : .system(size: 16))
            .foregroundColor(active ? .white : .white.opacity(0.35))
            .multilineTextAlignment(.leading)
            .lineLimit(nil) // permite múltiples líneas
            .fixedSize(horizontal: false, vertical: true)
            .opacity(animate ? 1 : 0)
            .offset(y: animate ? 0 : -12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) {
                    animate = true
                }
            }
            .onChange(of: text) { newText in
                animate = false
                DispatchQueue.main.async {
                    animate = true
                }
            
            }
    }
}

struct WordAnimatedText: View {
    let text: String
    let active: Bool
    let animateWords: Bool

    @State private var animate = false

    // Separamos las palabras individualmente
    var words: [String] {
        text.split(separator: " ").map { String($0) }
    }

    var body: some View {
        // Usamos un Layout flexible para que las palabras "caigan" al siguiente renglón
        // Si usas iOS 16+ esto es mucho más fácil con Layout
        ZStack {
            // Un contenedor que permite que las palabras se envuelvan automáticamente
            // Usamos un Text con concatenación o un Flow adaptativo
            generateContent()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if animateWords { animate = true }
        }
        .onChange(of: text) { _ in
            if animateWords {
                animate = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    animate = true
                }
            }
        }
    }

    // Esta función crea un "párrafo" de palabras individuales animadas
    @ViewBuilder
    func generateContent() -> some View {
        // El truco aquí es usar un envoltorio que no fuerce una sola línea
        // SwiftUI no tiene un 'Flow' nativo simple pre-iOS 16,
        // pero podemos usar este enfoque de "wrapping":
        
        var width = CGFloat.zero
        var height = CGFloat.zero

        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    Text(word + " ")
                        .font(active ? .system(size: 22, weight: .bold) : .system(size: 16))
                        .foregroundStyle(active ? .white : .white.opacity(0.35))
                        .blur(radius: animateWords ? (animate ? 0 : 5) : 0)
                        .opacity(animateWords ? (animate ? 1 : 0) : 1)
                        .offset(y: animateWords ? (animate ? 0 : 20) : 0)
                        .animation(
                            animateWords ? .easeOut(duration: 0.4).delay(Double(index) * 0.04) : .none,
                            value: animate
                        )
                        .alignmentGuide(.leading, computeValue: { d in
                            if (abs(width - d.width) > geometry.size.width) {
                                width = 0
                                height -= d.height
                            }
                            let result = width
                            if index == words.count - 1 {
                                width = 0 // last item
                            } else {
                                width -= d.width
                            }
                            return result
                        })
                        .alignmentGuide(.top, computeValue: { d in
                            let result = height
                            if index == words.count - 1 {
                                height = 0 // last item
                            }
                            return result
                        })
                }
            }
        }
        .frame(minHeight: 40) // Ajusta según el tamaño de tu fuente
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
