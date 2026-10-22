import Foundation
import CryptoKit
import Darwin
import AutoAudioCore
import AutoAudioPlatform

/// A real local peer, rather than an injected transaction, observes the RFC 6455
/// Close frame and TCP teardown. Every blocking operation has a finite timeout.
private final class ClosePeer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let acknowledge: Bool
    private let acknowledgmentDelay: TimeInterval
    private let binaryResponse: Bool
    private let allowAbort: Bool
    private let rejectAdditionalConnection: Bool
    private let stallUpgrade: Bool
    private let connectionsToServe: Int
    private let firstCommandConnection: Int
    private let firstCommand: WireCompletion?
    private let responseGate: WireCompletion?
    let acknowledgmentSent: WireCompletion
    private let reply: @Sendable (String) throws -> String?
    let receivedClose: WireCompletion
    let ended: WireCompletion
    private let lock = NSLock()
    private var storedError: Error?
    private var storedCommands: [String] = []
    private var storedTermination: String?
    private var storedRemoteTeardownCount = 0
    private var storedConnectionCount = 0
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return storedCommands }
    var termination: String? { lock.lock(); defer { lock.unlock() }; return storedTermination }
    var remoteTeardownCount: Int { lock.lock(); defer { lock.unlock() }; return storedRemoteTeardownCount }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return storedConnectionCount }
    private func observeTermination(_ value: String, remotelyConfirmed: Bool = false) {
        lock.lock(); storedTermination = value
        if remotelyConfirmed { storedRemoteTeardownCount += 1 }
        lock.unlock()
    }
    init(acknowledge: Bool, receivedClose: WireCompletion, ended: WireCompletion,
         acknowledgmentDelay: TimeInterval = 0,
         binaryResponse: Bool = false, allowAbort: Bool = false, rejectAdditionalConnection: Bool = false,
         stallUpgrade: Bool = false,
         connectionsToServe: Int = 1, firstCommandConnection: Int = 1,
         firstCommand: WireCompletion? = nil, responseGate: WireCompletion? = nil,
         reply: @escaping @Sendable (String) throws -> String? = { _ in "ok" }) throws {
        self.acknowledgmentDelay = acknowledgmentDelay
        self.binaryResponse = binaryResponse; self.allowAbort = allowAbort
        self.rejectAdditionalConnection = rejectAdditionalConnection
        self.stallUpgrade = stallUpgrade
        self.connectionsToServe = connectionsToServe; self.firstCommandConnection = firstCommandConnection
        self.firstCommand = firstCommand; self.responseGate = responseGate
        self.acknowledgmentSent = WireCompletion("peer acknowledgment sent")
        self.reply = reply; self.acknowledge = acknowledge; self.receivedClose = receivedClose; self.ended = ended
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        guard listener >= 0 else { throw PeerError.failed("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }}) == 0, Darwin.listen(listener, 1) == 0 else { Darwin.close(listener); throw PeerError.failed("bind/listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &length)
        }}) == 0 else { Darwin.close(listener); throw PeerError.failed("getsockname") }
        port = UInt16(bigEndian: address.sin_port)
    }
    func start() {
        DispatchQueue.global().async { [self] in
            defer { Darwin.close(listener); ended.fulfill() }
            do {
                for connection in 1...connectionsToServe { try serve(connection: connection) }
                if rejectAdditionalConnection { try verifyNoAdditionalConnection() }
            }
            catch { lock.lock(); storedError = error; lock.unlock() }
        }
    }
    private func verifyNoAdditionalConnection() throws {
        var readSet = fd_set(); withUnsafeMutableBytes(of: &readSet) { bytes in
            let words = bytes.bindMemory(to: Int32.self)
            words[Int(listener) / 32] |= Int32(bitPattern: 1 << UInt32(listener % 32))
        }
        // One finite negative observation, including a connection already queued
        // while the initial successful read was completing its graceful close.
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        let ready = select(listener + 1, &readSet, nil, nil, &timeout)
        guard ready >= 0 else { throw PeerError.failed("additional accept probe: errno=\(errno)") }
        if ready > 0 {
            let extra = accept(listener, nil, nil)
            if extra >= 0 { Darwin.close(extra) }
            throw PeerError.failed("Finite transaction opened an unexpected additional connection")
        }
    }
    private func serve(connection: Int) throws {
        // select bounds accept, including fixtures whose client never connects.
        var readSet = fd_set(); withUnsafeMutableBytes(of: &readSet) { bytes in
            let words = bytes.bindMemory(to: Int32.self)
            words[Int(listener) / 32] |= Int32(bitPattern: 1 << UInt32(listener % 32))
        }
        var acceptTimeout = timeval(tv_sec: 4, tv_usec: 0)
        guard select(listener + 1, &readSet, nil, nil, &acceptTimeout) > 0 else { throw PeerError.failed("accept timeout") }
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw PeerError.failed("accept") }
        lock.lock(); storedConnectionCount += 1; lock.unlock()
        defer { Darwin.close(peer) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0), noPipe: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192 else { throw PeerError.failed("HTTP header size") }
            header.append(try read(peer, count: 1))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        if stallUpgrade {
            // Keep HTTP upgrade pending. The client must end its TCP connection
            // without a WebSocket frame or help from the fixture's read timeout.
            let remainder = try read(peer, count: 1, allowEnd: true)
            guard remainder.isEmpty else { throw PeerError.failed("frame before HTTP upgrade") }
            return
        }
        guard let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { throw PeerError.failed("upgrade key") }
        let key = String(keyLine.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
        let acceptKey = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try send(peer, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n".utf8))
        var receivedCommand = false
        while true {
            let frame = try read(peer, count: 2, allowEnd: allowAbort)
            if frame.isEmpty { return }
            let opcode = frame[0] & 15
            var count = Int(frame[1] & 127)
            guard count < 127, frame[1] & 128 != 0 else { throw PeerError.failed("frame size/mask") }
            if count == 126 {
                let length = try read(peer, count: 2)
                count = Int(length[0]) * 256 + Int(length[1])
            }
            let mask = try read(peer, count: 4)
            let payload = try read(peer, count: count)
            let decoded = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            if opcode == 8 {
                guard decoded.prefix(2).elementsEqual([3, 232]) ||
                        (allowAbort && decoded.prefix(2).elementsEqual([3, 233])) else {
                    throw PeerError.failed("close code")
                }
                receivedClose.fulfill()
                if acknowledge {
                    if acknowledgmentDelay > 0 { Thread.sleep(forTimeInterval: acknowledgmentDelay) }
                    // Mark immediately before send to avoid a callback racing the flag.
                    acknowledgmentSent.fulfill()
                    try send(peer, Data([0x88, UInt8(decoded.count)]) + decoded)
                }
                var byte: UInt8 = 0
                let amount = recv(peer, &byte, 1, 0)
                if amount == 0 { observeTermination("Close acknowledgment followed by remote TCP EOF", remotelyConfirmed: true) }
                else if allowAbort && amount < 0 && errno == ECONNRESET {
                    observeTermination("Close acknowledgment followed by remote TCP reset", remotelyConfirmed: true)
                } else if allowAbort && amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    observeTermination("peer read deadline expired (3 seconds, errno=\(errno), Close received=true); fixture closed the socket after acknowledgment")
                } else { throw PeerError.failed("bounded TCP close: recv=\(amount), errno=\(errno)") }
                return
            }
            guard opcode == 1 else { throw PeerError.failed("unexpected opcode") }
            let command = String(decoding: decoded, as: UTF8.self)
            lock.lock(); storedCommands.append(command); lock.unlock()
            if !receivedCommand {
                receivedCommand = true
                if connection == firstCommandConnection {
                    firstCommand?.fulfill()
                    try responseGate?.waitBlocking()
                }
            }
            // A finite transaction can confirm connection readiness before closing.
            guard let text = try reply(command) else { continue }
            let response = Data(text.utf8)
            let responseOpcode: UInt8 = binaryResponse ? 0x82 : 0x81
            let prefix: Data
            if response.count < 126 { prefix = Data([responseOpcode, UInt8(response.count)]) }
            else { prefix = Data([responseOpcode, 126, UInt8(response.count >> 8), UInt8(response.count & 255)]) }
            try send(peer, prefix + response)
        }
    }
    private func read(_ peer: Int32, count: Int, allowEnd: Bool = false) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { recv(peer, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if offset == 0 && allowEnd {
                if amount == 0 {
                    observeTermination("remote TCP EOF without a Close frame", remotelyConfirmed: true)
                    return Data()
                }
                if amount < 0 && errno == ECONNRESET {
                    observeTermination("remote TCP reset without a Close frame", remotelyConfirmed: true)
                    return Data()
                }
                if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    observeTermination("peer read deadline expired (3 seconds, errno=\(errno), Close received=\(receivedClose.isFulfilled)); fixture closed the socket without confirmed remote teardown")
                    return Data()
                }
            }
            guard amount > 0 else { throw PeerError.failed("read: recv=\(amount), offset=\(offset), errno=\(errno)") }; offset += amount
        }
        return data
    }
    private func send(_ peer: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard amount > 0 else { throw PeerError.failed("write") }; offset += amount
        }
    }
    private enum PeerError: Error { case failed(String) }
}

