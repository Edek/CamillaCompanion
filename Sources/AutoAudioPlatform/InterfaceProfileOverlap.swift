import Foundation

/// Editor guidance only. Shared devices are valid for alternative profiles;
/// runtime selection and serialized DSP transitions remain authoritative.
package enum InterfaceProfileOverlap {
    package struct Notice {
        package let message: String
        package let automaticAmbiguity: Bool
        package let conflictingProfileIDs: Set<String>
    }

    package static func automaticReplacementProfiles(_ draft: InterfaceProfileDraft,
                                                       against profiles: [InterfaceProfileDraft]) -> [InterfaceProfileDraft] {
        guard draft.autoActivate, !draft.triggerUID.isEmpty else { return [] }
        return profiles.filter {
            $0.id != draft.id && $0.autoActivate && $0.triggerUID == draft.triggerUID
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    package static func automaticReplacementIDs(_ draft: InterfaceProfileDraft,
                                                  against profiles: [InterfaceProfileDraft]) -> Set<String> {
        Set(automaticReplacementProfiles(draft, against: profiles).map(\.id))
    }

    package static func automaticReplacementNames(_ draft: InterfaceProfileDraft,
                                                   against profiles: [InterfaceProfileDraft]) -> [String] {
        let replacements = automaticReplacementProfiles(draft, against: profiles)
        let duplicateNames = Set(replacements.map(\.name)).filter { name in profiles.filter { $0.name == name }.count > 1 }
        return replacements.map { profile in
            duplicateNames.contains(profile.name) ? "\(profile.name) (\(profile.id))" : profile.name
        }
    }

    package static func review(_ draft: InterfaceProfileDraft, against profiles: [InterfaceProfileDraft]) -> Notice? {
        let others = profiles.filter { $0.id != draft.id }
        let automatic = automaticReplacementProfiles(draft, against: profiles)
        if !automatic.isEmpty {
            return Notice(message: "Shares its automatic connection trigger with \(names(automatic)). Confirm which profile should own auto-activation for this trigger.",
                          automaticAmbiguity: true, conflictingProfileIDs: Set(automatic.map(\.id)))
        }
        let devices = Set([draft.captureUID, draft.playbackUID].filter { !$0.isEmpty })
        let shared = others.filter { !devices.isDisjoint(with: [$0.captureUID, $0.playbackUID]) }
        guard !shared.isEmpty else { return nil }
        return Notice(message: "Shares DSP devices with \(names(shared)). Alternative profiles are allowed; only one profile is used at a time.",
                      automaticAmbiguity: false, conflictingProfileIDs: [])
    }

    private static func names(_ profiles: [InterfaceProfileDraft]) -> String {
        let shown = profiles.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ")
        return profiles.count > 3 ? shown + " and others" : shown
    }
}
