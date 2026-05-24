//
//  ConnectionManager.swift
//  HeadunitPad
//
//  Manages device discovery and connection lifecycle
//

import Foundation
import AVFoundation
import Network
import UIKit

enum ConnectionState: Equatable {
    case disconnected
    case discovering
    case waitingForWirelessHelper
    case connecting
    case handshaking
    case running
    case error(String)

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .discovering:
            return "Scanning..."
        case .waitingForWirelessHelper:
            return "Waiting for Wireless Helper..."
        case .connecting:
            return "Connecting..."
        case .handshaking:
            return "Handshaking..."
        case .running:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

protocol ConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState)
    func connectionManager(_ manager: ConnectionManager, didUpdateStatus status: String)
    func connectionManager(_ manager: ConnectionManager, didDiscoverDevice device: DiscoveredDevice)
    func connectionManager(_ manager: ConnectionManager, didReceiveVideoData data: Data)
    func connectionManager(_ manager: ConnectionManager, didReceiveAudioData data: Data, on channel: UInt8)
}

class ConnectionManager {
    weak var delegate: ConnectionManagerDelegate?

    private let discovery = Discovery()
    private let tcpHandler = TcpHandler()
    private let wirelessHelperServer = WirelessHelperServer()
    private let microphoneCapture = MicrophoneCapture()
    private let locationCapture = LocationCapture()
    private var aapTransport: AapTransport?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isUserInitiatedDisconnect = false
    private var hasTriggeredWirelessHelper = false
    private var hasReceivedAaMediaMetadata = false
    private let reconnectDelay: TimeInterval = 2.0

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            print("ConnectionManager: state changed from \(oldValue.description) to \(state.description)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.connectionManager(self, didChangeState: self.state)
            }
        }
    }

    private(set) var discoveredDevices: [DiscoveredDevice] = []
    private(set) var connectedDevice: DiscoveredDevice?
    private(set) var statusDetail = "Ready to connect"

    init() {
        discovery.delegate = self
        wirelessHelperServer.delegate = self
        aapTransport = AapTransport(tcpHandler: tcpHandler)
        aapTransport?.delegate = self
        microphoneCapture.onPCMData = { [weak self] data in
            self?.aapTransport?.sendMicrophoneAudioData(data)
        }
        locationCapture.onLocation = { [weak self] location in
            self?.aapTransport?.sendLocationUpdate(location)
        }
        NowPlayingCoordinator.shared.onRemoteCommand = { [weak self] command in
            self?.sendRemoteMediaCommand(command)
        }
    }

    func requestLocationPermissionIfNeeded() {
        guard ProjectionSettings.gpsSource == .ipad else { return }
        guard ProjectionSettings.supportsCellularIpad() else { return }
        locationCapture.requestPermissionIfNeeded()
    }

    func startDiscovery() {
        print("ConnectionManager: startDiscovery called")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isUserInitiatedDisconnect = false
        let canStart: Bool
        switch state {
        case .disconnected, .error:
            canStart = true
        case .waitingForWirelessHelper:
            canStart = true
        default:
            canStart = false
        }

        guard canStart else {
            print("ConnectionManager: Cannot start discovery, current state: \(state.description)")
            return
        }

        discoveredDevices.removeAll()
        hasTriggeredWirelessHelper = false
        state = .discovering

        switch ProjectionSettings.connectionMode {
        case .auto:
            updateStatus("Listening on 5288, scanning for Wireless Helper and Headunit Server...")
            wirelessHelperServer.start()
            discovery.startScan(ports: [Discovery.launcherPort, Discovery.headunitPort])
        case .wirelessHelper:
            updateStatus("Listening on 5288 and looking for Wireless Helper...")
            wirelessHelperServer.start()
            discovery.startScan(ports: [Discovery.launcherPort])
        case .directHeadunit:
            updateStatus("Scanning for Headunit Server on 5277...")
            wirelessHelperServer.stop()
            discovery.startScan(ports: [Discovery.headunitPort])
        }
    }

    func stopDiscovery() {
        print("ConnectionManager: stopDiscovery called")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        discovery.stopScan()
        if state == .discovering || state == .waitingForWirelessHelper {
            state = .disconnected
            updateStatus("Ready to connect")
        }
    }

    func connect(to device: DiscoveredDevice) {
        print("ConnectionManager: connect(to:) called with device: \(device.displayName)")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isUserInitiatedDisconnect = false
        let preparedConnection = discovery.takePreparedConnection(ip: device.ip, port: device.port)
        stopDiscovery()
        state = .connecting
        connectedDevice = device
        updateStatus("Connecting to \(device.displayName)...")
        aapTransport?.configurePeer(host: device.ip, port: device.port)

        if let preparedConnection = preparedConnection {
            print("ConnectionManager: Using prepared connection from discovery for \(device.ip):\(device.port)")
            tcpHandler.adoptConnection(preparedConnection, host: device.ip, port: device.port)
        } else {
            print("ConnectionManager: Calling tcpHandler.connect(host: \(device.ip), port: \(device.port))")
            tcpHandler.connect(host: device.ip, port: device.port)
        }
    }

    func connect(to ip: String, port: UInt16 = 5277) {
        print("ConnectionManager: connect(to:port:) called with ip: \(ip), port: \(port)")
        let device = DiscoveredDevice(ip: ip, port: port, name: nil)
        connect(to: device)
    }

    func disconnect() {
        print("ConnectionManager: disconnect called")
        isUserInitiatedDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        NowPlayingCoordinator.shared.deactivate()
        microphoneCapture.stop()
        locationCapture.stop()
        wirelessHelperServer.stop()
        tcpHandler.disconnect()
        connectedDevice = nil
        state = .disconnected
        updateStatus("Ready to connect")
    }

    func send(_ data: Data) {
        guard state == .running else { return }
        aapTransport?.send(message: AapMessage(channel: 0, flags: 0, type: 0, payload: data))
    }

    func sendTouchEvent(x: Int, y: Int, action: TouchAction) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(x: x, y: y, action: action)
    }

    func sendTouchEvent(pointers: [(id: Int, x: Int, y: Int)], action: TouchAction, actionIndex: Int) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(pointers: pointers, action: action, actionIndex: actionIndex)
    }

    func requestVideoRecovery() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecovery()
    }

    func requestVideoRecoveryForNewDisplay() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecoveryForNewDisplay()
    }

    func sendRemoteMediaCommand(_ command: RemoteMediaCommand) {
        guard state == .running else { return }
        let keyCode: Int
        switch command {
        case .play:
            keyCode = 126
        case .pause:
            keyCode = 127
        case .playPause:
            keyCode = 85
        case .next:
            keyCode = 87
        case .previous:
            keyCode = 88
        case .stop:
            keyCode = 86
        }
        aapTransport?.sendMediaKeyEvent(keyCode: keyCode)
    }

    func diagnosticLines() -> [String] {
        let device = connectedDevice
        return [
            "State: \(state.description)",
            "Status: \(statusDetail)",
            "Mode: \(ProjectionSettings.connectionMode.title)",
            "Auto reconnect: \(ProjectionSettings.autoReconnect ? "On" : "Off")",
            "Local IP: \(localIPv4Address() ?? "Unknown")",
            "Wireless listener: \(wirelessHelperServer.isRunning ? "Listening" : "Stopped")",
            "Wireless listener port: \(WirelessHelperServer.port)",
            "Bonjour service: \(WirelessHelperServer.serviceType)",
            "Audio output: \(currentAudioOutputDescription())",
            "Now Playing owner: \(state == .running ? "HeadunitPad" : "Inactive")",
            "Discovered headunits: \(discoveredDevices.count)",
            "Helper triggered: \(hasTriggeredWirelessHelper ? "Yes" : "No")",
            "Connected device: \(device?.displayName ?? "None")",
            "Connected endpoint: \(device.map { "\($0.ip):\($0.port)" } ?? "None")"
        ]
    }

    private func updateStatus(_ status: String) {
        statusDetail = status
        print("ConnectionManager: status = \(status)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.connectionManager(self, didUpdateStatus: status)
        }
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard ProjectionSettings.autoReconnect else { return }
        guard !isUserInitiatedDisconnect else { return }
        guard reconnectWorkItem == nil else { return }

        updateStatus("\(reason). Reconnecting soon...")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            switch self.state {
            case .disconnected, .error:
                self.startDiscovery()
            default:
                break
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: workItem)
    }

    private func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            defer { current = addr.pointee.ifa_next }

            let name = String(cString: addr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            guard addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr.pointee.ifa_addr,
                socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                return String(cString: hostname)
            }
        }

        return nil
    }

    private func currentAudioOutputDescription() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else {
            return "None"
        }
        return outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }
}

