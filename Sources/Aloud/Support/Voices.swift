import Foundation

struct VoiceInfo: Identifiable, Hashable {
    let id: String

    var name: String {
        String(id.dropFirst(3)).capitalized
    }

    var group: VoiceGroup {
        switch id.prefix(2) {
        case "af": .usFemale
        case "am": .usMale
        case "bf": .ukFemale
        case "bm": .ukMale
        default: .usFemale
        }
    }
}

enum VoiceGroup: String, CaseIterable {
    case usFemale = "US · Female"
    case usMale = "US · Male"
    case ukFemale = "UK · Female"
    case ukMale = "UK · Male"
}

enum Voices {
    // The 28 voices bundled in voices.npz, from the Kokoro v1.0 release.
    static let all: [VoiceInfo] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ].map(VoiceInfo.init)

    static func grouped() -> [(group: VoiceGroup, voices: [VoiceInfo])] {
        VoiceGroup.allCases.map { group in
            (group, all.filter { $0.group == group })
        }
    }

    static func byID(_ id: String) -> VoiceInfo? {
        all.first { $0.id == id }
    }
}
