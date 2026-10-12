import Foundation

struct PublicSuffixList: Sendable {
    static let shared = PublicSuffixList()
    private let rules: Set<String>

    private init() {
        let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat")!
        let contents = try! String(contentsOf: url, encoding: .utf8)
        rules = Set(contents.split(separator: "\n").filter { !$0.hasPrefix("//") }.map {
            let rule = String($0).trimmingCharacters(in: .whitespaces)
            let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
            let host = String(rule.dropFirst(prefix.count))
            return prefix + (URL(string: "https://\(host)")?.host ?? host).lowercased()
        })
    }

    func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        var suffixLength = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                return false
            }
            if rules.contains(suffix) {
                suffixLength = max(suffixLength, labels.count - index)
            }
            if index > 0, rules.contains("*." + suffix) {
                suffixLength = max(suffixLength, labels.count - index + 1)
            }
        }
        return labels.count == suffixLength
    }
}