extension ConnectionManager: DiscoveryDelegate {
    func discoveryDidFindDevice(_ device: DiscoveredDevice) {
        if device.port == Discovery.launcherPort {
            print("ConnectionManager: triggered wireless helper launcher at \(device.ip):\(device.port)")
            hasTriggeredWirelessHelper = true
            updateStatus("Wireless Helper triggered at \(device.ip). Waiting for phone...")
            return
        }

        print("ConnectionManager: discovered device: \(device.displayName)")
        discoveredDevices.append(device)
        updateStatus("Found Headunit Server at \(device.ip):\(device.port)")
        delegate?.connectionManager(self, didDiscoverDevice: device)
    }

    func discoveryDidFinish() {
        print("ConnectionManager: discovery finished, found \(discoveredDevices.count) devices")
        if state == .discovering {
            if !discoveredDevices.isEmpty {
                state = .disconnected
                let suffix = discoveredDevices.count == 1 ? "" : "s"
                updateStatus("Found \(discoveredDevices.count) Headunit Server\(suffix)")
                return
            }

            switch ProjectionSettings.connectionMode {
            case .wirelessHelper:
                state = .waitingForWirelessHelper
                updateStatus(hasTriggeredWirelessHelper ? "Waiting for Wireless Helper to connect..." : "Listening on 5288. Open Wireless Helper on the phone.")
            case .auto where wirelessHelperServer.isRunning:
                state = .waitingForWirelessHelper
                updateStatus(hasTriggeredWirelessHelper ? "Waiting for Wireless Helper to connect..." : "No direct server found. Waiting for Wireless Helper on 5288.")
            case .auto, .directHeadunit:
                state = .disconnected
                updateStatus("No devices found")
                scheduleReconnectIfNeeded(reason: "Scan finished")
            }
        }
    }

