import Foundation
import AVFoundation
import MediaPlayer
import UIKit

final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()

    private var isActive = false

    var onRemoteCommand: ((RemoteMediaCommand) -> Void)?

    private var metadata = NowPlayingMetadata.placeholder

    private var playbackState = NowPlayingPlaybackState(
        isPlaying: true,
        elapsedSeconds: 0
    )

    private var keepAlivePlayer: AVQueuePlayer?
    private var keepAliveLooper: AVPlayerLooper?

    private var configuredCommandCenter: MPRemoteCommandCenter?

    private var lastPublishedIsPlaying: Bool?

    private var hasConfiguredAudioSession = false

    private init() {}

    // MARK: - Activation

    func activate() {
        DispatchQueue.main.async {
            guard !self.isActive else {
                self.updateNowPlayingInfo(
                    metadata: self.metadata,
                    playbackState: self.playbackState
                )
                return
            }

            self.isActive = true

            self.configureAudioSession()
            self.startSilentPlayback()

            UIApplication.shared.beginReceivingRemoteControlEvents()

            self.configureRemoteCommands()

            self.updateNowPlayingInfo(
                metadata: self.metadata,
                playbackState: self.playbackState
            )

            print("NowPlayingCoordinator: activated")
        }
    }

    func deactivate() {
        DispatchQueue.main.async {
            guard self.isActive else {
                return
            }

            self.isActive = false

            self.metadata = .placeholder

            self.playbackState = NowPlayingPlaybackState(
                isPlaying: true,
                elapsedSeconds: 0
            )

            self.lastPublishedIsPlaying = nil
            self.hasConfiguredAudioSession = false

            self.stopSilentPlayback()
            self.clearRemoteCommands()

            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            UIApplication.shared.endReceivingRemoteControlEvents()

            print("NowPlayingCoordinator: deactivated")
        }
    }

    // MARK: - Metadata

    func updateMetadata(_ metadata: NowPlayingMetadata) {
        DispatchQueue.main.async {
            self.metadata = metadata

            guard self.isActive else {
                return
            }

            self.updateNowPlayingInfo(
                metadata: metadata,
                playbackState: self.playbackState
            )
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        guard !hasConfiguredAudioSession else {
            return
        }

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try session.setActive(true)

            hasConfiguredAudioSession = true

            print(
                "NowPlayingCoordinator: audio session activated"
            )
        } catch {
            print(
                "NowPlayingCoordinator: failed to activate audio session: \(error)"
            )
        }
    }

    // MARK: - Keep alive audio

    private func startSilentPlayback() {
        let player: AVQueuePlayer

        if let existingPlayer = keepAlivePlayer {
            player = existingPlayer
        } else {
            guard let url = makeKeepAliveAudioURL() else {
                return
            }

            let item = AVPlayerItem(url: url)

            player = AVQueuePlayer()

            player.actionAtItemEnd = .none

            // Very low volume. The purpose is to keep the audio
            // session alive, not to produce audible sound.
            player.volume = 0.0001

            keepAlivePlayer = player

            keepAliveLooper = AVPlayerLooper(
                player: player,
                templateItem: item
            )
        }

        player.playImmediately(atRate: 1.0)
    }

    private func stopSilentPlayback() {
        keepAlivePlayer?.pause()

        keepAlivePlayer?.removeAllItems()

        keepAliveLooper?.disableLooping()

        keepAliveLooper = nil
        keepAlivePlayer = nil
    }

    private func pauseSilentPlayback() {
        keepAlivePlayer?.pause()
    }

    private func makeKeepAliveAudioURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HeadunitPadKeepAliveTone.wav"
            )

        if FileManager.default.fileExists(
            atPath: url.path
        ) {
            return url
        }

        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let durationSeconds: UInt32 = 1

        let byteRate =
            sampleRate *
            UInt32(channels) *
            UInt32(bitsPerSample / 8)

        let blockAlign =
            channels *
            (bitsPerSample / 8)

        let dataSize =
            sampleRate *
            UInt32(blockAlign) *
            durationSeconds

        let riffSize = 36 + dataSize

        let sampleCount =
            Int(sampleRate * durationSeconds)

        var data = Data()

        // RIFF
        data.append(contentsOf: [
            0x52, 0x49, 0x46, 0x46
        ])

        data.appendLittleEndian(riffSize)

        // WAVE
        data.append(contentsOf: [
            0x57, 0x41, 0x56, 0x45
        ])

        // fmt
        data.append(contentsOf: [
            0x66, 0x6d, 0x74, 0x20
        ])

        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // data
        data.append(contentsOf: [
            0x64, 0x61, 0x74, 0x61
        ])

        data.appendLittleEndian(dataSize)

        for sampleIndex in 0..<sampleCount {
            let t =
                Double(sampleIndex) /
                Double(sampleRate)

            let sine =
                sin(
                    2.0 *
                    Double.pi *
                    440.0 *
                    t
                )

            let sample =
                Int16(sine * 24.0)

            data.appendLittleEndian(sample)
            data.appendLittleEndian(sample)
        }

        do {
            try data.write(
                to: url,
                options: [.atomic]
            )

            return url
        } catch {
            print(
                "NowPlayingCoordinator: failed to write keep-alive audio: \(error)"
            )

            return nil
        }
    }

    // MARK: - Playback state

    func updatePlaybackState(
        _ playbackState: NowPlayingPlaybackState
    ) {
        DispatchQueue.main.async {
            let didChangePlayingState =
                self.playbackState.isPlaying !=
                playbackState.isPlaying

            self.playbackState = playbackState

            guard self.isActive else {
                return
            }

            if playbackState.isPlaying {
                self.configureAudioSession()
                self.startSilentPlayback()
            } else {
                self.pauseSilentPlayback()
            }

            if didChangePlayingState {
                self.updateNowPlayingInfo(
                    metadata: self.metadata,
                    playbackState: playbackState,
                    forceRepublish: true
                )
            }

            print(
                "NowPlayingCoordinator: playback updated " +
                "isPlaying=\(playbackState.isPlaying) " +
                "elapsed=\(playbackState.elapsedSeconds)"
            )
        }
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        clearRemoteCommands()

        let commandCenter =
            MPRemoteCommandCenter.shared()

        configuredCommandCenter = commandCenter

        commandCenter.playCommand.isEnabled = true

        commandCenter.playCommand.addTarget {
            [weak self] _ in

            self?.handle(.play) ?? .commandFailed
        }

        commandCenter.pauseCommand.isEnabled = true

        commandCenter.pauseCommand.addTarget {
            [weak self] _ in

            self?.handle(.pause) ?? .commandFailed
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true

        commandCenter.togglePlayPauseCommand.addTarget {
            [weak self] _ in

            self?.handle(.playPause) ?? .commandFailed
        }

        commandCenter.nextTrackCommand.isEnabled = true

        commandCenter.nextTrackCommand.addTarget {
            [weak self] _ in

            self?.handle(.next) ?? .commandFailed
        }

        commandCenter.previousTrackCommand.isEnabled = true

        commandCenter.previousTrackCommand.addTarget {
            [weak self] _ in

            self?.handle(.previous) ?? .commandFailed
        }

        commandCenter.stopCommand.isEnabled = true

        commandCenter.stopCommand.addTarget {
            [weak self] _ in

            self?.handle(.stop) ?? .commandFailed
        }

        commandCenter.changePlaybackPositionCommand.isEnabled =
            false
    }

    private func handle(
        _ command: RemoteMediaCommand
    ) -> MPRemoteCommandHandlerStatus {
        guard isActive else {
            return .commandFailed
        }

        onRemoteCommand?(command)

        applyOptimisticState(
            for: command
        )

        return .success
    }

    private func applyOptimisticState(
        for command: RemoteMediaCommand
    ) {
        switch command {
        case .play:
            playbackState =
                NowPlayingPlaybackState(
                    isPlaying: true,
                    elapsedSeconds:
                        playbackState.elapsedSeconds
                )

            configureAudioSession()
            startSilentPlayback()

        case .pause, .stop:
            playbackState =
                NowPlayingPlaybackState(
                    isPlaying: false,
                    elapsedSeconds:
                        playbackState.elapsedSeconds
                )

            pauseSilentPlayback()

        case .playPause:
            playbackState =
                NowPlayingPlaybackState(
                    isPlaying:
                        !playbackState.isPlaying,
                    elapsedSeconds:
                        playbackState.elapsedSeconds
                )

            if playbackState.isPlaying {
                configureAudioSession()
                startSilentPlayback()
            } else {
                pauseSilentPlayback()
            }

        case .next, .previous:
            break
        }

        updateNowPlayingInfo(
            metadata: metadata,
            playbackState: playbackState,
            forceRepublish: true
        )
    }

    private func clearRemoteCommands() {
        let commandCenter =
            configuredCommandCenter ??
            MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        configuredCommandCenter = nil
    }

    // MARK: - Now Playing information

    private func updateNowPlayingInfo(
        metadata: NowPlayingMetadata,
        playbackState: NowPlayingPlaybackState,
        forceRepublish: Bool = false
    ) {
        let info =
            makeNowPlayingInfo(
                metadata: metadata,
                playbackState: playbackState
            )

        updateRemoteCommandAvailability()

        let infoCenter =
            MPNowPlayingInfoCenter.default()

        if forceRepublish ||
            lastPublishedIsPlaying !=
            playbackState.isPlaying {

            infoCenter.nowPlayingInfo = nil
        }

        infoCenter.nowPlayingInfo = info

        lastPublishedIsPlaying =
            playbackState.isPlaying
    }

    private func makeNowPlayingInfo(
        metadata: NowPlayingMetadata,
        playbackState: NowPlayingPlaybackState
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:
                metadata.title,

            MPMediaItemPropertyArtist:
                metadata.artist,

            MPMediaItemPropertyAlbumTitle:
                metadata.album,

            MPNowPlayingInfoPropertyPlaybackRate:
                playbackState.isPlaying ? 1.0 : 0.0,

            MPNowPlayingInfoPropertyDefaultPlaybackRate:
                playbackState.isPlaying ? 1.0 : 0.0,

            MPNowPlayingInfoPropertyElapsedPlaybackTime:
                Double(
                    playbackState.elapsedSeconds
                ),

            MPNowPlayingInfoPropertyIsLiveStream:
                false
        ]

        if playbackState.isPlaying {
            info[
                MPNowPlayingInfoPropertyCurrentPlaybackDate
            ] = Date()
        }

        if let durationSeconds =
            metadata.durationSeconds {

            info[
                MPMediaItemPropertyPlaybackDuration
            ] = Double(durationSeconds)

        } else {
            info[
                MPMediaItemPropertyPlaybackDuration
            ] = Double(
                max(
                    playbackState.elapsedSeconds + 3600,
                    3600
                )
            )
        }

        if let artworkImage =
            metadata.artworkImage {

            info[
                MPMediaItemPropertyArtwork
            ] = MPMediaItemArtwork(
                boundsSize: artworkImage.size
            ) { _ in
                artworkImage
            }
        }

        return info
    }

    private func updateRemoteCommandAvailability() {
        let commandCenter =
            configuredCommandCenter ??
            MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLittleEndian(
        _ value: Int16
    ) {
        var littleEndian = value.littleEndian

        append(
            Data(
                bytes: &littleEndian,
                count: MemoryLayout<Int16>.size
            )
        )
    }

    mutating func appendLittleEndian(
        _ value: UInt16
    ) {
        var littleEndian = value.littleEndian

        append(
            Data(
                bytes: &littleEndian,
                count: MemoryLayout<UInt16>.size
            )
        )
    }

    mutating func appendLittleEndian(
        _ value: UInt32
    ) {
        var littleEndian = value.littleEndian

        append(
            Data(
                bytes: &littleEndian,
                count: MemoryLayout<UInt32>.size
            )
        )
    }
}

// MARK: - Remote media commands

enum RemoteMediaCommand {
    case play
    case pause
    case playPause
    case next
    case previous
    case stop
}

// MARK: - Now Playing metadata

struct NowPlayingMetadata {
    let title: String
    let artist: String
    let album: String
    let durationSeconds: UInt64?
    let artworkImage: UIImage?

    static let placeholder =
        NowPlayingMetadata(
            title: "HeadunitPad",
            artist: "Android Auto",
            album: "Projection",
            durationSeconds: nil,
            artworkImage: nil
        )
}

// MARK: - Playback state

struct NowPlayingPlaybackState {
    let isPlaying: Bool
    let elapsedSeconds: UInt64
}