@MainActor enum WebSocketCleanupVerification {
    static func checks() async throws {
        try await verifyClose(acknowledge: true)
        try await verifyClose(acknowledge: true, acknowledgmentDelay: 0.1)
        try await verifyClose(acknowledge: false)
        for binary in [false, true] {
            try await testSuccessfulAuxReadClosesNormally(binaryResponse: binary)
            try await testSuccessfulPresetReadClosesNormally(binaryResponse: binary)
        }
        try await testV5AuxReadAndVolumeMutation()
        for path in CommandPath.allCases {
            for iteration in 1...2 { try await testStalledReceiveTimesOut(path, iteration: iteration) }
            try await testStalledReceiveTimesOut(path, iteration: 1, stallUpgrade: true)
            try await testBlockedReceiveTaskCancellation(path)
            try await testCancelAndReplaceBlockedReceive(path)
        }
        try await testMeterConnectionPersistsUntilCancel()
        try await testAuxMutationCanceledBeforeDispatch()
        try await testStalledAuxSetterAcknowledgmentTimesOut()
    }
    private static func testSuccessfulAuxReadClosesNormally(binaryResponse: Bool) async throws {
        let close = WireCompletion("Aux peer receives Close frame")
        let ended = WireCompletion("Aux peer ends")
        let peer = try ClosePeer(acknowledge: true, receivedClose: close, ended: ended,
                                 binaryResponse: binaryResponse) { command in
            let name = try JSONDecoder().decode(String.self, from: Data(command.utf8))
            let value: Any
            switch name {
            case "GetVersion": value = "4.1.3"
            case "GetState": value = "Running"
            case "GetConfigJson":
                value = #"{"devices":{"capture":{"type":"CoreAudio","device":"Virtual"},"playback":{"type":"CoreAudio","device":"Physical"}},"pipeline":[]}"#
            case "GetFaders": value = (0..<5).map { _ in ["volume": 0, "mute": false] as [String: Any] }
            default: throw NSError(domain: "Unexpected fixture command", code: 1)
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [name: ["result": "Ok", "value": value]]), as: UTF8.self)
        }
        peer.start()
        let profile = Profile(id: "test", name: "Test", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaAuxDSPTransport()
        defer { transport.cancel() }
        let result = try await transport.read(profile: profile)
        try require(result.main?.volumeDB == 0, "Aux read result")
        try await close.wait(); try await ended.wait()
        if let error = peer.error { throw error }
    }
    private static func testV5AuxReadAndVolumeMutation() async throws {
        let close = WireCompletion("v5 Aux peer receives Close frames")
        let ended = WireCompletion("v5 Aux peer ends")
        let peer = try ClosePeer(acknowledge: true, receivedClose: close, ended: ended,
                                 connectionsToServe: 3) { command in
            let decoded = try JSONSerialization.jsonObject(with: Data(command.utf8), options: [.fragmentsAllowed])
            let name: String
            if let legacy = decoded as? String {
                guard legacy == "GetVersion" else { throw VerificationFailure.failed("Unexpected legacy v5 command: \(legacy)") }
                return #"{"reply":"Invalid","error":"invalid type: string \"GetVersion\", expected internally tagged enum WsCommand at line 1 column 12"}"#
            }
            guard let object = decoded as? [String: Any], let modernName = object["command"] as? String else {
                throw VerificationFailure.failed("Malformed v5 command: \(command)")
            }
            name = modernName
            let value: Any
            switch name {
            case "GetVersion": value = "5.0.0-beta.2"
            case "GetState": value = "Running"
            case "GetConfigJson":
                value = #"{"devices":{"capture":{"type":"CoreAudio","device":"Virtual","channels":2,"labels":["Left","Right"]},"playback":{"type":"CoreAudio","device":"Physical","channels":1,"labels":["Speaker"]}},"pipeline":[{"type":"Filter","channels":[0],"names":["aux1"]}],"filters":{"aux1":{"type":"Volume","parameters":{"fader":"Aux1","limit":0,"ramp_time_ms":10}}}}"#
            case "GetFaders": value = (0..<5).map { _ in ["volume": -12.0, "mute": false] as [String: Any] }
            case "GetSignalLevelsSinceLast":
                value = ["capture_rms": [-30.0, -40.0], "capture_peak": [-10.0, -20.0],
                         "playback_rms": [-25.0], "playback_peak": [-5.0]]
            case "SetFaderVolume":
                guard object["fader"] as? Int == 1 && object["value"] as? Double == -18 else {
                    throw VerificationFailure.failed("Malformed v5 volume mutation: \(command)")
                }
                return #"{"reply":"SetFaderVolume","result":"Ok"}"#
            default: throw VerificationFailure.failed("Unexpected v5 Aux command: \(name)")
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["reply": name, "result": "Ok", "value": value]), as: UTF8.self)
        }
        peer.start()
        let profile = Profile(id: "v5-wire", name: "v5 wire", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaAuxDSPTransport()
        defer { transport.cancel() }
        let read = try await transport.read(profile: profile)
        try require(read.main?.volumeDB == -12 && read.faders.map(\.id) == [1], "v5 read exposes Main and the configured Aux1 fader")
        try await transport.setVolume(id: 1, db: -18)
        let meter = CamillaSignalLevelsTransport()
        try await meter.connect(profile: profile)
        let levels = try await meter.read()
        try require(levels.input.map(\.label) == ["Left", "Right"] && levels.output.map(\.label) == ["Speaker"] &&
                    levels.input.map(\.rmsDB) == [-30, -40] && levels.output.map(\.peakDB) == [-5],
                    "v5 retained meter connection decodes its reply envelope and channel payload")
        meter.cancel()
        try await close.wait(); try await ended.wait()
        if let error = peer.error { throw error }
        let decoded = try peer.commands.map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        let names = decoded.map { command -> String in
            if let legacy = command as? String { return legacy }
            return (command as? [String: Any])?["command"] as? String ?? "invalid"
        }
        try require(names == ["GetVersion", "GetVersion", "GetState", "GetConfigJson", "GetFaders",
                             "GetVersion", "GetVersion", "SetFaderVolume",
                             "GetVersion", "GetVersion", "GetState", "GetConfigJson", "GetSignalLevelsSinceLast"],
                    "v5 Aux, mutation and retained meter connections negotiate once and use typed commands")
    }
    private static func testSuccessfulPresetReadClosesNormally(binaryResponse: Bool) async throws {
        let close = WireCompletion("Preset peer receives Close frame")
        let ended = WireCompletion("Preset peer ends")
        let peer = try ClosePeer(acknowledge: true, receivedClose: close, ended: ended,
                                 acknowledgmentDelay: 0.1, binaryResponse: binaryResponse) { command in
            let name = try JSONDecoder().decode(String.self, from: Data(command.utf8))
            let value: Any
            switch name {
            case "GetVersion": value = "4.1.3"
            case "GetState": value = "Running"
            case "GetConfigJson":
                value = #"{"devices":{"capture":{"type":"CoreAudio","device":"Virtual"},"playback":{"type":"CoreAudio","device":"Physical"}},"pipeline":[]}"#
            case "GetConfigFilePath": value = NSNull()
            case "GetFaders": value = (0..<5).map { _ in ["volume": 0, "mute": false] as [String: Any] }
            default: throw NSError(domain: "Unexpected fixture command", code: 1)
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [name: ["result": "Ok", "value": value]]), as: UTF8.self)
        }
        peer.start()
        let profile = Profile(id: "test", name: "Test", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaPresetDSPTransport()
        defer { transport.cancel() }
        let result = try await transport.inspect(profile: profile, paths: [])
        try require(result.entries.isEmpty && result.activePath == nil, "Preset read result")
        try await close.wait(); try await ended.wait()
        if let error = peer.error { throw error }
    }
    private static func testMeterConnectionPersistsUntilCancel() async throws {
        let close = WireCompletion("Meter peer receives normal Close frame after cancel")
        let ended = WireCompletion("Meter peer ends after cancel")
        let peer = try ClosePeer(acknowledge: true, receivedClose: close, ended: ended,
                                 binaryResponse: true) { command in
            let name = try JSONDecoder().decode(String.self, from: Data(command.utf8))
            let value: Any
            switch name {
            case "GetVersion": value = "4.1.3"
            case "GetState": value = "Running"
            case "GetConfigJson":
                value = #"{"devices":{"capture":{"type":"CoreAudio","device":"Virtual","channels":2,"labels":["Left","Right"]},"playback":{"type":"CoreAudio","device":"Physical","channels":1,"labels":["Speaker"]}},"pipeline":[]}"#
            case "GetSignalLevelsSinceLast":
                value = ["capture_rms": [-30.0, -40.0], "capture_peak": [-10.0, -20.0],
                         "playback_rms": [-25.0], "playback_peak": [-5.0]]
            default: throw VerificationFailure.failed("Unexpected meter command: \(name)")
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [name: ["result": "Ok", "value": value]]), as: UTF8.self)
        }
        peer.start()
        let profile = Profile(id: "meter-wire", name: "Meter wire", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaSignalLevelsTransport()
        defer { transport.cancel() }
        let completed = WireCompletion("Meter connect and reads finish within bounded wait")
        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await transport.connect(profile: profile)
            try require(!close.isFulfilled && !ended.isFulfilled, "Successful meter connect retains its socket")
            let first = try await transport.read()
            try require(first.input.map(\.label) == ["Left", "Right"] && first.output.map(\.label) == ["Speaker"],
                "Meter binary configuration replies decode channel labels")
            try require(first.input.map(\.rmsDB) == [-30, -40] && first.output.map(\.peakDB) == [-5],
                "Meter binary interval reply decodes level values")
            let second = try await transport.read()
            try require(second.input.map(\.peakDB) == [-10, -20] && second.output.map(\.rmsDB) == [-25],
                "Meter performs a second read on the retained connection")
            try require(!close.isFulfilled && !ended.isFulfilled, "Successful meter reads retain their socket")
        }
        defer { operation.cancel() }
        try await completed.wait()
        try await operation.value
        let names = try peer.commands.map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        try require(names == ["GetVersion", "GetState", "GetConfigJson", "GetSignalLevelsSinceLast", "GetSignalLevelsSinceLast"],
            "Single meter peer receives only the finite requested exchanges")
        transport.cancel()
        try await close.wait(); try await ended.wait()
        if let error = peer.error { throw error }
    }
    private static func testAuxMutationCanceledBeforeDispatch() async throws {
        let close = WireCompletion("Predispatch Aux fixture read closes normally")
        let ended = WireCompletion("Predispatch Aux fixture negative accept probe finishes")
        let peer = try ClosePeer(acknowledge: true, receivedClose: close, ended: ended,
            rejectAdditionalConnection: true, reply: { try commandReply($0) })
        peer.start()
        let profile = Profile(id: "cancel-before-dispatch", name: "Cancel before dispatch", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaAuxDSPTransport()
        defer { transport.cancel() }
        _ = try await transport.read(profile: profile)
        let completed = WireCompletion("Predispatch Aux mutation cancellation finishes")
        let mutation = Task { @MainActor in
            defer { completed.fulfill() }
            try await transport.setVolume(id: 0, db: -12)
        }
        // Both creation and cancellation occur in the same MainActor turn. The
        // mutation has valid readback authority but cannot run before cancellation.
        mutation.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        try await completed.wait()
        switch await mutation.result {
        case .success: throw VerificationFailure.failed("Predispatch-canceled Aux mutation succeeded")
        case .failure(let error): try require(error is CancellationError, "Predispatch cancellation retains its error type")
        }
        try require(ProcessInfo.processInfo.systemUptime - started < 1.5, "Predispatch Aux cancellation is prompt")
        try await close.wait(); try await ended.wait()
        if let error = peer.error { throw error }
        let names = try peer.commands.map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        try require(names == ["GetVersion", "GetState", "GetConfigJson", "GetFaders"],
            "Canceled authorized Aux mutation sends no setter command or replacement connection")
    }
    private static func testStalledAuxSetterAcknowledgmentTimesOut() async throws {
        let received = WireCompletion("Aux setter received before acknowledgment stalls")
        let ended = WireCompletion("Aux setter peer ends and negative accept probe finishes")
        let peer = try ClosePeer(acknowledge: true,
            receivedClose: WireCompletion("Aux setter fixture Close frames"), ended: ended,
            allowAbort: true, rejectAdditionalConnection: true,
            connectionsToServe: 2, firstCommandConnection: 2, firstCommand: received, reply: { command in
                let data = Data(command.utf8)
                if let setter = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
                    guard setter.count == 1, let arguments = setter["SetFaderVolume"] as? [NSNumber],
                          arguments.map(\.doubleValue) == [0, -12] else {
                        throw VerificationFailure.failed("Unexpected Aux setter command: \(command)")
                    }
                    return nil
                }
                return try commandReply(command)
            })
        peer.start()
        let profile = Profile(id: "stalled-setter", name: "Stalled setter", triggerUID: "physical", captureUID: "virtual",
            playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
            websocketURL: "ws://127.0.0.1:\(peer.port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
        let transport = CamillaAuxDSPTransport(timeout: 0.2)
        defer { transport.cancel() }
        let state = try await transport.read(profile: profile)
        try require(state.main?.volumeDB == 0, "Stalled setter starts with valid Aux readback authority")
        let completed = WireCompletion("Aux setter acknowledgment timeout finishes within bounded wait")
        let started = ProcessInfo.processInfo.systemUptime
        let mutation = Task { @MainActor in
            defer { completed.fulfill() }
            try await transport.setVolume(id: 0, db: -12)
        }
        defer { mutation.cancel() }
        try await received.wait()
        try await completed.wait()
        if case .success = await mutation.result { throw VerificationFailure.failed("Unacknowledged Aux setter succeeded") }
        try require(ProcessInfo.processInfo.systemUptime - started < 1.5, "Aux setter acknowledgment timeout is prompt")
        try await observeAbortPeerEnd(peer, ended: ended, context: "Aux setter acknowledgment timeout", requiredRemoteEnds: 2)
        try require(peer.connectionCount == 2, "Aux setter uses one authorized read connection and one mutation connection")
        let commands = peer.commands
        try require(commands.count == 6, "Timed-out Aux setter sends one handshake per connection and exactly one mutation without replay")
        let names = try commands.prefix(5).map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        try require(Array(names.prefix(4)) == ["GetVersion", "GetState", "GetConfigJson", "GetFaders"] && names[4] == "GetVersion",
                    "Aux setter authority came from a complete prior read and a new mutation connection")
    }
    private enum CommandPath: String, CaseIterable { case aux, preset }
    @MainActor private enum CommandTransport {
        case aux(CamillaAuxDSPTransport)
        case preset(CamillaPresetDSPTransport)
        init(_ path: CommandPath, timeout: TimeInterval) {
            switch path {
            case .aux: self = .aux(CamillaAuxDSPTransport(timeout: timeout))
            case .preset: self = .preset(CamillaPresetDSPTransport(timeout: timeout))
            }
        }
        func read(port: UInt16) async throws {
            let profile = Profile(id: "blocked-wire", name: "Blocked wire", triggerUID: "physical", captureUID: "virtual",
                playbackUID: "physical", launchAgentLabel: "example.dsp", launchAgentPath: "/tmp/example.plist",
                websocketURL: "ws://127.0.0.1:\(port)", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
            switch self {
            case .aux(let transport):
                let result = try await transport.read(profile: profile)
                try WebSocketCleanupVerification.require(result.main?.volumeDB == 0, "Replacement Aux read result")
            case .preset(let transport):
                let result = try await transport.inspect(profile: profile, paths: [])
                try WebSocketCleanupVerification.require(result.entries.isEmpty && result.activePath == nil, "Replacement preset read result")
            }
        }
        func cancel() {
            switch self {
            case .aux(let transport): transport.cancel()
            case .preset(let transport): transport.cancel()
            }
        }
    }
    private static func testStalledReceiveTimesOut(_ path: CommandPath, iteration: Int, stallUpgrade: Bool = false) async throws {
        let received = WireCompletion("\(path.rawValue) stalled command received")
        let ended = WireCompletion("\(path.rawValue) timeout peer ends")
        let peer = try ClosePeer(acknowledge: true, receivedClose: WireCompletion("timeout close"), ended: ended,
            allowAbort: true, stallUpgrade: stallUpgrade, firstCommand: received, reply: { _ in nil })
        peer.start()
        let transport = CommandTransport(path, timeout: 0.2)
        defer { transport.cancel() }
        let completed = WireCompletion("\(path.rawValue) stalled read finishes within bounded wait")
        let started = ProcessInfo.processInfo.systemUptime
        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await transport.read(port: peer.port)
        }
        defer { operation.cancel() }
        if !stallUpgrade { try await received.wait() }
        try await completed.wait()
        if case .success = await operation.result { throw VerificationFailure.failed("Stalled \(path.rawValue) read succeeded") }
        try require(ProcessInfo.processInfo.systemUptime - started < 1.5, "\(path.rawValue) read timeout is finite")
        let context = stallUpgrade ? "\(path.rawValue) blocked upgrade" : "\(path.rawValue) timeout iteration \(iteration)"
        try await observeAbortPeerEnd(peer, ended: ended, context: context, requiredRemoteEnds: 1)
        if stallUpgrade {
            try require(peer.connectionCount == 1 && peer.commands.isEmpty,
                "Blocked \(path.rawValue) upgrade closes the accepted socket without dispatching a command")
        }
        if let error = peer.error { throw error }
    }
    private static func testBlockedReceiveTaskCancellation(_ path: CommandPath) async throws {
        let received = WireCompletion("\(path.rawValue) task cancellation command received")
        let ended = WireCompletion("\(path.rawValue) task cancellation peer ends")
        let peer = try ClosePeer(acknowledge: true, receivedClose: WireCompletion("task cancellation close"), ended: ended,
            allowAbort: true, firstCommand: received, reply: { _ in nil })
        peer.start()
        let transport = CommandTransport(path, timeout: 3)
        defer { transport.cancel() }
        let completed = WireCompletion("\(path.rawValue) task cancellation finishes")
        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await transport.read(port: peer.port)
        }
        defer { operation.cancel() }
        try await received.wait()
        let started = ProcessInfo.processInfo.systemUptime
        operation.cancel()
        try await completed.wait()
        if case .success = await operation.result { throw VerificationFailure.failed("Task-canceled \(path.rawValue) read succeeded") }
        try require(ProcessInfo.processInfo.systemUptime - started < 1.5, "\(path.rawValue) task cancellation is prompt")
        try await observeAbortPeerEnd(peer, ended: ended, context: "\(path.rawValue) task cancellation")
        if let error = peer.error { throw error }
    }
    private static func testCancelAndReplaceBlockedReceive(_ path: CommandPath) async throws {
        let received = WireCompletion("\(path.rawValue) canceled command received")
        let ended = WireCompletion("\(path.rawValue) canceled peer ends")
        let oldPeer = try ClosePeer(acknowledge: true, receivedClose: WireCompletion("canceled close"), ended: ended,
            allowAbort: true, firstCommand: received, reply: { _ in nil })
        oldPeer.start()
        let transport = CommandTransport(path, timeout: 3)
        defer { transport.cancel() }
        let oldCompleted = WireCompletion("\(path.rawValue) canceled read finishes")
        let old = Task { @MainActor in
            defer { oldCompleted.fulfill() }
            try await transport.read(port: oldPeer.port)
        }
        defer { old.cancel() }
        try await received.wait()
        transport.cancel()

        // Start the replacement immediately, before awaiting the old operation's
        // cleanup. Hold its first reply until that cleanup has completed.
        let replacementReceived = WireCompletion("\(path.rawValue) replacement command received")
        let releaseReply = WireCompletion("\(path.rawValue) replacement reply released")
        let replacementClose = WireCompletion("\(path.rawValue) replacement closes normally")
        let replacementEnded = WireCompletion("\(path.rawValue) replacement peer ends")
        let replacementPeer = try ClosePeer(acknowledge: true, receivedClose: replacementClose, ended: replacementEnded,
            binaryResponse: true, firstCommand: replacementReceived, responseGate: releaseReply,
            reply: { try commandReply($0) })
        replacementPeer.start()
        let replacementCompleted = WireCompletion("\(path.rawValue) replacement read finishes")
        let replacement = Task { @MainActor in
            defer { replacementCompleted.fulfill() }
            try await transport.read(port: replacementPeer.port)
        }
        defer { releaseReply.fulfill(); replacement.cancel() }
        try await replacementReceived.wait()
        try await oldCompleted.wait()
        if case .success = await old.result { throw VerificationFailure.failed("Canceled \(path.rawValue) read succeeded") }
        releaseReply.fulfill()
        try await replacementCompleted.wait()
        try await replacement.value
        try await observeAbortPeerEnd(oldPeer, ended: ended, context: "\(path.rawValue) transport cancellation")
        try await replacementClose.wait(); try await replacementEnded.wait()
        if let error = replacementPeer.error { throw error }
    }
    private static func observeAbortPeerEnd(_ peer: ClosePeer, ended: WireCompletion, context: String,
                                          requiredRemoteEnds: Int = 1) async throws {
        // Foundation can leave a pending receive's TCP connection alive after
        // abort has released command authority. Observe it beyond this peer's
        // three-second read limit, reporting fixture cleanup separately from
        // remotely confirmed teardown. Every abort case requires remote EOF/reset;
        // expiry remains a diagnostic observation and never a passing result.
        try await ended.wait(timeout: 4)
        if let error = peer.error { throw error }
        guard let termination = peer.termination else {
            throw VerificationFailure.failed("Aborted \(context) peer termination was not classified")
        }
        try require(peer.remoteTeardownCount == requiredRemoteEnds,
            "\(context) requires remote TCP EOF/reset before the fixture deadline: \(termination)")
        print("Aborted \(context) peer observation: \(termination)")
    }
    nonisolated private static func commandReply(_ command: String) throws -> String? {
        let name = try JSONDecoder().decode(String.self, from: Data(command.utf8))
        let value: Any
        switch name {
        case "GetVersion": value = "4.1.3"
        case "GetState": value = "Running"
        case "GetConfigJson":
            value = #"{"devices":{"capture":{"type":"CoreAudio","device":"Virtual"},"playback":{"type":"CoreAudio","device":"Physical"}},"pipeline":[]}"#
        case "GetConfigFilePath": value = NSNull()
        case "GetFaders": value = (0..<5).map { _ in ["volume": 0, "mute": false] as [String: Any] }
        default: throw VerificationFailure.failed("Unexpected replacement command: \(name)")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: [name: ["result": "Ok", "value": value]]), as: UTF8.self)
    }
    private static func verifyClose(acknowledge: Bool, acknowledgmentDelay: TimeInterval = 0) async throws {
        let close = WireCompletion("peer receives normal Close frame")
        let ended = WireCompletion("peer connection ends")
        let invalidated = WireCompletion("client session invalidated")
        let peer = try ClosePeer(acknowledge: acknowledge, receivedClose: close, ended: ended,
                                 acknowledgmentDelay: acknowledgmentDelay)
        peer.start()
        let prematureInvalidation = WireCompletion("premature invalidation")
        let connection = BoundedWebSocketConnection(url: URL(string: "ws://127.0.0.1:\(peer.port)")!,
            timeout: 3, closeTimeout: 0.5, onInvalidation: {
                if acknowledge && !peer.acknowledgmentSent.isFulfilled { prematureInvalidation.fulfill() }
                invalidated.fulfill()
            })
        defer { connection.abort() }
        let socket = connection.socket!
        socket.resume()
        try await socket.send(.string("ready"))
        guard case .string("ok") = try await socket.receive() else { throw VerificationFailure.failed("Unexpected fixture reply") }
        let started = Date()
        connection.close()
        // Idempotent teardown must not restart the grace period.
        connection.close()
        try await close.wait(); try await ended.wait(); try await invalidated.wait()
        if let error = peer.error { throw error }
        try require(!prematureInvalidation.isFulfilled, "session lives until delayed peer acknowledgment")
        try require(Date().timeIntervalSince(started) < 1.5, "bounded close teardown")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationFailure.failed(message) }
    }
}
private enum VerificationFailure: Error { case failed(String) }
private final class WireCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var fulfilled = false
    var isFulfilled: Bool { lock.lock(); defer { lock.unlock() }; return fulfilled }
    private let description: String
    init(_ description: String) { self.description = description }
    func fulfill() { lock.lock(); fulfilled = true; lock.unlock(); semaphore.signal() }
    func waitBlocking(timeout: TimeInterval = 2) throws {
        if semaphore.wait(timeout: .now() + timeout) != .success { throw VerificationFailure.failed(description) }
    }
    func wait(timeout: TimeInterval = 2) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in
                do { try waitBlocking(timeout: timeout); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
