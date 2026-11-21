// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Reads the copy tables as source, so it covers every app (Mac, iPhone and
// the Watch app's own WatchCopy) and every string, interpolated or not.
// Fails on an em dash anywhere in the repository (comments too), and in the
// copy tables on words the product no longer uses and on American spellings.
// With KEYRING_COPY_OUT set to a file path, it also writes every user-facing
// string, grouped by table and section, so the whole app reads in one go.

import Foundation
import Testing

@Suite struct EveryWordOnScreen {
    @Test func noEmDashAnywhere() throws {
        var found: [String] = []
        for file in try Repository.trackedTextFiles() {
            for (number, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("\u{2014}") {
                found.append("\(Repository.relative(file)):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(found.isEmpty, "Em dashes (use a comma, colon, full stop or brackets):\n\(found.joined(separator: "\n"))")
    }

    @Test func copyUsesOnlyTodaysWordsInBritishEnglish() throws {
        var found: [String] = []
        for table in try CopyTable.all() {
            for string in table.strings {
                for rule in Rule.all where string.words.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    found.append("\(table.file):\(string.line): \(rule.why): “\(string.words)”")
                }
            }
        }
        #expect(found.isEmpty, "\(found.count) problems in the copy tables:\n\(found.joined(separator: "\n"))")
    }

    @Test func writesEveryStringForReading() throws {
        guard let out = ProcessInfo.processInfo.environment["KEYRING_COPY_OUT"] else { return }
        var text = "# Every user-facing string, by copy table and section\n\n"
        for table in try CopyTable.all() {
            text += "## \(table.file)\n"
            var section = ""
            for string in table.strings {
                if string.section != section {
                    section = string.section
                    text += "\n### \(section)\n\n"
                }
                text += "- \(string.words)\n"
            }
            text += "\n"
        }
        try text.write(toFile: out, atomically: true, encoding: .utf8)
    }
}

struct Rule {
    let pattern: String
    let why: String

    static let all: [Rule] = [
        Rule(pattern: "\u{2014}", why: "em dash"),
        Rule(pattern: " - ", why: "a spaced hyphen standing in for a dash"),
        Rule(pattern: "\\brelay(s|ed|ing)?\\b", why: "“relay” is gone from the product"),
        Rule(pattern: "\\blease(s|d)?\\b", why: "“lease” is not a word he sees"),
        Rule(pattern: "\\bchip keys?\\b", why: "“chip keys” is not a word he sees"),
        Rule(pattern: "always-on mac", why: "there is no always-on Mac"),
    ] + americanisms.map { Rule(pattern: "\\b\($0.us)\\b", why: "American spelling, British is “\($0.uk)”") }

    static let americanisms: [(us: String, uk: String)] = [
        ("color(s|ed)?", "colour"), ("favorite(s)?", "favourite"), ("canceled", "cancelled"), ("canceling", "cancelling"),
        ("center(s|ed)?", "centre"), ("behavior(s)?", "behaviour"), ("gray", "grey"), ("enroll(s|ed|ing|ment)?", "enrol"),
        ("catalog(s)?", "catalogue"), ("license(d)?", "licence (noun)"), ("analyz(e|ed|ing)", "analyse"),
        ("honor(s|ed)?", "honour"), ("labeled", "labelled"), ("traveled", "travelled"), ("modeled", "modelled"),
        ("defense", "defence"), ("offense", "offence"), ("program(s)? (settings|preferences)", "programme"),
    ]
}

/// A copy table, read as source: its string literals, each with its section.
struct CopyTable {
    struct Entry { let words: String; let line: Int; let section: String }
    let file: String
    let strings: [Entry]

    /// The copy tables: every *Copy.swift and *Words.swift file, and the Watch app's WatchCopy.
    static func all() throws -> [CopyTable] {
        let files = try Repository.trackedTextFiles().filter {
            $0.pathExtension == "swift" && ($0.lastPathComponent.contains("Copy") || $0.lastPathComponent.contains("Words"))
                && !$0.path.contains("/Tests/")
        }
        var tables = try files.map { try CopyTable(file: $0) }
        let watch = Repository.root.appendingPathComponent("AgentKeyringWatch/WatchApp.swift")
        if FileManager.default.fileExists(atPath: watch.path) { tables.append(try CopyTable(file: watch, onlyType: "WatchCopy")) }
        return tables.sorted { $0.file < $1.file }
    }

    init(file: URL, onlyType: String? = nil) throws {
        self.file = Repository.relative(file)
        let source = try String(contentsOf: file, encoding: .utf8)
        var entries: [Entry] = []
        var section = "", type = ""
        var depth = 0, typeDepth = -1
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") {
                if code.hasPrefix("// MARK:") { section = type + ": " + code.dropFirst(8).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let name = Self.typeName(code), depth <= 1 {
                type = name
                section = name
                typeDepth = depth
            }
            let inScope = onlyType == nil || type == onlyType
            if inScope, !code.hasPrefix("import "), !code.contains("Logger("), !code.contains("subsystem:") {
                for literal in Self.literals(in: line) where Self.isWords(literal) {
                    entries.append(Entry(words: literal, line: number + 1, section: section))
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth <= typeDepth { type = ""; typeDepth = -1 }
        }
        strings = entries
    }

    static func typeName(_ code: String) -> String? {
        let words = code.split(separator: " ").map(String.init)
        guard let index = words.firstIndex(where: { ["enum", "struct", "extension"].contains($0) }), index + 1 < words.count else { return nil }
        return words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "{:<"))
    }

    /// Words a person reads: a letter in it, and more than an identifier or a key.
    static func isWords(_ literal: String) -> Bool {
        literal.contains { $0.isLetter } && (literal.contains(" ") || literal.first?.isUppercase == true)
    }

    /// The string literals on one line, with interpolations kept as written.
    static func literals(in line: String) -> [String] {
        var found: [String] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" { break }
            guard characters[index] == "\"" else { index += 1; continue }
            var literal = "", depth = 0
            index += 1
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count {
                    if characters[index + 1] == "(" { depth += 1 }
                    literal.append(character); literal.append(characters[index + 1]); index += 2; continue
                }
                if depth > 0 {
                    if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                    literal.append(character); index += 1; continue
                }
                if character == "\"" { break }
                literal.append(character)
                index += 1
            }
            found.append(literal)
            index += 1
        }
        return found
    }
}

enum Repository {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func relative(_ file: URL) -> String { String(file.path.dropFirst(root.path.count + 1)) }

    /// Every file git tracks that is text a person or an agent reads.
    static func trackedTextFiles() throws -> [URL] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        git.waitUntilExit()
        let kinds: Set<String> = ["swift", "go", "md", "txt", "json", "plist", "strings", "sh", "js", "html", "py", "nix", "proto"]
        return output.split(separator: "\n").map { root.appendingPathComponent(String($0)) }
            .filter { kinds.contains($0.pathExtension) && FileManager.default.fileExists(atPath: $0.path) }
    }
}
