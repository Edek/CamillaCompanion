import AppKit
import CoreAudio
import AutoAudioCore

/// CoreAudio callbacks only. No recurring timers or background sampling.
@MainActor public final class CoreAudioManager: AudioManaging {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var handler: (@MainActor (AudioEvent) -> Void)?
    private var registrations: [ListenerRegistration] = []
    private var deviceRegistrations: [AudioDeviceID: [ListenerRegistration]] = [:]
    private var wakeRegistration: WakeRegistration?
    private var monitoringGeneration = UUID()
    public init() {}

    public func snapshot() throws -> AudioSnapshot {
        let ids = try deviceIDs()
        if handler != nil { try updateDeviceListeners(ids) }
        var devices: [AudioDevice] = []
        for id in ids {
            let alive = try uint32(id, kAudioDevicePropertyDeviceIsAlive)
            guard alive != 0 else { continue }
            devices.append(AudioDevice(
                uid: try string(id, kAudioDevicePropertyDeviceUID),
                name: try string(id, kAudioObjectPropertyName),
                inputChannels: try channelCount(id, scope: kAudioDevicePropertyScopeInput),
                outputChannels: try channelCount(id, scope: kAudioDevicePropertyScopeOutput),
                isBuiltIn: try uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
            ))
        }
        guard Set(devices.map(\.uid)).count == devices.count else {
            throw SwitcherError.message("CoreAudio returned duplicate device UIDs; routing is ambiguous.")
        }
        return AudioSnapshot(devices: devices,
                             outputUID: try defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
                             alertUID: try defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice))
    }

    public func setOutput(uid: String) throws { try setDefault(uid, kAudioHardwarePropertyDefaultOutputDevice) }
    public func setAlertOutput(uid: String) throws { try setDefault(uid, kAudioHardwarePropertyDefaultSystemOutputDevice) }

    public func startMonitoring(_ handler: @escaping @MainActor (AudioEvent) -> Void) throws {
        stopMonitoring()
        self.handler = handler
        do {
            registrations.append(try listen(system, kAudioHardwarePropertyDevices, event: .devicesChanged))
            registrations.append(try listen(system, kAudioHardwarePropertyDefaultOutputDevice, event: .outputChanged))
            registrations.append(try listen(system, kAudioHardwarePropertyDefaultSystemOutputDevice, event: .outputChanged))
            try updateDeviceListeners(deviceIDs())
            let center = NSWorkspace.shared.notificationCenter
            let generation = monitoringGeneration
            let token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.monitoringGeneration == generation else { return }
                    self.handler?(.woke)
                }
            }
            wakeRegistration = WakeRegistration(center: center, token: token)
        } catch {
            stopMonitoring()
            throw error
        }
    }

    public func stopMonitoring() {
        handler = nil
        monitoringGeneration = UUID()
        registrations.removeAll()
        deviceRegistrations.removeAll()
        wakeRegistration = nil
    }

    private func updateDeviceListeners(_ ids: [AudioDeviceID]) throws {
        let present = Set(ids)
        for id in Array(deviceRegistrations.keys) where !present.contains(id) { deviceRegistrations.removeValue(forKey: id) }
        for id in ids where deviceRegistrations[id] == nil {
            var added: [ListenerRegistration] = []
            let changes: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
                (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
                (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
            ]
            for (selector, scope) in changes {
                var property = address(selector, scope: scope)
                if AudioObjectHasProperty(id, &property) {
                    added.append(try listen(id, selector, scope: scope, event: .devicesChanged))
                }
            }
            deviceRegistrations[id] = added
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        event: AudioEvent) throws -> ListenerRegistration {
        var property = address(selector, scope: scope)
        let generation = monitoringGeneration
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.monitoringGeneration == generation else { return }
                self.handler?(event)
            }
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &property, .main, block), "Register audio notification")
        return ListenerRegistration(object: object, address: property, block: block)
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "Read device list size")
        guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw SwitcherError.message("CoreAudio returned an invalid device list size.")
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let capacity = size
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!)
        }
        try check(status, "Read device list")
        guard size <= capacity, size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw SwitcherError.message("CoreAudio device list changed during enumeration.")
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard AudioObjectHasProperty(id, &property) else { return 0 }
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read stream configuration for device \(id)")
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage), "Read stream configuration for device \(id)")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func defaultUID(_ selector: AudioObjectPropertySelector) throws -> String? {
        let id = try uint32(system, selector)
        return id == kAudioObjectUnknown ? nil : try string(id, kAudioDevicePropertyDeviceUID)
    }

    private func setDefault(_ uid: String, _ selector: AudioObjectPropertySelector) throws {
        let matches = try deviceIDs().filter { try string($0, kAudioDevicePropertyDeviceUID) == uid }
        guard matches.count == 1, var id = matches.first else {
            throw SwitcherError.message("Output UID '\(uid)' is missing or ambiguous.")
        }
        guard try uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
              try channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0 else {
            throw SwitcherError.message("Device '\(uid)' is not an available output.")
        }
        var property = address(selector)
        try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id), "Set default output")
        guard try defaultUID(selector) == uid else {
            throw SwitcherError.message("CoreAudio did not confirm the requested output '\(uid)'.")
        }
    }

    private func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "Read audio property \(selector) on \(id)")
        guard size == MemoryLayout<UInt32>.size else { throw SwitcherError.message("Unexpected audio property size.") }
        return value
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "Read audio device identity")
        guard let value else { throw SwitcherError.message("CoreAudio returned an empty device identity.") }
        // AudioHardwareBase.h specifies caller ownership for both name and UID.
        return value.takeRetainedValue() as String
    }

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SwitcherError.message("\(operation) failed (CoreAudio \(status)).") }
    }
}

private final class ListenerRegistration {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    init(object: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object; self.address = address; self.block = block
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}

private final class WakeRegistration {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}