    func discoveryDidFail(_ error: Error) {
        print("ConnectionManager: discovery failed with error: \(error.localizedDescription)")
        state = .error(error.localizedDescription)
        updateStatus(error.localizedDescription)
        scheduleReconnectIfNeeded(reason: "Discovery failed")
    }
}

extension ConnectionManager: TcpHandlerDelegate {
    func tcpHandlerDidConnect(_ handler: TcpHandler) {
        print("ConnectionManager: TCP connection established")
        state = .handshaking
        updateStatus("TCP connected. Starting Android Auto handshake...")
        aapTransport?.startHandshake()
    }

    func tcpHandler(_ handler: TcpHandler, didFailWithError error: Error) {
        print("ConnectionManager: TCP failed with error: \(error.localizedDescription)")
        state = .error(error.localizedDescription)
        updateStatus(error.localizedDescription)
        scheduleReconnectIfNeeded(reason: "TCP failed")
    }

    func tcpHandler(_ handler: TcpHandler, didReceiveData data: Data) {
    }

    func tcpHandlerDidDisconnect(_ handler: TcpHandler) {
        print("ConnectionManager: TCP disconnected")
        NowPlayingCoordinator.shared.deactivate()
        state = .disconnected
        connectedDevice = nil
        updateStatus("Disconnected")
        scheduleReconnectIfNeeded(reason: "Disconnected")
    }
}

