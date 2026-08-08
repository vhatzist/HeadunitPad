import Foundation
import AVFoundation
import MediaPlayer
import UIKit

final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()
    private var isActive = false
    var onRemoteCommand: ((RemoteMediaCommand) -> Void)?
    private var metadata = NowPlayingMetadata.placeholder
    private var playbackState = NowPlayingPlaybackState(isPlaying: true, elapsedSeconds: 0)
    private var keepAlivePlayer: AVQueuePlayer?
    private var keepAliveItem: AVPlayerItem?
    private var keepAliveLooper: AVPlayerLooper?
    private var nowPlayingSession: MPNowPlayingSession?
    private var configuredCommandCenter: MPRemoteCommandCenter?
    private var lastPublishedIsPlaying: Bool?
    private var hasConfiguredAudioSession = false
    private init() {}

    private var activeInfoCenter: MPNowPlayingInfoCenter {
        if #available(iOS 16.0, *) {
            return nowPlayingSession?.nowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default()
        }
        return MPNowPlayingInfoCenter.default()
    }

    private var activeCommandCenter: MPRemoteCommandCenter {
        if #available(iOS 16.0, *) {
            return nowPlayingSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
        }
        return MPRemoteCommandCenter.shared()
    }

    func activate() {
        DispatchQueue.main.async {
            guard !self.isActive else {
                self.updateNowPlayingInfo(metadata: self.metadata, playbackState: self.playbackState)
                return
            }
            self.isActive = true
            self.configureAudioSession()
            self.startSilentPlayback()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            self.configureRemoteCommands()
            self.updateNowPlayingInfo(metadata: self.metadata, playbackState: self.playbackState)
            print("NowPlayingCoordinator: activated")
        }
    }

    func deactivate() {
        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.isActive = false
            self.metadata = .placeholder
            self.playbackState = NowPlayingPlaybackState(isPlaying: true, elapsedSeconds: 0)
            self.lastPublishedIsPlaying = nil
            self.hasConfiguredAudioSession = false
            self.stopSilentPlayback()
            self.clearRemoteCommands()
            self.activeInfoCenter.nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            self.nowPlayingSession = nil
            UIApplication.shared.endReceivingRemoteControlEvents()
            print("NowPlayingCoordinator: deactivated")
        }
    }

    func updateMetadata(_ metadata: NowPlayingMetadata) {
        DispatchQueue.main.async {
            self.metadata = metadata
            guard self.isActive else { return }
            self.updateNowPlayingInfo(metadata: metadata, playbackState: self.playbackState)
        }
    }

    private func configureAudioSession() {
        if hasConfiguredAudioSession {
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            hasConfiguredAudioSession = true
            print("NowPlayingCoordinator: audio session activated for AVRCP")
        } catch {
            print("NowPlayingCoordinator: failed to activate audio session: \(error)")
        }
    }

    private func startSilentPlayback() {
        let player: AVQueuePlayer
        if let keepAlivePlayer {
            player = keepAlivePlayer
        } else {
            guard let url = makeKeepAliveAudioURL() else {
                return
            }
            let item = AVPlayerItem(url: url)
            player = AVQueuePlayer()
            player.actionAtItemEnd = .none
            player.volume = 0.0001
            keepAliveItem = item
            keepAlivePlayer = player

            if #available(iOS 16.0, *) {
                item.nowPlayingInfo = makeNowPlayingInfo(
                    metadata: metadata,
                    playbackState: playbackState
                )
            }

            keepAliveLooper = AVPlayerLooper(player: player, templateItem: item)

            if #available(iOS 16.0, *) {
                configureNowPlayingSession(for: player)
            }
        }
        player.playImmediately(atRate: 1.0)
    }

    @available(iOS 16.0, *)
    private func configureNowPlayingSession(for player: AVPlayer) {
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession = session
        session.becomeActiveIfPossible { [weak self] success in
            print("NowPlayingCoordinator: now playing session active=\(success)")
            guard success else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.configureRemoteCommands()
                self.updateNowPlayingInfo(
                    metadata: self.metadata,
                    playbackState: self.playbackState,
                    forceRepublish: true
                )
            }
        }
    }

    private func stopSilentPlayback() {
        tearDownSilentPlayback()
    }

    private func tearDownSilentPlayback() {
        if #available(iOS 16.0, *) {
            nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
        }

        keepAlivePlayer?.pause()
        keepAlivePlayer?.removeAllItems()
        keepAliveLooper?.disableLooping()
        keepAliveLooper = nil
        keepAlivePlayer = nil
        keepAliveItem = nil
        nowPlayingSession = nil
    }

    private func pauseSilentPlayback() {
        keepAlivePlayer?.pause()
    }

    private func makeKeepAliveAudioURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeadunitPadKeepAliveTone.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let durationSeconds: UInt32 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = sampleRate * UInt32(blockAlign) * durationSeconds
        let riffSize = 36 + dataSize
        let sampleCount = Int(sampleRate * durationSeconds)

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendLittleEndian(riffSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20])
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.appendLittleEndian(dataSize)

        for sampleIndex in 0..<sampleCount {
            let t = Double(sampleIndex) / Double(sampleRate)
            let sine = sin(2.0 * Double.pi * 440.0 * t)
            let sample = Int16(sine * 24.0)
            data.appendLittleEndian(sample)
            data.appendLittleEndian(sample)
        }

        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            print("NowPlayingCoordinator: failed to write silent loop: \(error)")
            return nil
        }
    }

    func updatePlaybackState(_ playbackState: NowPlayingPlaybackState) {
        DispatchQueue.main.async {
            let didChangePlayingState = self.playbackState.isPlaying != playbackState.isPlaying
            self.playbackState = playbackState
            guard self.isActive else { return }

            let shouldPublish = didChangePlayingState

            if playbackState.isPlaying {
                self.configureAudioSession()
                self.startSilentPlayback()
            } else {
                self.pauseSilentPlayback()
            }

            if shouldPublish {
                self.updateNowPlayingInfo(
                    metadata: self.metadata,
                    playbackState: playbackState,
                    forceRepublish: true
                )
            }

            print("NowPlayingCoordinator: playback updated isPlaying=\(playbackState.isPlaying) elapsed=\(playbackState.elapsedSeconds) published=\(shouldPublish)")
        }
    }

    private func configureRemoteCommands() {
        clearRemoteCommands()

        let commandCenter = activeCommandCenter
        configuredCommandCenter = commandCenter

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handle(.play) ?? .commandFailed
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handle(.pause) ?? .commandFailed
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handle(.playPause) ?? .commandFailed
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handle(.next) ?? .commandFailed
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handle(.previous) ?? .commandFailed
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.handle(.stop) ?? .commandFailed
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }

    private func handle(_ command: RemoteMediaCommand) -> MPRemoteCommandHandlerStatus {
        guard isActive else {
            return .commandFailed
        }
        onRemoteCommand?(command)
        applyOptimisticState(for: command)
        print("NowPlayingCoordinator: forwarded remote command \(command)")
        return .success
    }

    private func applyOptimisticState(for command: RemoteMediaCommand) {
        switch command {
        case .play:
            playbackState = NowPlayingPlaybackState(isPlaying: true, elapsedSeconds: playbackState.elapsedSeconds)
            configureAudioSession()
            startSilentPlayback()

        case .pause, .stop:
            playbackState = NowPlayingPlaybackState(isPlaying: false, elapsedSeconds: playbackState.elapsedSeconds)
            pauseSilentPlayback()

        case .playPause:
            playbackState = NowPlayingPlaybackState(
                isPlaying: !playbackState.isPlaying,
                elapsedSeconds: playbackState.elapsedSeconds
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
        let commandCenter = configuredCommandCenter ?? activeCommandCenter

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        configuredCommandCenter = nil
    }

    private func updateNowPlayingInfo(
        metadata: NowPlayingMetadata,
        playbackState: NowPlayingPlaybackState,
        forceRepublish: Bool = false
    ) {
        let info = makeNowPlayingInfo(
            metadata: metadata,
            playbackState: playbackState
        )

        updateRemoteCommandAvailability()

        if forceRepublish || lastPublishedIsPlaying != playbackState.isPlaying {
            activeInfoCenter.nowPlayingInfo = nil
        }

        if #available(iOS 16.0, *) {
            keepAliveItem?.nowPlayingInfo = info
            keepAlivePlayer?.currentItem?.nowPlayingInfo = info
        }

        activeInfoCenter.nowPlayingInfo = info
        lastPublishedIsPlaying = playbackState.isPlaying
    }

    private func makeNowPlayingInfo(
        metadata: NowPlayingMetadata,
        playbackState: NowPlayingPlaybackState
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: metadata.artist,
            MPMediaItemPropertyAlbumTitle: metadata.album,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(playbackState.elapsedSeconds),
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if playbackState.isPlaying {
            info[MPNowPlayingInfoPropertyCurrentPlaybackDate] = Date()
        }

        if let durationSeconds = metadata.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationSeconds)
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = Double(
                max(playbackState.elapsedSeconds + 3600, 3600)
            )
        }

        if let artworkImage = metadata.artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artworkImage.size
            ) { _ in artworkImage }
        }

        return info
    }

    private func updateRemoteCommandAvailability() {
        let commandCenter = configuredCommandCenter ?? activeCommandCenter

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: Int16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}

enum RemoteMediaCommand {
    case play
    case pause
    case playPause
    case next
    case previous
    case stop
}

struct NowPlayingMetadata {
    let title: String
    let artist: String
    let album: String
    let durationSeconds: UInt64?
    let artworkImage: UIImage?

    static let placeholder = NowPlayingMetadata(
        title: "HeadunitPad",
        artist: "Android Auto",
        album: "Projection",
        durationSeconds: nil,
        artworkImage: nil
    )
}

struct NowPlayingPlaybackState {
    let isPlaying: Bool
    let elapsedSeconds: UInt64
} 
