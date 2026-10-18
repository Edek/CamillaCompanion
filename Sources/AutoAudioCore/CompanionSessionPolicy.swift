import Foundation

/// Companion sessions select one DSP, independent of default-output routing.
enum CompanionSessionPolicy {
    static func selectedProfileID(_ requested: String?, profiles: [Profile]) -> String? {
        requested ?? (profiles.count == 1 ? profiles.first?.id : nil)
    }

    static func available(_ profile: Profile, in snapshot: AudioSnapshot) -> Bool {
        let outputs = Set(snapshot.devices.filter(\.hasOutput).map(\.uid))
        return outputs.contains(profile.captureUID) && outputs.contains(profile.playbackUID)
    }
}