extension ConnectionManager: AapTransportDelegate {
    func aapTransport(_ transport: AapTransport, didRequestMicrophoneCapture isOpen: Bool) {
        if isOpen {
            microphoneCapture.start(sampleRate: 16_000, channels: 1)
        } else {
            microphoneCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didRequestLocationUpdates isEnabled: Bool) {
        if isEnabled {
            locationCapture.start()
        } else {
            locationCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didReceiveVideoData data: Data) {
        delegate?.connectionManager(self, didReceiveVideoData: data)
    }

    func aapTransport(_ transport: AapTransport, didReceiveAudioData data: Data, on channel: UInt8) {
        delegate?.connectionManager(self, didReceiveAudioData: data, on: channel)
    }

    func aapTransport(_ transport: AapTransport, didReceiveMediaMetadata metadata: AapMediaMetadata) {
        hasReceivedAaMediaMetadata = true
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = metadata.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = metadata.albumArt.flatMap { UIImage(data: $0) }

        NowPlayingCoordinator.shared.updateMetadata(
            NowPlayingMetadata(
                title: title?.isEmpty == false ? title! : "Android Auto",
                artist: artist?.isEmpty == false ? artist! : "Unknown Artist",
                album: album?.isEmpty == false ? album! : "Projection",
                durationSeconds: metadata.durationSeconds,
                artworkImage: artwork
            )
        )
    }

    func aapTransport(_ transport: AapTransport, didReceivePlaybackStatus status: AapPlaybackStatus) {
        let isPlaying = status.state != .paused && status.state != .stopped
        if !hasReceivedAaMediaMetadata,
           let source = status.mediaSource?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            NowPlayingCoordinator.shared.updateMetadata(
                NowPlayingMetadata(
                    title: source,
                    artist: "Android Auto",
                    album: "Projection",
                    durationSeconds: nil,
                    artworkImage: nil
                )
            )
        }
        NowPlayingCoordinator.shared.updatePlaybackState(
            NowPlayingPlaybackState(
                isPlaying: isPlaying,
                elapsedSeconds: status.playbackSeconds ?? 0
            )
        )
    }

    func aapTransport(_ transport: AapTransport, didChangeState state: AapTransportState) {
        switch state {
        case .running:
            NowPlayingCoordinator.shared.activate()
            self.state = .running
            updateStatus("Android Auto is running")
        case .error(let msg):
            NowPlayingCoordinator.shared.deactivate()
            microphoneCapture.stop()
            locationCapture.stop()
            self.state = .error(msg)
            updateStatus(msg)
            scheduleReconnectIfNeeded(reason: "Android Auto error")
        default:
            break
        }
    }

    func aapTransportDidDisconnect(_ transport: AapTransport) {
        NowPlayingCoordinator.shared.deactivate()
        microphoneCapture.stop()
        locationCapture.stop()
        state = .disconnected
        connectedDevice = nil
        updateStatus("Android Auto disconnected")
        scheduleReconnectIfNeeded(reason: "Android Auto disconnected")
    }
}

extension ConnectionManager: WirelessHelperServerDelegate {
    func wirelessHelperServer(_ server: WirelessHelperServer, didAccept connection: NWConnection, remoteHost: String?) {
        let canAccept: Bool
        switch state {
        case .discovering, .waitingForWirelessHelper, .disconnected, .error:
            canAccept = true
        case .connecting, .handshaking, .running:
            canAccept = false
        }

        guard canAccept else {
            print("ConnectionManager: dropping inbound wireless helper connection while state=\(state.description)")
            connection.cancel()
            return
        }

        discovery.stopScan()
        state = .connecting

        let host = remoteHost ?? "Wireless Helper"
        connectedDevice = DiscoveredDevice(ip: host, port: WirelessHelperServer.port, name: "Wireless Helper")
        updateStatus("Wireless Helper connected. Starting Android Auto...")
        aapTransport?.configurePeer(host: host, port: WirelessHelperServer.port)
        tcpHandler.acceptConnection(connection, host: host, port: WirelessHelperServer.port)
    }

    func wirelessHelperServer(_ server: WirelessHelperServer, didFail error: Error) {
        print("ConnectionManager: wireless helper server failed with error: \(error.localizedDescription)")
        if state == .discovering {
            state = .error(error.localizedDescription)
            updateStatus(error.localizedDescription)
            scheduleReconnectIfNeeded(reason: "Wireless Helper listener failed")
        }
    }
}
