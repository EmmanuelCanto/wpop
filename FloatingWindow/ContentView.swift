import AppKit
import Combine
import SwiftUI

@MainActor
final class LyricsViewModel: ObservableObject {
    static let silenceMarker = "__SILENCE__"

    @Published private(set) var currentLine = "Abre Spotify o Apple Music"
    @Published private(set) var nextLine = "Esperando conexión…"
    @Published private(set) var previousLine = ""
    @Published private(set) var silenceProgress = 0.0

    private var lyrics: [LyricLine] = []
    private var songPosition = 0.0
    private var currentTrackKey = ""
    private var currentLyricIndex = -1
    private var basePosition = 0.0
    private var baseTime = Date()
    private var isPlaying = false
    private var emptyStateLine = "Abre Spotify o Apple Music"
    private var consecutivePlaybackFailures = 0
    private var isRunning = false
    private var latestPlaybackSnapshot: PlaybackSnapshot?

    private var lyricTimer: Timer?
    private var playbackTimer: Timer?
    private var playbackPollTask: Task<Void, Never>?
    private var lyricsFetchTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let lyricTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickLyrics()
            }
        }
        RunLoop.main.add(lyricTimer, forMode: .common)
        self.lyricTimer = lyricTimer

        let playbackTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPlaybackState()
            }
        }
        RunLoop.main.add(playbackTimer, forMode: .common)
        self.playbackTimer = playbackTimer

        pollPlaybackState()
        tickLyrics()
    }

    func stop() {
        isRunning = false
        lyricTimer?.invalidate()
        playbackTimer?.invalidate()
        lyricTimer = nil
        playbackTimer = nil

        playbackPollTask?.cancel()
        lyricsFetchTask?.cancel()
        playbackPollTask = nil
        lyricsFetchTask = nil
    }

    private func pollPlaybackState() {
        guard isRunning, playbackPollTask == nil else { return }

        playbackPollTask = Task { [weak self] in
            guard let self else { return }
            defer { playbackPollTask = nil }

            do {
                let snapshot = try await MusicService.currentPlayback()
                guard !Task.isCancelled else { return }

                consecutivePlaybackFailures = 0
                if let snapshot {
                    applyPlayback(snapshot)
                } else {
                    applyNoPlayer()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                consecutivePlaybackFailures += 1

                // Un fallo aislado de Apple Events no debe romper el reloj.
                if consecutivePlaybackFailures >= 3 {
                    isPlaying = false
                    basePosition = songPosition
                    baseTime = Date()

                    if currentTrackKey.isEmpty {
                        setEmptyState("No pude leer Spotify o Apple Music")
                    }
                }

                print("⚠️ Error consultando el reproductor: \(error.localizedDescription)")
            }
        }
    }

    private func applyPlayback(_ snapshot: PlaybackSnapshot) {
        let trackKey = "\(snapshot.source)|\(snapshot.trackID)"
        let isNewTrack = trackKey != currentTrackKey

        latestPlaybackSnapshot = snapshot
        isPlaying = snapshot.status == .playing
        basePosition = snapshot.position
        baseTime = snapshot.sampledAt
        songPosition = projectedPosition(at: Date())

        if let window = NSApplication.shared.windows.first {
            window.title = "\(snapshot.artist) — \(snapshot.track)"
        }

        if isNewTrack {
            print("🎵 Cambió canción: \(snapshot.artist) — \(snapshot.track)")
            currentTrackKey = trackKey
            resetLyricsForNewTrack()
            fetchLyrics(trackKey: trackKey)
        }

        updateLyrics()
    }

    private func applyNoPlayer() {
        guard !currentTrackKey.isEmpty || isPlaying else { return }

        isPlaying = false
        currentTrackKey = ""
        latestPlaybackSnapshot = nil
        songPosition = 0
        basePosition = 0
        baseTime = Date()
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        lyrics = []
        currentLyricIndex = -1
        emptyStateLine = "Abre Spotify o Apple Music"
        previousLine = ""
        currentLine = emptyStateLine
        nextLine = "Esperando conexión…"
        silenceProgress = 0
        NSApplication.shared.windows.first?.title = "Lyrics"
    }

    private func resetLyricsForNewTrack() {
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        lyrics = []
        currentLyricIndex = -1
        emptyStateLine = "Buscando letra…"
        previousLine = ""
        currentLine = emptyStateLine
        nextLine = ""
        silenceProgress = 0
    }

    private func fetchLyrics(trackKey: String) {
        lyricsFetchTask = Task { [weak self] in
            guard let self else { return }
            defer { lyricsFetchTask = nil }

            // Spotify puede cambiar primero el ID y unos instantes después el
            // resto de los metadatos. Esta espera evita buscar la canción nueva
            // con título, álbum o duración de la anterior.
            let retryDelays: [UInt64] = [
                700_000_000,
                2_000_000_000,
                5_000_000_000
            ]
            var lastError: Error?
            var receivedNoMatch = false

            for (attempt, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      currentTrackKey == trackKey,
                      let snapshot = latestPlaybackSnapshot else {
                    return
                }

                let artist = snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let track = snapshot.track.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artist.isEmpty, !track.isEmpty else {
                    print("⏳ Esperando metadatos completos del reproductor")
                    continue
                }

                let attemptedMetadata = metadataSignature(for: snapshot)

                do {
                    let result = try await LyricsService.findLyrics(
                        artist: artist,
                        track: track,
                        album: snapshot.album,
                        duration: snapshot.duration
                    )

                    guard !Task.isCancelled,
                          currentTrackKey == trackKey,
                          let latestSnapshot = latestPlaybackSnapshot else {
                        return
                    }

                    // Si Spotify corrigió los metadatos mientras LRCLIB
                    // respondía, esa respuesta ya no pertenece a la búsqueda
                    // válida y debe descartarse.
                    guard metadataSignature(for: latestSnapshot) == attemptedMetadata else {
                        print("🔄 Los metadatos cambiaron; repitiendo búsqueda de letra")
                        setEmptyState("Actualizando búsqueda…")
                        continue
                    }

                    if case .notFound = result {
                        receivedNoMatch = true

                        if attempt < retryDelays.count - 1 {
                            print("🔄 LRCLIB no devolvió letra; reintentando")
                            setEmptyState("Reintentando búsqueda…")
                            continue
                        }
                    }

                    applyLyricsResult(result)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error

                    if attempt < retryDelays.count - 1 {
                        print("🔄 Falló LRCLIB; reintentando: \(error.localizedDescription)")
                        setEmptyState("Reintentando búsqueda…")
                    }
                }
            }

            guard !Task.isCancelled, currentTrackKey == trackKey else { return }

            if receivedNoMatch {
                applyLyricsResult(.notFound)
            } else {
                print("⚠️ Error cargando letras: \(lastError?.localizedDescription ?? "metadatos incompletos")")
                setEmptyState("No pude cargar la letra")
            }
        }
    }

    private func metadataSignature(for snapshot: PlaybackSnapshot) -> String {
        let roundedDuration = Int(snapshot.duration.rounded())
        return [
            snapshot.artist,
            snapshot.track,
            snapshot.album,
            String(roundedDuration)
        ]
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        .joined(separator: "|")
    }

    private func applyLyricsResult(_ result: LyricsLookupResult) {
        switch result {
        case .synced(let lines):
            guard !lines.isEmpty else {
                setEmptyState("No encontré letra sincronizada")
                return
            }

            lyrics = lines
            currentLyricIndex = -1
            emptyStateLine = Self.silenceMarker
            print("✅ Letra sincronizada cargada (\(lines.count) marcas)")
            updateLyrics()

        case .instrumental:
            setEmptyState("Pista instrumental")

        case .unsynced:
            setEmptyState("Esta canción no tiene letra sincronizada")

        case .notFound:
            setEmptyState("No encontré letra sincronizada")
        }
    }

    private func setEmptyState(_ message: String) {
        lyrics = []
        currentLyricIndex = -1
        emptyStateLine = message
        previousLine = ""
        currentLine = message
        nextLine = ""
        silenceProgress = 0
    }

    private func tickLyrics(now: Date = Date()) {
        songPosition = projectedPosition(at: now)
        updateLyrics()
    }

    private func projectedPosition(at date: Date) -> Double {
        guard isPlaying else { return basePosition }
        return max(basePosition + max(date.timeIntervalSince(baseTime), 0), 0)
    }

    private func updateLyrics() {
        guard !lyrics.isEmpty else {
            if currentLine != emptyStateLine {
                previousLine = ""
                currentLine = emptyStateLine
                nextLine = ""
            }
            return
        }

        // La posición del reproductor ya es la referencia; no se añade un
        // adelanto artificial que haga cambiar la línea antes de tiempo.
        let position = max(songPosition, 0)
        let index = lyricIndex(at: position)

        guard index >= 0 else {
            let firstTime = max(lyrics.first?.time ?? 0, 0.1)
            silenceProgress = min(max(position / firstTime, 0), 1)
            show(
                index: -1,
                previous: "",
                current: Self.silenceMarker,
                next: nextNonEmptyLine(after: -1)
            )
            return
        }

        let line = lyrics[index]
        let previous = previousNonEmptyLine(before: index)
        let next = nextNonEmptyLine(after: index)

        if line.text.isEmpty {
            let nextTime = lyrics[(index + 1)...].first(where: { !$0.text.isEmpty })?.time
                ?? max(line.time + 1, position)
            let duration = max(nextTime - line.time, 0.1)
            silenceProgress = min(max((position - line.time) / duration, 0), 1)
            show(
                index: index,
                previous: previous,
                current: Self.silenceMarker,
                next: next
            )
        } else {
            show(index: index, previous: previous, current: line.text, next: next)
        }
    }

    private func lyricIndex(at position: Double) -> Int {
        var lowerBound = 0
        var upperBound = lyrics.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lyrics[middle].time <= position {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound - 1
    }

    private func previousNonEmptyLine(before index: Int) -> String {
        guard index > 0 else { return "" }
        return lyrics[..<index].last(where: { !$0.text.isEmpty })?.text ?? ""
    }

    private func nextNonEmptyLine(after index: Int) -> String {
        let start = index + 1
        guard start < lyrics.count else { return "" }
        return lyrics[start...].first(where: { !$0.text.isEmpty })?.text ?? ""
    }

    private func show(index: Int, previous: String, current: String, next: String) {
        guard index != currentLyricIndex ||
                previous != previousLine ||
                current != currentLine ||
                next != nextLine else {
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            currentLyricIndex = index
            previousLine = previous
            currentLine = current
            nextLine = next
        }
    }
}

struct ContentView: View {
    @StateObject private var model = LyricsViewModel()

    var body: some View {
        VStack(spacing: 6) {
            LyricText(
                text: model.previousLine,
                active: false
            )

            if model.currentLine == LyricsViewModel.silenceMarker {
                SilenceDotsView(progress: model.silenceProgress)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            } else {
                LyricText(
                    text: model.currentLine,
                    active: true
                )
            }

            LyricText(
                text: model.nextLine,
                active: false
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

private struct LyricText: View {
    let text: String
    let active: Bool

    @State private var isVisible = true

    var body: some View {
        Text(text)
            .font(active ? .system(size: 22, weight: .bold) : .system(size: 16))
            .foregroundStyle(active ? .white : .white.opacity(0.35))
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                minHeight: active ? 52 : 34,
                alignment: .leading
            )
            .opacity(text.isEmpty ? 0 : (isVisible ? 1 : 0))
            .blur(radius: active && !isVisible ? 3 : 0)
            .offset(y: active && !isVisible ? 8 : 0)
            .onChange(of: text) {
                guard active else {
                    isVisible = true
                    return
                }

                isVisible = false
                withAnimation(.easeOut(duration: 0.22)) {
                    isVisible = true
                }
            }
    }
}

private struct SilenceDotsView: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            Dot(progress: progress * 3)
            Dot(progress: progress * 3 - 1)
            Dot(progress: progress * 3 - 2)
        }
        .font(.system(size: 28, weight: .bold))
    }
}

private struct Dot: View {
    let progress: Double

    var body: some View {
        Text(".")
            .opacity(min(max(progress, 0), 1))
            .animation(.linear(duration: 0.1), value: progress)
    }
}
