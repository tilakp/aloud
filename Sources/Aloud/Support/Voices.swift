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
        default: .usFemale
        }
    }
}

enum VoiceGroup: String, CaseIterable {
    case usFemale = "US · Female"
    case usMale = "US · Male"
}

enum Voices {
    // The US voices from the Kokoro v1.0 release. The UK ones are left out
    // because FluidAudio's English frontend only has a US lexicon, so they
    // would speak with US pronunciation.
    static let all: [VoiceInfo] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
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
