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
    @State private var currentTrackKey = ""
    @State private var windowTitle = "Lyrics"
    @State private var silenceDuration: Double = 0
    @State private var silenceProgress: Double = 0
    @State private var lastSpotifyPosition: Double = 0
    @State private var lastSyncTime: Date = Date()
    @State private var firstLyricTime: Double = 0
    @State private var isNewTrack = false
    @State private var isPlaying: Bool = false
    @State private var currentLyricIndex: Int = -1
    @State private var basePosition: Double = 0
    @State private var baseTime: Date = Date()
    @State private var lyricTimer: Timer?
    @State private var playbackTimer: Timer?





    func normalizedForMatch(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "feat.", with: "")
            .replacingOccurrences(of: "featuring", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchLyrics(artist: String, track: String, trackKey: String) {
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

                let requestedArtist = self.normalizedForMatch(artist)
                let requestedTrack = self.normalizedForMatch(cleanTrack)

                let exactSyncedMatch = json.first { item in
                    guard let synced = item["syncedLyrics"] as? String,
                          synced.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 else {
                        return false
                    }

                    let resultArtist = self.normalizedForMatch(item["artistName"] as? String ?? "")
                    let resultTrack = self.normalizedForMatch(item["trackName"] as? String ?? "")

                    return resultTrack == requestedTrack &&
                        (resultArtist == requestedArtist ||
                         resultArtist.contains(requestedArtist) ||
                         requestedArtist.contains(resultArtist))
                }

                let firstSyncedMatch = json.first { item in
                    guard let synced = item["syncedLyrics"] as? String else { return false }
                    return synced.trimmingCharacters(in: .whitespacesAndNewlines).count > 10
                }

                let bestMatch = exactSyncedMatch ?? firstSyncedMatch ?? first

                if let synced = bestMatch["syncedLyrics"] as? String,
                   synced.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                    print("✅ Letras cargadas para \(artist) — \(track)")
                    self.parseLRC(synced, trackKey: trackKey)
                    return
                }

                print("⚠️ No encontré letras sincronizadas para \(artist) — \(track)")

                // ... (resto de tu lógica de plainLyrics)
            }
        }.resume()

    }

    func parseLRC(_ lrc: String, trackKey: String) {

        var parsed: [LyricLine] = []
        let lines = lrc.components(separatedBy: "\n")

        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }

        for line in lines {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))

            if !matches.isEmpty {
                let text = regex.stringByReplacingMatches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)

                for match in matches {
                    if match.numberOfRanges >= 3 {
                        let minutesString = nsLine.substring(with: match.range(at: 1))
                        let secondsString = nsLine.substring(with: match.range(at: 2))

                        let minutes = Double(minutesString) ?? 0
                        let seconds = Double(secondsString) ?? 0
                        let time = minutes * 60 + seconds

                        parsed.append(LyricLine(time: time, text: text))
                    }
                }
            }
        }

        parsed.sort(by: { $0.time < $1.time })

        DispatchQueue.main.async {
            guard self.currentTrackKey == trackKey else { return }
            self.lyrics = parsed
            self.firstLyricTime = parsed.first?.time ?? 0   // 🔥 importante
            self.currentLyricIndex = -1
            self.updateLyrics()
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

    func tickLyrics(now: Date = Date()) {
        if isPlaying {
            let elapsed = now.timeIntervalSince(baseTime)
            songPosition = basePosition + elapsed
        }

        updateLyrics()
    }

    func pollPlaybackState() {
        let script = """
        set appState to "NOTHING"
        set appOutput to ""

        try
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is playing then
                        return "PLAYING||" & artist of current track & "||" & name of current track & "||" & player position & "||" & id of current track
                    else if player state is paused then
                        set tempOutput to "PAUSED||" & artist of current track & "||" & name of current track & "||" & player position & "||" & id of current track
                        set appState to "PAUSED"
                        set appOutput to tempOutput
                    end if
                end tell
            end if
        end try

        try
            if application "Music" is running then
                tell application "Music"
                    if player state is playing then
                        return "PLAYING||" & artist of current track & "||" & name of current track & "||" & player position & "||" & (persistent ID of current track as string)
                    else if player state is paused then
                        if appState is "NOTHING" then
                            set tempOutput to "PAUSED||" & artist of current track & "||" & name of current track & "||" & player position & "||" & (persistent ID of current track as string)
                            set appState to "PAUSED"
                            set appOutput to tempOutput
                        end if
                    end if
                end tell
            end if
        end try

        if appState is not "NOTHING" then
            return appOutput
        end if

        return "NOTHING"
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)

        guard let output = appleScript?.executeAndReturnError(&error).stringValue else {
            if let error = error {
                print("AppleScript error:", error)
            }
            isPlaying = false
            return
        }

        if output == "NOTHING" || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let parts = output.components(separatedBy: "||")
        guard parts.count >= 5 else { return }

        let state = parts[0]
        let artist = parts[1]
        let track = parts[2]
        let position = Double(parts[3]) ?? 0
        let trackID = parts[4]
        let trackKey = "\(artist)|\(track)|\(trackID)"

        if state == "PAUSED" {
            if isPlaying {
                print("⏸ Pausado en \(Int(position))s")
                basePosition = position
                songPosition = position
            }
            isPlaying = false
        } else if state == "PLAYING" {
            if !isPlaying {
                print("▶️ Reanudado en \(Int(position))s")
            }
            basePosition = position
            baseTime = Date()
            isPlaying = true
        }

        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.title = "\(artist) — \(track)"
            }
        }

        if trackKey != currentTrackKey {
            print("🎵 Cambió canción: \(track)")

            currentTrackKey = trackKey
            lastSpotifyPosition = position
            songPosition = position
            basePosition = position
            baseTime = Date()

            lyrics = []
            currentLine = "__SILENCE__"
            nextLine = ""
            previousLine = ""
            silenceProgress = 0
            firstLyricTime = 0
            currentLyricIndex = -1

            fetchLyrics(artist: artist, track: track, trackKey: trackKey)
        } else {
            let diff = position - lastSpotifyPosition
            let isBackward = diff < -0.2
            let isForwardJump = diff > 0.5

            if isBackward || isForwardJump {
                print("🎯 MOVIMIENTO DETECTADO → \(String(format: "%.2f", position))s")
                print("📍 Movimiento al segundo \(Int(position))")

                basePosition = position
                baseTime = Date()
                songPosition = position
                currentLyricIndex = -1
            }

            lastSpotifyPosition = position
        }

        updateLyrics()
    }

    func updateLyrics() {
        if lyrics.isEmpty {
            currentLine = "__SILENCE__"
            nextLine = ""
            previousLine = ""
            return
        }


        let delay: Double = 0.5

        // Aplicamos el delay a la posición real
        let adjustedPosition = max(songPosition + delay, 0)

        // Manejo de silencio antes de la primera letra
        if adjustedPosition < firstLyricTime {
            if currentLyricIndex != -1 || currentLine != "__SILENCE__" {
                withAnimation(.easeInOut(duration: 0.35)) {
                    currentLine = "__SILENCE__"
                    nextLine = ""
                    previousLine = ""
                    currentLyricIndex = -1
                }
            }
            silenceProgress = min(adjustedPosition / max(firstLyricTime, 0.1), 1)
            return
        }

        // Buscar la línea actual
        var foundCurrentLine = false

        for i in 0..<lyrics.count {
            if adjustedPosition >= lyrics[i].time {
                if i + 1 < lyrics.count {
                    if adjustedPosition < lyrics[i + 1].time {
                        // Estamos entre la línea i y i+1
                        let newPrevious = i > 0 ? lyrics[i-1].text : ""
                        let newCurrent = lyrics[i].text
                        let newNext = lyrics[i+1].text

                        if i != currentLyricIndex || abs(songPosition - lyrics[i].time) > 0.3 {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                previousLine = newPrevious
                                currentLine = newCurrent
                                nextLine = newNext
                                currentLyricIndex = i
                            }
                        }

                        // Calcular progreso
                        let currentTime = lyrics[i].time
                        let nextTime = lyrics[i+1].time
                        silenceProgress = (adjustedPosition - currentTime) / (nextTime - currentTime)
                        foundCurrentLine = true
                        break
                    }
                } else {
                    // Última línea
                    let newPrevious = lyrics.count > 1 ? lyrics[i-1].text : ""
                    let newCurrent = lyrics[i].text

                    if i != currentLyricIndex {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            previousLine = newPrevious
                            currentLine = newCurrent
                            nextLine = ""
                            currentLyricIndex = i
                        }
                    }

                    silenceProgress = 1
                    foundCurrentLine = true
                    break
                }
            }
        }

        // Si no encontramos ninguna línea (por ejemplo, posición mayor que todas)
        if !foundCurrentLine && !lyrics.isEmpty {
            if adjustedPosition >= lyrics.last?.time ?? 0 {
                // Mostrar última línea
                let lastIndex = lyrics.count - 1
                let newPrevious = lyrics.count > 1 ? lyrics[lastIndex-1].text : ""
                let newCurrent = lyrics[lastIndex].text

                if lastIndex != currentLyricIndex {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        previousLine = newPrevious
                        currentLine = newCurrent
                        nextLine = ""
                        currentLyricIndex = lastIndex
                    }
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

            if currentLine == "__SILENCE__" {
                SilenceDotsView(progress: silenceProgress)
            } else {
                WordAnimatedText(
                    text: currentLine,
                    active: true,
                    animateWords: true
                )
            }

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
        .onAppear {
            lyricTimer?.invalidate()
            playbackTimer?.invalidate()

            lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                self.tickLyrics()
            }

            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                self.pollPlaybackState()
            }

            if let lyricTimer {
                RunLoop.main.add(lyricTimer, forMode: .common)
            }

            if let playbackTimer {
                RunLoop.main.add(playbackTimer, forMode: .common)
            }

            pollPlaybackState()
            tickLyrics()
        }
        .onDisappear {
            lyricTimer?.invalidate()
            playbackTimer?.invalidate()
            lyricTimer = nil
            playbackTimer = nil
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
                .onChange(of: text) {
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
            .onChange(of: text) {
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

    struct SilenceDotsView: View {

        var progress: Double

        var body: some View {

            HStack(spacing: 6) {
                Dot(progress: progress * 3)
                Dot(progress: progress * 3 - 1)
                Dot(progress: progress * 3 - 2)
            }
            .font(.system(size: 28, weight: .bold)) // más grandes
        }
    }

    struct Dot: View {

        var progress: Double

        var body: some View {

            Text(".")
                .opacity(min(max(progress, 0), 1))
                .animation(.linear(duration: 0.15), value: progress)
        }
    }

    struct SizePreferenceKey: PreferenceKey {
        static var defaultValue: CGSize = .zero

        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }
