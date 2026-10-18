import Foundation

public enum SignalMeterNumericMode: String, Codable, Equatable, Sendable, CaseIterable {
    case realtime
    case peakHold
    public var title: String { self == .realtime ? "Realtime" : "Peak Hold" }
}

public struct SignalMeterOptions: Codable, Equatable, Sendable {
    public var peakHoldMilliseconds: Double
    public var falloffDBPerSecond: Double
    public var refreshHz: Double
    public var minimumDB: Double
    public var maximumDB: Double
    public var numberHoldMilliseconds: Double
    public var numericPeakHoldMilliseconds: Double
    public init(peakHoldMilliseconds: Double = 3000, falloffDBPerSecond: Double = 40, refreshHz: Double = 10,
                minimumDB: Double = -96, maximumDB: Double = 6, numericPeakHoldMilliseconds: Double = 5000, numberHoldMilliseconds: Double = 500) {
        self.peakHoldMilliseconds = peakHoldMilliseconds
        self.falloffDBPerSecond = falloffDBPerSecond
        self.refreshHz = refreshHz
        self.minimumDB = minimumDB; self.maximumDB = maximumDB
        self.numericPeakHoldMilliseconds = numericPeakHoldMilliseconds
        self.numberHoldMilliseconds = numberHoldMilliseconds
    }
    private enum CodingKeys: String, CodingKey { case peakHoldMilliseconds, falloffDBPerSecond, refreshHz, minimumDB, maximumDB, numericPeakHoldMilliseconds, numberHoldMilliseconds }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        peakHoldMilliseconds = try values.decodeIfPresent(Double.self, forKey: .peakHoldMilliseconds) ?? 3000
        falloffDBPerSecond = try values.decodeIfPresent(Double.self, forKey: .falloffDBPerSecond) ?? 40
        refreshHz = try values.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 10
        minimumDB = try values.decodeIfPresent(Double.self, forKey: .minimumDB) ?? -96
        maximumDB = try values.decodeIfPresent(Double.self, forKey: .maximumDB) ?? 6
        // The obsolete legacy numeric hold never supplies the new Realtime hold.
        numberHoldMilliseconds = try values.decodeIfPresent(Double.self, forKey: .numberHoldMilliseconds) ?? 500
        numericPeakHoldMilliseconds = try values.decodeIfPresent(Double.self, forKey: .numericPeakHoldMilliseconds) ?? 5000
    }
    public func validated() throws -> Self {
        guard numberHoldMilliseconds.isFinite, (0...5000).contains(numberHoldMilliseconds) else {
            throw SwitcherError.message("Number hold must be between 0 and 5000 ms")
        }
        guard numericPeakHoldMilliseconds.isFinite, (0...60000).contains(numericPeakHoldMilliseconds) else {
            throw SwitcherError.message("Peak number hold must be between 0 and 60000 ms")
        }
        guard peakHoldMilliseconds.isFinite, (0...10000).contains(peakHoldMilliseconds) else {
            throw SwitcherError.message("Peak hold must be between 0 and 10000 ms")
        }
        guard falloffDBPerSecond.isFinite, falloffDBPerSecond > 0, falloffDBPerSecond <= 120 else {
            throw SwitcherError.message("Meter falloff must be greater than 0 and at most 120 dB/s")
        }
        guard refreshHz.isFinite, (1...120).contains(refreshHz) else {
            throw SwitcherError.message("Meter refresh rate must be between 1 and 120 Hz")
        }
        guard minimumDB.isFinite, maximumDB.isFinite, (-150...20).contains(minimumDB),
              (-150...20).contains(maximumDB), minimumDB < maximumDB else {
            throw SwitcherError.message("Meter display endpoints must be within -150 to +20 dBFS, with minimum below maximum")
        }
        return self
    }
}

public struct MainSliderRange: Codable, Equatable, Sendable {
    public var minimumDB: Double
    public var maximumDB: Double
    public init(minimumDB: Double = -50, maximumDB: Double = 6) {
        self.minimumDB = minimumDB; self.maximumDB = maximumDB
    }
    public func validated() throws -> Self {
        guard minimumDB.isFinite, maximumDB.isFinite,
              (-150...50).contains(minimumDB), (-150...50).contains(maximumDB), minimumDB < maximumDB else {
            throw SwitcherError.message("Main slider endpoints must be within -150 to +50 dB, with minimum below maximum")
        }
        return self
    }
}

