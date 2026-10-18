import Foundation
import Darwin
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class GUIClock: TransitionSleeping {
    var time: TimeInterval = 0
    var delays: [Int] = []
    func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation(); delays.append(milliseconds); time += Double(milliseconds) / 1000
        await Task.yield(); try Task.checkCancellation()
    }
}
@MainActor private final class FakeGUI: GUIManaging {
    var onExit: (@MainActor (String, String) -> Void)?
    var calls: [String] = []
    var failure: GUIFailure?
    var stopFailures = 0
    var readinessFailures = 0
    var probes = 0
    var holdStart = false
    var holdStop = false
    var waiting: CheckedContinuation<Void, Never>?
    var exitDuringStart = false
    func start(_ profile: Profile) async throws {
        calls.append("start:" + profile.id)
        if holdStart { await withCheckedContinuation { waiting = $0 } }
        if exitDuringStart { exitDuringStart = false; onExit?(profile.id, "Exited during start") }
        if let failure { throw failure }
    }
    func verifyReadiness(_ profile: Profile) async throws {
        probes += 1
        if readinessFailures > 0 { readinessFailures -= 1; throw GUIFailure.starting("HTTP not ready") }
    }
    func stop(_ profile: Profile) async throws {
        calls.append("stop:" + profile.id)
        if holdStop { await withCheckedContinuation { waiting = $0 } }
        if stopFailures > 0 { stopFailures -= 1; throw GUIFailure.transient("Owned stop still pending") }
    }
}
@MainActor private func settled(_ controller: GUIController, _ id: String, _ state: GUIServiceState) async throws {
    for _ in 0..<2_000 {
        if try controller.status(profileID: id).observed == state { return }
        await Task.yield()
    }
    throw CheckFailure.failed("GUI did not reach " + state.rawValue)
}
@MainActor func runGUIChecks() async throws {
    var profile = Profile(id: "gui-test", name: "GUI Test", triggerUID: "physical", captureUID: "virtual",
                          playbackUID: "physical", launchAgentLabel: "test.dsp.gui", launchAgentPath: "/tmp/test-dsp.plist",
                          websocketURL: "ws://127.0.0.1:1234", expectedCaptureDevice: "Virtual", expectedPlaybackDevice: "Physical")
    let old = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
    try check(old.gui == nil, "Old profiles retain absent GUI settings")
    let omitted = Data(#"{"executablePath":"/usr/bin/true","configPath":"/tmp/gui.json","url":"http://127.0.0.1:5005"}"#.utf8)
    profile.gui = try JSONDecoder().decode(GUIConfiguration.self, from: omitted)
    try check(profile.gui?.autoStart == false, "Missing autoStart defaults false")
    profile.gui!.autoStart = true
    let absent = AudioSnapshot(devices: [], outputUID: nil, alertUID: nil)
    let present = AudioSnapshot(devices: [AudioDevice(uid: "physical", name: "Physical", hasOutput: true)], outputUID: nil, alertUID: nil)
    var offProfile = profile; offProfile.gui!.autoStart = false
    let offService = FakeGUI(); let off = GUIController(profiles: [offProfile], service: offService)
    off.receive(present)
    for _ in 0..<30 { await Task.yield() }
    try check(offService.calls == ["stop:" + profile.id], "Default-off removes inherited owned GUI even with hardware present")
    await off.shutdown()
    let autoService = FakeGUI(); let autoClock = GUIClock()
    let automatic = GUIController(profiles: [profile], service: autoService, sleeper: autoClock, now: { autoClock.time })
    automatic.receive(present)
    try await settled(automatic, profile.id, .running)
    autoService.holdStop = true
    automatic.receive(absent)
    while autoService.waiting == nil { await Task.yield() }
    automatic.receive(present)
    autoService.holdStop = false; autoService.waiting?.resume(); autoService.waiting = nil
    try await settled(automatic, profile.id, .running)
    try check(autoService.calls == ["start:gui-test", "stop:gui-test", "start:gui-test"], "Physical reconnect during shutdown restarts automatic GUI after shutdown completes")
    autoService.failure = .transient("automatic temporary failure")
    autoService.onExit?(profile.id, "automatic exit")
    try await settled(automatic, profile.id, .failed)
    let autoAttempts = autoService.calls.count; let autoDeadline = autoClock.time
    for _ in 0..<5 { automatic.receive(present); await Task.yield() }
    try check(autoService.calls.count == autoAttempts && autoClock.time == autoDeadline, "Duplicate physical snapshots do not renew expired automatic recovery")
    autoService.failure = nil
    automatic.receive(absent)
    for _ in 0..<30 { await Task.yield() }
    try await settled(automatic, profile.id, .stopped)
    automatic.receive(present)
    try await settled(automatic, profile.id, .running)
    try check(autoService.calls.count == autoAttempts + 2, "Genuine physical disconnect/reconnect opens a new recovery window")
    await automatic.shutdown()
    let clock = GUIClock(); let service = FakeGUI()
    let gui = GUIController(profiles: [profile], service: service, sleeper: clock, now: { clock.time })
    var logs: [String] = []; gui.onLog = { logs.append($0) }
    service.readinessFailures = 3
    _ = try await gui.command(.start, profileID: profile.id)
    try await settled(gui, profile.id, .running)
    try check(service.probes == 4 && clock.delays == [500, 500, 500], "HTTP readiness observed at 500ms without relaunch")
    let probes = service.probes
    for _ in 0..<20 { await Task.yield() }
    try check(service.probes == probes, "Healthy GUI has no scheduled readiness probes")
    gui.receive(absent)
    let manualStatus = try gui.status(profileID: profile.id)
    try check(manualStatus.desiredRunning, "Manual-on survives disconnect")
    service.holdStop = true
    _ = try await gui.command(.stop, profileID: profile.id)
    while service.waiting == nil { await Task.yield() }
    _ = try await gui.command(.start, profileID: profile.id)
    service.holdStop = false; service.waiting?.resume(); service.waiting = nil
    try await settled(gui, profile.id, .running)
    try check(service.calls == ["start:gui-test", "stop:gui-test", "start:gui-test"], "Rapid off/on serializes owned shutdown then restarts latest desire")
    service.onExit?(profile.id, "unexpected")
    for _ in 0..<30 { await Task.yield() }
    try check(service.calls.filter { $0.hasPrefix("start:") }.count == 3, "Unexpected exit starts one recovery window")
    await gui.shutdown()
    service.onExit?(profile.id, "late")
    let stoppedStatus = try gui.status(profileID: profile.id)
    try check(stoppedStatus.observed == .stopped, "Late exit after shutdown ignored")

    let failing = FakeGUI(); failing.failure = .transient("temporarily unavailable")
    let failClock = GUIClock()
    let failed = GUIController(profiles: [profile], service: failing, sleeper: failClock, now: { failClock.time })
    _ = try await failed.command(.start, profileID: profile.id)
    try await settled(failed, profile.id, .failed)
    try check(failClock.time == 30 && failClock.delays.prefix(4) == [1_000, 2_000, 4_000, 4_000], "One 30-second deadline clamps capped retry delays")
    let attempts = failing.calls.count
    failed.receive(absent)
    for _ in 0..<30 { await Task.yield() }
    try check(failing.calls.count == attempts, "Unchanged manual desired state does not renew failed recovery")
    failing.failure = .permanent("invalid configuration")
    _ = try await failed.command(.retry, profileID: profile.id)
    let retainedOn = try failed.status(profileID: profile.id).policy
    try check(retainedOn == .manualOn, "GUI retry preserves manual On")
    for _ in 0..<30 { await Task.yield() }
    try check(failing.calls.count == attempts + 1, "Explicit retry opens new window; permanent failure is attempted once")
    await failed.shutdown()

    let retryService = FakeGUI(); retryService.failure = .permanent("invalid preview configuration")
    let autoRetry = GUIController(profiles: [profile], service: retryService)
    autoRetry.receive(present)
    try await settled(autoRetry, profile.id, .failed)
    for _ in 0..<30 { await Task.yield() }
    retryService.failure = nil
    _ = try await autoRetry.command(.retry, profileID: profile.id)
    let retainedAuto = try autoRetry.status(profileID: profile.id).policy
    try check(retainedAuto == .automatic, "GUI retry preserves Auto")
    try await settled(autoRetry, profile.id, .running)
    do { _ = try await autoRetry.command(.retry, profileID: profile.id); throw CheckFailure.failed("Retry must reject healthy GUI") }
    catch let error as CheckFailure { throw error } catch { }
    await autoRetry.shutdown()

    let cleanupService = FakeGUI(); cleanupService.stopFailures = 2; let cleanupClock = GUIClock()
    let cleanup = GUIController(profiles: [profile], service: cleanupService, sleeper: cleanupClock, now: { cleanupClock.time })
    _ = try await cleanup.command(.start, profileID: profile.id)
    try await settled(cleanup, profile.id, .running)
    _ = try await cleanup.command(.stop, profileID: profile.id)
    for _ in 0..<30 { await Task.yield() }
    try await settled(cleanup, profile.id, .stopped)
    try check(cleanupClock.delays == [1_000, 2_000] && cleanupService.calls.filter { $0.hasPrefix("stop:") }.count == 3, "Transient owned shutdown receives bounded cleanup retries")
    await cleanup.shutdown()

    let delayedService = FakeGUI(); delayedService.holdStart = true
    var second = profile; second.id = "second"
    let delayed = GUIController(profiles: [profile, second], service: delayedService)
    _ = try await delayed.command(.start, profileID: profile.id)
    while delayedService.waiting == nil { await Task.yield() }
    delayedService.holdStart = false
    _ = try await delayed.command(.start, profileID: second.id)
    try await settled(delayed, second.id, .running)
    _ = try await delayed.command(.stop, profileID: profile.id)
    delayedService.waiting?.resume(); delayedService.waiting = nil
    try await settled(delayed, profile.id, .stopped)
    let cancelledStatus = try delayed.status(profileID: profile.id)
    try check(cancelledStatus.observed == .stopped, "Cancelled startup cleans latest stopped state without blocking another profile")
    await delayed.shutdown()

    let exits = FakeGUI(); exits.exitDuringStart = true; let exitClock = GUIClock()
    let exiting = GUIController(profiles: [profile], service: exits, sleeper: exitClock, now: { exitClock.time })
    _ = try await exiting.command(.start, profileID: profile.id)
    try await settled(exiting, profile.id, .running)
    try check(exits.calls.count == 2 && exits.probes == 1, "Exit during start is retried before HTTP success")
    await exiting.shutdown()
    try check(logs.contains { $0.contains("ready") } && logs.contains { $0.contains("unexpected exit") }, "Lifecycle logs independent of feedback settings")
    var duplicate = profile; duplicate.id = "duplicate"; duplicate.launchAgentLabel = "test.duplicate"
    do { try ConfigurationLoader.validate(Configuration(profiles: [profile, duplicate])); throw CheckFailure.failed("Duplicate GUI port accepted") }
    catch let error as SwitcherError { try check(error.localizedDescription.contains("distinct GUI"), "Duplicate endpoint rejected") }
    duplicate.gui!.url = "http://example.com:5006"
    do { try ConfigurationLoader.validate(Configuration(profiles: [duplicate])); throw CheckFailure.failed("Nonlocal GUI accepted") }
    catch is SwitcherError {}
    duplicate.gui!.url = "http://127.0.0.1:5006"; duplicate.launchAgentLabel = LaunchdGUIManager.label(profile)
    do { try ConfigurationLoader.validate(Configuration(profiles: [profile, duplicate])); throw CheckFailure.failed("GUI DSP identity conflict accepted") }
    catch is SwitcherError {}
    try await runGUIPlatformChecks(profile)
    print("GUI checks: readiness, bounded recovery, cancellation, rapid off/on, independent profiles, ownership and command acceptance passed")
}

@MainActor private func runGUIPlatformChecks(_ original: Profile) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gui-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = original
    let fixtureFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fixtureFD >= 0 else { throw CheckFailure.failed("Cannot allocate GUI fixture port") }
    var fixtureAddress = sockaddr_in(); fixtureAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    fixtureAddress.sin_family = sa_family_t(AF_INET); fixtureAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
    fixtureAddress.sin_port = 0
    let fixtureBound = withUnsafePointer(to: &fixtureAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fixtureFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard fixtureBound == 0 else { Darwin.close(fixtureFD); throw CheckFailure.failed("Cannot bind GUI fixture port") }
    var fixtureLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &fixtureAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fixtureFD, $0, &fixtureLength) } }
    let fixturePort = Int(UInt16(bigEndian: fixtureAddress.sin_port))
    Darwin.close(fixtureFD)
    profile.gui!.url = "http://127.0.0.1:" + String(fixturePort)
    profile.gui!.executablePath = "/usr/bin/true"
    profile.gui!.configPath = root.appendingPathComponent("backend.yml").path
    let config: [String: Any] = ["bind_address": "127.0.0.1", "port": fixturePort, "camilla_host": "127.0.0.1", "camilla_port": 1234]
    try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: profile.gui!.configPath))
    try LaunchdGUIManager.validateBackend(profile)
    let ordinaryYAML = """
    # Ordinary CamillaGUI backend YAML, including explicit null TLS fields.
    bind_address: localhost
    port: \(fixturePort)
    camilla_host: 127.0.0.1
    camilla_port: 1234
    ssl_certificate: null
    ssl_private_key: ~
    """
    let backendURL = URL(fileURLWithPath: profile.gui!.configPath)
    try Data(ordinaryYAML.utf8).write(to: backendURL)
    let validatedYAML = try LaunchdGUIManager.validateBackend(profile)
    try check(validatedYAML == Data(ordinaryYAML.utf8), "Launch validation accepts ordinary YAML comments and null TLS values without changing bytes")
    let invalidBackendDocuments = [
        "bind_address: [unclosed", "- one\n- two\n", "null", "42",
        ordinaryYAML.replacingOccurrences(of: "camilla_port: 1234", with: "camilla_port: 4321"),
        ordinaryYAML.replacingOccurrences(of: "bind_address: localhost", with: "bind_address: 0.0.0.0"),
        ordinaryYAML.replacingOccurrences(of: "ssl_certificate: null", with: "ssl_certificate: certificate.pem"),
        ordinaryYAML.replacingOccurrences(of: "ssl_private_key: ~", with: "ssl_private_key: key.pem"),
        ordinaryYAML.replacingOccurrences(of: "ssl_certificate: null", with: "ssl_certificate: 'null'"),
        ordinaryYAML.replacingOccurrences(of: "ssl_certificate: null", with: "ssl_certificate: !!str null"),
        ordinaryYAML.replacingOccurrences(of: "port: \(fixturePort)", with: "port: !!str \(fixturePort)"),
        ordinaryYAML + "\nbind_address: 0.0.0.0\n",
        ordinaryYAML.replacingOccurrences(of: "port: \(fixturePort)", with: "port: 1")
    ]
    var rejectedLaunchCommands = 0
    let refusedManager = LaunchdGUIManager(directory: root, runCommand: { _ in
        rejectedLaunchCommands += 1
        throw CheckFailure.failed("Invalid GUI config reached launchctl")
    })
    for document in invalidBackendDocuments {
        try Data(document.utf8).write(to: backendURL)
        do { try await refusedManager.start(profile); throw CheckFailure.failed("Invalid GUI backend configuration reached launch") }
        catch is GUIFailure { }
    }
    try check(rejectedLaunchCommands == 0, "Malformed, nonmapping, mismatched or TLS GUI configurations fail before service inspection or launch")
    try JSONSerialization.data(withJSONObject: config).write(to: backendURL)
    var missingExecutable = profile; missingExecutable.gui!.executablePath = root.appendingPathComponent("not-installed").path
    do { try LaunchdGUIManager.validateBackend(missingExecutable); throw CheckFailure.failed("Missing GUI executable accepted") }
    catch let error as GUIFailure { try check(!error.recoverable, "Missing executable is a permanent configuration failure") }
    var wrong = config; wrong["bind_address"] = "0.0.0.0"
    try JSONSerialization.data(withJSONObject: wrong).write(to: URL(fileURLWithPath: profile.gui!.configPath))
    do { try LaunchdGUIManager.validateBackend(profile); throw CheckFailure.failed("Network GUI backend allowed") }
    catch is GUIFailure { }
    try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: profile.gui!.configPath))
    try check(LaunchdGUIManager.label(profile) == "org.camillacompanion.gui." + profile.id,
              "GUI job identity uses the current application namespace")
    let path = root.appendingPathComponent(LaunchdGUIManager.label(profile) + ".plist")
    let plist: [String: Any] = ["Label": LaunchdGUIManager.label(profile), "ProgramArguments": [profile.gui!.executablePath, "-c", profile.gui!.configPath], "KeepAlive": false]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path)
    let loaded = ProcessResult(status: 0, stdout: """
    path = \(path.path)
    program = \(profile.gui!.executablePath)
    arguments = {
        \(profile.gui!.executablePath)
        -c
        \(profile.gui!.configPath)
    }
    pid = \(getpid())
    """, stderr: "")
    let missing = ProcessResult(status: 113, stdout: "", stderr: "Could not find service")
    var calls: [String] = []; var removed = false
    let inherited = LaunchdGUIManager(directory: root, runCommand: { args in
        calls.append(args[0]); if args[0] == "bootout" { removed = true; return ProcessResult(status: 0, stdout: "", stderr: "") }
        return removed ? missing : loaded
    })
    try await inherited.stop(profile)
    try check(calls == ["print", "bootout", "print"], "Restart cleans inherited exact owned job, with one finite verification")
    calls.removeAll()
    let unrelated = LaunchdGUIManager(directory: root, runCommand: { args in
        calls.append(args[0]); return ProcessResult(status: 0, stdout: "path = /unrelated.plist", stderr: "")
    })
    do { try await unrelated.stop(profile); throw CheckFailure.failed("Unrelated service stopped") }
    catch is GUIFailure { }
    try check(calls == ["print"], "Unrelated job refused before bootout")

    let foreignFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard foreignFD >= 0 else { throw CheckFailure.failed("Cannot create foreign GUI port fixture") }
    defer { Darwin.close(foreignFD) }
    var foreignAddress = sockaddr_in(); foreignAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    foreignAddress.sin_family = sa_family_t(AF_INET); foreignAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
    foreignAddress.sin_port = 0
    let bound = withUnsafePointer(to: &foreignAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(foreignFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    try check(bound == 0 && Darwin.listen(foreignFD, 1) == 0, "Foreign listener fixture bound")
    var foreignLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &foreignAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(foreignFD, $0, &foreignLength) } }
    var foreign = profile; foreign.gui!.url = "http://127.0.0.1:" + String(UInt16(bigEndian: foreignAddress.sin_port))
    var foreignConfig = config; foreignConfig["port"] = Int(UInt16(bigEndian: foreignAddress.sin_port))
    try JSONSerialization.data(withJSONObject: foreignConfig).write(to: URL(fileURLWithPath: profile.gui!.configPath))
    var foreignCalls: [String] = []
    let foreignManager = LaunchdGUIManager(directory: root, runCommand: { args in foreignCalls.append(args[0]); return missing })
    do { try await foreignManager.start(foreign); throw CheckFailure.failed("Foreign GUI listener adopted") }
    catch let error as GUIFailure { try check(!error.recoverable, "Foreign port fails permanently") }
    try check(foreignCalls == ["print"], "Foreign listener never bootstrapped or stopped")
    try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: profile.gui!.configPath))

    let state = root.appendingPathComponent("runtime.json")
    let lockFD = Darwin.open(state.path + ".lock", O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw CheckFailure.failed("Cannot open fake controller lock") }
    defer { Darwin.close(lockFD) }
    try check(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "Fake controller lock acquired")
    let service = FakeGUI(); let controller = GUIController(profiles: [profile], service: service)
    var controlCommands: [ControllerCommand] = []
    var presetFile: String?
    var presetImpact: PresetImpact?
    let server = GUICommandServer(stateURL: state, controllerHandler: { request in
        controlCommands.append(request.command)
        presetFile = request.presetPath
        presetImpact = request.presetImpact
        let presetReply = request.command == .presets ? PresetSnapshot(profileID: profile.id,
            entries: (0..<32).map { PresetEntry(path: "/tmp/Preset \($0).yml", title: "Preset \($0)",
                available: false, reason: String(repeating: "Incompatible device configuration. ", count: 10)) }, ready: true) : nil
        return ControllerReply(status: ControllerStatus(mode: "automatic", selectedProfileID: profile.id,
            dspState: "idle", outputName: "Speakers", outputUID: "built", suspended: false, profiles: []), presets: presetReply)
    }) { request in
        do { return GUIReply(status: try await controller.command(request.command, profileID: request.profileID)) }
        catch { return GUIReply(error: error.localizedDescription) }
    }
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: GUICommandServer.socketURL(stateURL: state).deletingLastPathComponent())
    }
    let request = GUIRequest(command: .start, profileID: profile.id)
    let reply = try await Task.detached { try GUICommandClient.send(request, stateURL: state) }.value
    try check(reply.status?.desiredRunning == true && reply.error == nil, "GUI command accepts desired state while controller lock held")
    let controlRequest = ControllerRequest(command: .auto, profileID: profile.id)
    let controlReply = try await Task.detached { try ControllerCommandClient.send(controlRequest, stateURL: state) }.value
    try check(controlReply.status?.mode == "automatic" && controlCommands == [.auto], "Controller command routes through shared private socket")
    let legacyStatus = try await Task.detached { try GUICommandClient.send(GUIRequest(command: .status, profileID: profile.id), stateURL: state) }.value
    try check(legacyStatus.status?.profileID == profile.id && controlCommands == [.auto], "Legacy GUI status remains GUI-scoped")
    let legacyAuto = try await Task.detached { try GUICommandClient.send(GUIRequest(command: .auto, profileID: profile.id), stateURL: state) }.value
    try check(legacyAuto.status?.policy == .automatic && controlCommands == [.auto], "Legacy GUI auto is not a DSP command")
    let presetsRequest = ControllerRequest(command: .presets, profileID: profile.id)
    let presetsReply = try await Task.detached { try ControllerCommandClient.send(presetsRequest, stateURL: state) }.value
    try check(presetsReply.presets?.entries.count == 32 && presetsReply.error == nil,
              "Preset catalog replies larger than request limit travel through the bounded shared socket")
    let presetRequest = ControllerRequest(command: .preset, profileID: profile.id, presetPath: "/tmp/Preset with spaces.yml",
        presetImpact: PresetImpact(requiresAudioRestart: true, settingChanges: ["adjust_period: 1 → 2 seconds"]))
    _ = try await Task.detached { try ControllerCommandClient.send(presetRequest, stateURL: state) }.value
    try check(presetFile == presetRequest.presetPath && controlCommands.suffix(2) == [.presets, .preset],
              "Preset selection uses controller scope and preserves structured file paths")
    try check(presetImpact == presetRequest.presetImpact, "Preset restart impact survives the command channel")
    let legacyPreset = try JSONDecoder().decode(ControllerRequest.self,
        from: Data(#"{"scope":"controller","command":"preset","presetPath":"/tmp/Legacy.yml"}"#.utf8))
    try check(legacyPreset.presetImpact == nil, "Legacy preset commands omit optional impact metadata")
    let socketPath = GUICommandServer.socketURL(stateURL: state).path
    try await settled(controller, profile.id, .stopped)
    let callsBeforeMalformed = service.calls
    let malformed = try await Task.detached { try rawGUIRequest(socketPath, data: Data(#"{"command":"destroy","profileID":"gui-test"}"#.utf8)) }.value
    try check(malformed.error?.contains("Invalid command request") == true, "Malformed command rejected without lifecycle mutation")
    try check(service.calls == callsBeforeMalformed, "Malformed request cannot touch services")
    server.stop()
    do {
        _ = try await Task.detached { try GUICommandClient.send(request, stateURL: state) }.value
        throw CheckFailure.failed("Unavailable controller accepted")
    } catch let error as SwitcherError { try check(error.localizedDescription.contains("Controller unavailable"), "Unavailable controller has actionable failure") }
    await controller.shutdown()
}

private func rawGUIRequest(_ path: String, data: Data) throws -> GUIReply {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CheckFailure.failed("Cannot create test socket") }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    withUnsafePointer(to: &timeout) { _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    try check(connected == 0, "Raw test client connected")
    var frame = data; frame.append(10)
    _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    var bytes = [UInt8](repeating: 0, count: 8192)
    let count = Darwin.read(fd, &bytes, bytes.count)
    try check(count > 0, "Raw request receives reply")
    return try JSONDecoder().decode(GUIReply.self, from: Data(bytes.prefix(count)))
}
