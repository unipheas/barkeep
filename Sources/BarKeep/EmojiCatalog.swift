import Foundation

struct Emoji: Identifiable, Hashable {
    let char: String
    let name: String
    var id: String { char }
}

/// Builds the full emoji list from Unicode scalar properties — no bundled
/// data files. Searchable via each scalar's official Unicode name.
enum EmojiCatalog {
    static let all: [Emoji] = build()

    static func search(_ query: String) -> [Emoji] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let terms = trimmed.uppercased().split(separator: " ").map(String.init)
        return all.filter { emoji in
            terms.allSatisfy { emoji.name.contains($0) }
        }
    }

    private static func build() -> [Emoji] {
        // Ranges covering emoji blocks (symbols, pictographs, transport,
        // supplemental, extended). Digits/keycaps excluded by category check.
        let ranges: [ClosedRange<UInt32>] = [
            0x2190...0x2BFF,     // arrows, misc symbols, dingbats
            0x1F000...0x1F02F,   // mahjong, dominoes
            0x1F0A0...0x1F0FF,   // playing cards
            0x1F300...0x1F5FF,   // misc symbols & pictographs
            0x1F600...0x1F64F,   // emoticons
            0x1F680...0x1F6FF,   // transport
            0x1F700...0x1F77F,   // alchemical
            0x1F900...0x1F9FF,   // supplemental symbols
            0x1FA70...0x1FAFF,   // extended-A
        ]

        var result: [Emoji] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let props = scalar.properties
                guard props.isEmoji, !props.isEmojiModifier else { continue }
                guard let name = props.name else { continue }

                if props.isEmojiPresentation {
                    result.append(Emoji(char: String(scalar), name: name))
                } else if props.generalCategory == .otherSymbol {
                    // Text-presentation symbols (☀ ❤ ✈ …) need VS16 to render as emoji.
                    result.append(Emoji(char: String(scalar) + "\u{FE0F}", name: name))
                }
            }
        }
        return result
    }
}
