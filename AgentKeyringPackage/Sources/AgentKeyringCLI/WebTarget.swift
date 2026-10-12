import ArgumentParser
import Foundation

func normaliseWebTarget(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: target),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        components.host?.isEmpty == false
    else {
        throw ValidationError(
            "'\(value)' is not a valid site or page URL. Use a site such as example.com."
        )
    }
    return target
}

func normaliseSecureWebTarget(_ value: String) throws -> String {
    let target = try normaliseWebTarget(value)
    guard let components = URLComponents(string: target),
        let host = components.host?.lowercased()
    else { return target }
    let localhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
    guard components.scheme?.lowercased() == "https" || localhost else {
        throw ValidationError(
            "Agent Keyring will not release credentials to an insecure page. Use the HTTPS page instead."
        )
    }
    return target
}

func displayHost(_ targetURL: String) -> String {
    URLComponents(string: targetURL)?.host ?? targetURL
}
