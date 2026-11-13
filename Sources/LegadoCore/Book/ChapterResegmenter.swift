import Foundation

/// Port of Android ContentHelp's paragraph repair, dialogue and quoted-word rules.
/// UTF-16 offsets match Kotlin Char/String indexes. Long-paragraph splitting uses a
/// content-derived seed so reopening a chapter does not move its reading position.
struct ChapterResegmenter {
    private static let sentenceEnd = "？。！?!~"
    private static let sentenceEndP = ".？。！?!~"
    private static let sentenceMid = ".，、,—…"
    private static let sentenceSay = "问说喊唱叫骂道着答"
    private static let quoteBefore = "，：,:"
    private static let quote = "\"“”"
    private static let quoteRight = "\"”"
    private static let trimCharacters = CharacterSet(charactersIn: (0...32).compactMap(UnicodeScalar.init).map(String.init).joined())

    func process(_ content: String, chapterName: String) -> String {
        guard !content.isEmpty else { return content }
        let dictionary = makeDictionary(content)
        var random = StableRandom(content)
        var value = replace(content, #"&quot;"#, "“")
        value = replace(value, #"[:：]['"‘”“]+"#, "：“")
        value = replace(value, #"["”“]+\s*["”“][\s"”“]*"#, "”\n“")
        let paragraphs = replace(value, #"\n(\s*)"#, "\n").components(separatedBy: "\n")
        var buffer = Array("  ".utf16)
        if let first = paragraphs.first,
           first.trimmingCharacters(in: Self.trimCharacters) != chapterName.trimmingCharacters(in: Self.trimCharacters) {
            buffer += replace(first, #"[\u3000\s]+"#, "").utf16
        }
        for paragraph in paragraphs.dropFirst() {
            if let last = buffer.last,
               Self.contains(Self.sentenceEnd, last)
                || (Self.contains(Self.quoteRight, last) && buffer.count > 1 && Self.contains(Self.sentenceEnd, buffer[buffer.count - 2])) {
                buffer.append(10)
            }
            buffer += replace(paragraph, #"[\u3000\s]"#, "").utf16
        }
        value = replace(Self.string(buffer), #"["”“]+\s*["”“]+"#, "”\n“")
        // Keep the reference's expressions, including its literal punctuation group.
        value = replace(value, #"["”“]+(？。！?!~)["”“]+"#, "”$1\n“")
        value = replace(value, #"["”“]+(？。！?!~)([^"”“])"#, "”$1\n$2")
        value = replace(value, #"([问说喊唱叫骂道着答])[\.。]"#, "$1。\n")
        value = value.components(separatedBy: "\n").map {
            "\n" + findNewLines($0, dictionary: dictionary, random: &random)
        }.joined()
        value = reduceLength(value)
        value = replace(value, #"^\s+"#, "")
        value = replace(value, #"\s*["”“]+\s*["”“][\s"”“]*"#, "”\n“")
        value = replace(value, #"[:：][”“"\s]+"#, "：“")
        value = replace(value, #"\n["“”]([^\n"“”]+)([,:，：]["”“])([^\n"“”]+)"#, "\n$1：“$3")
        return replace(value, #"\n(\s*)"#, "\n")
    }

    private func reduceLength(_ content: String) -> String {
        var paragraphs = content.components(separatedBy: "\n")
        let dialogue = paragraphs.map { $0.range(of: #"^["”“][^"”“]+["”“]$"#, options: .regularExpression) != nil }
        var state = 0
        for index in paragraphs.indices {
            if dialogue[index] {
                if state < 0 { state = 1 } else if state < 2 { state += 1 }
            } else if state > 1 {
                paragraphs[index] = splitQuote(paragraphs[index])
                state -= 1
            } else if state > 0 && index < paragraphs.count - 2 && dialogue[index + 1] {
                paragraphs[index] = splitQuote(paragraphs[index])
            }
        }
        return paragraphs.map { "\n" + $0 }.joined()
    }

    private func splitQuote(_ value: String) -> String {
        let text = Array(value.utf16)
        guard text.count >= 3 else { return value }
        let index: Int
        if Self.contains(Self.quote, text[0]) {
            index = seekIndex(text, key: Self.quote, from: 1, to: text.count - 2, forward: true) + 1
        } else if Self.contains(Self.quote, text[text.count - 1]) {
            index = text.count - 1 - seekIndex(text, key: Self.quote, from: 1, to: text.count - 2, forward: false)
        } else { return value }
        guard index > 1, index <= text.count, !Self.contains(Self.quoteBefore, text[index - 1]) else { return value }
        return Self.string(text[..<index]) + "\n" + Self.string(text[index...])
    }

    private func forceSplit(_ text: [UInt16], offset: Int, minimum: Int, gain: Int, trigger: Int, random: inout StableRandom) -> [Int] {
        let ends = seekIndexes(text, key: Self.sentenceEndP, from: 0, to: text.count - 2)
        let middles = seekIndexes(text, key: Self.sentenceMid, from: 0, to: text.count - 2)
        guard ends.count >= trigger || middles.count >= trigger * 3 else { return [] }
        var result: [Int] = []
        var middle = 0
        var index = minimum
        while index < ends.count {
            var count = 0
            while middle < middles.count {
                if middles[middle] < ends[index] { count += 1 }
                middle += 1
            }
            if random.next() * Double(gain) < 0.8 + Double(count) / 2.5 {
                result.append(ends[index] + offset)
                index += minimum
            }
            index += 1
        }
        return result
    }

    private func findNewLines(_ value: String, dictionary: Set<String>, random: inout StableRandom) -> String {
        let original = Array(value.utf16)
        guard !original.isEmpty else { return value }
        var text = original
        var quotes: [Int] = []
        var newlines: [Int] = []
        var modes = [Int](repeating: 0, count: original.count)
        var waitingForClose = false
        for index in original.indices where Self.contains(Self.quote, original[index]) {
            let size = quotes.count
            if let previous = quotes.last, index - previous == 2 {
                let separators = waitingForClose ? ",，、/" : ",，、/和与或"
                if Self.contains(separators, original[index - 1]) {
                    text[index] = 0x201C
                    text[index - 2] = 0x201D
                    quotes.removeLast()
                    modes[size - 1] = 1
                    modes[size] = -1
                    continue
                }
            }
            quotes.append(index)
            if index > 1 {
                let before = original[index - 1]
                if Self.contains(Self.quoteBefore, before) {
                    if quotes.count > 1 {
                        let lastQuote = quotes[quotes.count - 2]
                        var position = 0
                        var previousBefore: UInt16 = 0
                        if Self.contains(",，", before), quotes.count > 2 {
                            position = quotes[quotes.count - 3]
                            if position > 0 { previousBefore = original[position - 1] }
                        }
                        if Self.contains(Self.sentenceEndP, previousBefore) {
                            newlines.append(position - 1)
                        } else if !Self.contains("的", previousBefore) {
                            let end = seekLast(original, key: Self.sentenceEnd, from: index, to: lastQuote)
                            newlines.append(end > 0 ? end : lastQuote)
                        }
                    }
                    waitingForClose = true
                    modes[size] = 1
                    if size > 0 {
                        modes[size - 1] = -1
                        if size > 1 { modes[size - 2] = 1 }
                    }
                } else if waitingForClose {
                    waitingForClose = false
                    newlines.append(index)
                }
            }
        }

        var open = false
        for index in quotes.indices {
            if modes[index] > 0 { open = true }
            else if modes[index] < 0 {
                if !open && index > 0 { modes[index] = 3 }
                open = false
            } else {
                open.toggle()
                modes[index] = open ? 2 : -2
            }
        }
        if open, let last = quotes.last {
            if last - text.count > -3 {
                if quotes.count > 1 { modes[quotes.count - 2] = 4 }
                modes[quotes.count - 1] = -4
            } else if text.count > 1 && !Self.contains(Self.sentenceSay, text[text.count - 2]) {
                text.append(0x201D)
            }
        }
        var previousMode = -1
        for index in quotes.indices {
            let before = quotes[index] - 1
            if before < 0 { previousMode = 0; continue }
            if previousMode < 0 && modes[index] > 0 && Self.contains(Self.sentenceEnd, text[before]) {
                newlines.append(before)
            }
            previousMode = modes[index]
        }
        newlines = newlines.filter { index in
            guard original.indices.contains(index) else { return false }
            if Self.contains("\"'”“", text[index]) {
                let start = seekLast(original, key: "\"'”“", from: index - 1, to: index - 16)
                if start > 0 {
                    let word = Self.string(original[(start + 1)..<index])
                    if dictionary.contains(word) || Self.contains("的地得", original[start]) { return false }
                }
            }
            return true
        }
        newlines = Array(Set(newlines)).sorted()
        var cursor = 0
        var progress = 0
        var nextLine = newlines.first ?? -1
        var gain = 3
        var minimum = 0
        var trigger = 2
        for quote in quotes {
            gain = quote > 0 ? 4 : 3
            minimum = quote > 0 ? 2 : 0
            trigger = quote > 0 ? 4 : 2
            while cursor < newlines.count {
                if nextLine >= quote { break }
                nextLine = newlines[cursor]
                if progress < nextLine {
                    newlines += forceSplit(Array(text[progress..<nextLine]), offset: progress,
                        minimum: minimum, gain: gain, trigger: trigger, random: &random)
                    progress = nextLine + 1
                }
                cursor += 1
            }
            if progress < quote {
                newlines += forceSplit(Array(text[progress...quote]), offset: progress,
                    minimum: minimum, gain: gain, trigger: trigger, random: &random)
                progress = quote + 1
            }
        }
        while cursor < newlines.count {
            nextLine = newlines[cursor]
            if progress < nextLine {
                newlines += forceSplit(Array(text[progress..<nextLine]), offset: progress,
                    minimum: minimum, gain: gain, trigger: trigger, random: &random)
                progress = nextLine + 1
            }
            cursor += 1
        }
        if progress < text.count {
            newlines += forceSplit(Array(text[progress...]), offset: progress,
                minimum: minimum, gain: gain, trigger: trigger, random: &random)
        }

        var insertQuote = [Bool](repeating: false, count: quotes.count)
        open = false
        for index in quotes.indices {
            if modes[index] > 0 {
                text[quotes[index]] = 0x201C
                insertQuote[index] = open
                open = true
            } else if modes[index] < 0 {
                text[quotes[index]] = 0x201D
                open = false
            } else {
                open.toggle()
                text[quotes[index]] = open ? 0x201C : 0x201D
            }
        }
        newlines = Array(Set(newlines)).sorted()
        var result: [UInt16] = []
        cursor = 0
        progress = 0
        nextLine = newlines.first ?? -1
        for index in quotes.indices {
            let quote = quotes[index]
            while cursor < newlines.count {
                if nextLine >= quote { break }
                nextLine = newlines[cursor]
                if progress <= nextLine + 1 {
                    result += text[progress..<(nextLine + 1)]
                    result.append(10)
                    progress = nextLine + 1
                }
                cursor += 1
            }
            if progress < quote {
                result += text[progress...quote]
                progress = quote + 1
            }
            if insertQuote[index] && result.count > 2 {
                if result.last == 10 { result.append(0x201C) }
                else { result.insert(contentsOf: [0x201D, 10], at: result.count - 1) }
            }
        }
        while cursor < newlines.count {
            nextLine = newlines[cursor]
            if progress <= nextLine {
                result += text[progress...nextLine]
                result.append(10)
                progress = nextLine + 1
            }
            cursor += 1
        }
        if progress < text.count { result += text[progress...] }
        return Self.string(result)
    }

    private func makeDictionary(_ value: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(pattern: #"(?<=["'”“])([^\n\p{P}]{1,16})(?=["'”“])"#) else { return [] }
        var seen: Set<String> = []
        var repeated: Set<String> = []
        let text = value as NSString
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let word = text.substring(with: match.range)
            if !seen.insert(word).inserted { repeated.insert(word) }
        }
        return repeated
    }

    private func seekIndexes(_ text: [UInt16], key: String, from: Int, to: Int) -> [Int] {
        let start = max(0, from)
        let end = to > 0 ? min(text.count, to) : text.count
        guard start < end else { return [] }
        var result: [Int] = []
        for index in start..<end where Self.contains(key, text[index]) {
            if let last = result.last, index - last == 1 { result[result.count - 1] = index }
            else { result.append(index) }
        }
        return result
    }

    private func seekLast(_ text: [UInt16], key: String, from: Int, to: Int) -> Int {
        guard !text.isEmpty, from >= 0, from < text.count else { return -1 }
        let lower = max(0, to)
        var index = min(text.count - 1, from)
        while index > lower {
            if Self.contains(key, text[index]) { return index }
            index -= 1
        }
        return -1
    }

    private func seekIndex(_ text: [UInt16], key: String, from: Int, to: Int, forward: Bool) -> Int {
        let start = max(0, from)
        let end = to > 0 ? min(text.count, to) : text.count
        guard start < end else { return -1 }
        for index in start..<end where Self.contains(key, text[forward ? index : text.count - index - 1]) { return index }
        return -1
    }

    private func replace(_ value: String, _ pattern: String, _ replacement: String) -> String {
        // Java's default \s is ASCII; ICU's \s also matches NBSP and other
        // Unicode spaces. Preserve those characters as the reference does.
        let characters = Array(pattern)
        var compatible = ""
        var inClass = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                if characters[index + 1] == "s" {
                    compatible += inClass ? #"\x09-\x0D\x20"# : #"[\x09-\x0D\x20]"#
                } else {
                    compatible.append(character)
                    compatible.append(characters[index + 1])
                }
                index += 2
                continue
            }
            if character == "[" { inClass = true }
            else if character == "]" { inClass = false }
            compatible.append(character)
            index += 1
        }
        guard let regex = try? NSRegularExpression(pattern: compatible) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }

    private static func contains(_ characters: String, _ character: UInt16) -> Bool { characters.utf16.contains(character) }
    private static func string<T: Collection>(_ text: T) -> String where T.Element == UInt16 { String(decoding: text, as: UTF16.self) }

    private struct StableRandom {
        var state: UInt64 = 14695981039346656037
        init(_ value: String) {
            for character in value.utf16 { state = (state ^ UInt64(character)) &* 1099511628211 }
        }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
    }
}
