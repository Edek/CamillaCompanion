import Foundation

/// Companion sessions select one DSP, independent of default-output routing.
enum CompanionSessionPolicy {
    static func selectedProfileID(_ requested: String?, profiles: [Profile]) -> String? {
        requested ?? (profiles.count == 1 ? profiles.first?.id : nil)
    }

    static func available(_ profile: Profile, in snapshot: AudioSnapshot, requireTrigger: Bool = true) -> Bool {
        profile.deviceRolesAvailable(in: snapshot, automaticSwitching: false, requireTrigger: requireTrigger)
    }
}
