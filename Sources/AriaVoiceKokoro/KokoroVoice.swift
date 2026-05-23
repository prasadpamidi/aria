// `canImport(KokoroSwift)` becomes true only when the `VoiceKokoro`
// trait is enabled on the consuming package; otherwise the
// `kokoro-ios` dep isn't resolved and this whole file compiles
// to nothing. Same pattern AriaMLX uses for the `MLX` trait.
#if ARIA_VOICE_KOKORO
    import Foundation
    import KokoroSwift

    // MARK: - KokoroVoice

    /// One of Kokoro's 28 ship-with voices. The enum exists so the
    /// catalog lives in code (typed groups, display names, default
    /// pick) rather than scattering string literals across picker UI
    /// and the provider.
    ///
    /// Voice id convention from upstream:
    ///   - First char: 'a' → American English, 'b' → British English
    ///   - Second char: 'f' → female timbre, 'm' → male timbre
    ///   - Remainder: friendly first name
    ///
    /// The voices file (`voices.npz`) stores embeddings keyed by
    /// `"<id>.npy"` (e.g. `"af_heart.npy"`). `npzKey` returns the
    /// match for that lookup so the provider doesn't have to know the
    /// upstream convention.
    public enum KokoroVoice: String, CaseIterable, Identifiable, Codable, Sendable {
        // American Female
        case afAlloy = "af_alloy"
        case afAoede = "af_aoede"
        case afBella = "af_bella"
        case afHeart = "af_heart"
        case afJessica = "af_jessica"
        case afKore = "af_kore"
        case afNicole = "af_nicole"
        case afNova = "af_nova"
        case afRiver = "af_river"
        case afSarah = "af_sarah"
        case afSky = "af_sky"
        // American Male
        case amAdam = "am_adam"
        case amEcho = "am_echo"
        case amEric = "am_eric"
        case amFenrir = "am_fenrir"
        case amLiam = "am_liam"
        case amMichael = "am_michael"
        case amOnyx = "am_onyx"
        case amPuck = "am_puck"
        case amSanta = "am_santa"
        // British Female
        case bfAlice = "bf_alice"
        case bfEmma = "bf_emma"
        case bfIsabella = "bf_isabella"
        case bfLily = "bf_lily"
        // British Male
        case bmDaniel = "bm_daniel"
        case bmFable = "bm_fable"
        case bmGeorge = "bm_george"
        case bmLewis = "bm_lewis"

        // MARK: Public

        public enum Group: String, CaseIterable, Identifiable, Sendable {
            case americanFemale
            case americanMale
            case britishFemale
            case britishMale

            // MARK: Public

            public var id: String {
                self.rawValue
            }

            public var displayName: String {
                switch self {
                case .americanFemale: "American · Female"
                case .americanMale: "American · Male"
                case .britishFemale: "British · Female"
                case .britishMale: "British · Male"
                }
            }
        }

        /// Voices grouped for the picker. Order matches `Group.allCases`
        /// so the four sections always render in the same sequence.
        public static var grouped: [(group: Group, voices: [KokoroVoice])] {
            Group.allCases.map { group in
                (group, KokoroVoice.allCases.filter { $0.group == group })
            }
        }

        /// Reasonable starting voice — warm, conversational, neutral
        /// American Female. Easy to change in settings later, but
        /// shipping with `af_heart` is the convention upstream uses too.
        public static var defaultVoice: KokoroVoice {
            .afHeart
        }

        public var id: String {
            self.rawValue
        }

        /// Filename key inside `voices.npz`. The bundle stores
        /// embeddings as `"af_heart.npy"`, not `"af_heart"`, so all
        /// lookups have to suffix `.npy`.
        public var npzKey: String {
            "\(self.rawValue).npy"
        }

        /// Friendly name for the picker — just the first-name portion
        /// of the id, capitalized. Group + accent are surfaced
        /// separately so the row reads `"Heart"` under `"American · Female"`
        /// rather than repeating "American Female Heart" on every row.
        public var displayName: String {
            let parts = self.rawValue.split(separator: "_")
            guard parts.count == 2 else {
                return self.rawValue.capitalized
            }
            return parts[1].capitalized
        }

        /// Which `KokoroSwift.Language` this voice was trained on.
        /// `a*` → American (`enUS`), `b*` → British (`enGB`).
        public var language: Language {
            self.rawValue.first == "a" ? .enUS : .enGB
        }

        /// Display group used by voice pickers to section the list.
        public var group: Group {
            let prefix = self.rawValue.prefix(2)
            return switch prefix {
            case "af": .americanFemale
            case "am": .americanMale
            case "bf": .britishFemale
            case "bm": .britishMale
            default: .americanFemale
            }
        }
    }
#endif