/// Application presentation preferences, independent of audio ownership and configuration.
public struct UIPreferences: Codable, Equatable, Sendable {
    public let version: Int
    public var silentMode: Bool
    public var liveLevels: Bool
    public var keepActiveColors: Bool
    public var showMenuBarIcon: Bool
    public var followMacOSOutput: Bool
    public var meterOptions: SignalMeterOptions
    public var meterNumericMode: SignalMeterNumericMode
    public var mainSliderRanges: [String: MainSliderRange]
    public var presetsFolderPath: String?
    public var automaticSwitching: Bool
    public var companionDSPMode: AutomationMode
    public var companionProfileID: String?

    public init(silentMode: Bool = false, liveLevels: Bool = false,
                meterOptions: SignalMeterOptions = .init(), mainSliderRanges: [String: MainSliderRange] = [:], presetsFolderPath: String? = nil,
                keepActiveColors: Bool = false, showMenuBarIcon: Bool = true, followMacOSOutput: Bool = false,
                automaticSwitching: Bool = true, companionDSPMode: AutomationMode = .automatic, companionProfileID: String? = nil,
                meterNumericMode: SignalMeterNumericMode = .realtime) {
        version = 1
        self.silentMode = silentMode
        self.liveLevels = liveLevels
        self.keepActiveColors = keepActiveColors
        self.showMenuBarIcon = showMenuBarIcon
        self.followMacOSOutput = followMacOSOutput
        self.meterNumericMode = meterNumericMode
        self.meterOptions = meterOptions; self.mainSliderRanges = mainSliderRanges
        self.presetsFolderPath = presetsFolderPath
        self.automaticSwitching = automaticSwitching
        self.companionDSPMode = companionDSPMode
        self.companionProfileID = companionProfileID
    }

    public func mainSliderRange(profileID: String?) -> MainSliderRange {
        profileID.flatMap { mainSliderRanges[$0] } ?? MainSliderRange()
    }
    public func validated() throws -> Self {
        if let presetsFolderPath {
            guard !presetsFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  presetsFolderPath.hasPrefix("/"), !presetsFolderPath.contains("\0") else {
                throw SwitcherError.message("Presets folder must be an absolute, nonempty path")
            }
        }
        if let companionProfileID {
            guard !companionProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !companionProfileID.contains("\0") else {
                throw SwitcherError.message("Companion profile ID must be nonempty and contain no NUL characters")
            }
        }
        _ = try meterOptions.validated()
        for (id, range) in mainSliderRanges {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SwitcherError.message("Main slider settings require a profile ID")
            }
            _ = try range.validated()
        }
        return self
    }
    private enum CodingKeys: String, CodingKey { case version, silentMode, liveLevels, keepActiveColors, showMenuBarIcon, followMacOSOutput, meterOptions, meterNumericMode, mainSliderRanges, presetsFolderPath, automaticSwitching, companionDSPMode, companionProfileID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw SwitcherError.message("Unsupported UI preferences version") }
        silentMode = try values.decodeIfPresent(Bool.self, forKey: .silentMode) ?? false
        liveLevels = try values.decodeIfPresent(Bool.self, forKey: .liveLevels) ?? false
        keepActiveColors = try values.decodeIfPresent(Bool.self, forKey: .keepActiveColors) ?? false
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        followMacOSOutput = try values.decodeIfPresent(Bool.self, forKey: .followMacOSOutput) ?? false
        meterOptions = try values.decodeIfPresent(SignalMeterOptions.self, forKey: .meterOptions) ?? .init()
        meterNumericMode = try values.decodeIfPresent(SignalMeterNumericMode.self, forKey: .meterNumericMode) ?? .realtime
        mainSliderRanges = try values.decodeIfPresent([String: MainSliderRange].self, forKey: .mainSliderRanges) ?? [:]
        presetsFolderPath = try values.decodeIfPresent(String.self, forKey: .presetsFolderPath)
        automaticSwitching = try values.decodeIfPresent(Bool.self, forKey: .automaticSwitching) ?? true
        companionDSPMode = try values.decodeIfPresent(AutomationMode.self, forKey: .companionDSPMode) ?? .automatic
        companionProfileID = try values.decodeIfPresent(String.self, forKey: .companionProfileID)
        _ = try validated()
    }
}
