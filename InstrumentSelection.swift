import Foundation

/// The locally parsed watchlist. Availability is checked against OKX before it is saved.
struct InstrumentSelection {
    static let defaultIDs = ["MU-USDT-SWAP"]
    static let maxCount = 20

    enum InputError: LocalizedError {
        case empty
        case malformed(String)
        case tooMany(Int)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "请至少输入一个标的，例如 MU、BTC 或 BTC-USDT。"
            case .malformed(let token):
                return "“\(token)”的格式不正确。可输入 MU（USDT 永续）、BTC-USDT（现货），或 OKX 的完整合约代码，例如 BTC-USD-261225、BTC-USD-261225-100000-C。"
            case .tooMany(let count):
                return "最多支持 \(InstrumentSelection.maxCount) 个不同标的，当前输入了 \(count) 个。"
            }
        }
    }

    static func parse(_ text: String) throws -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",，;；、"))
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw InputError.empty }

        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let normalized = token.uppercased().replacingOccurrences(of: "/", with: "-")
            let id: String
            if validAsset(normalized) {
                id = "\(normalized)-USDT-SWAP"
            } else if validInstrumentID(normalized) {
                id = normalized
            } else {
                throw InputError.malformed(token)
            }
            if seen.insert(id).inserted { result.append(id) }
        }
        guard result.count <= maxCount else { throw InputError.tooMany(result.count) }
        return result
    }

    static func displayName(for id: String) -> String {
        let parts = id.uppercased().components(separatedBy: "-")
        if parts.count == 3, parts[2] == "SWAP" {
            return parts[1] == "USDT" ? parts[0] : "\(parts[0])/\(parts[1])"
        }
        if parts.count == 2 { return "\(parts[0])/\(parts[1])" }
        return id.uppercased()
    }

    static func quoteCurrency(for id: String) -> String {
        let parts = id.uppercased().components(separatedBy: "-")
        if parts.count == 5, parts[4] == "C" || parts[4] == "P" {
            // Coin-margined option premiums are quoted in BTC/ETH, unlike their USD strikes.
            if parts[1] == "USD" { return parts[0] }
            if parts[1] == "USD_UM" { return "USD" }
        }
        return parts.count >= 2 ? parts[1] : "USDT"
    }

    static func marketName(for id: String) -> String {
        let parts = id.uppercased().components(separatedBy: "-")
        if parts.count == 3, parts[2] == "SWAP" { return "永续" }
        if parts.count == 5, parts[4] == "C" || parts[4] == "P" { return "期权" }
        if parts.count == 3 { return "交割" }
        return "现货"
    }

    static func tradingURL(for id: String) -> URL? {
        let normalized = id.uppercased()
        guard validInstrumentID(normalized) else { return nil }
        let parts = normalized.components(separatedBy: "-")
        let route: String
        let slug: String
        switch marketName(for: normalized) {
        case "永续":
            route = "trade-swap"
            slug = normalized.lowercased()
        case "交割":
            route = "trade-futures"
            slug = normalized.lowercased()
        case "期权":
            // OKX's option screen is an underlying's chain, rather than a contract page.
            route = "trade-option"
            slug = "\(parts[0])-\(parts[1] == "USD_UM" ? "USD" : parts[1])".lowercased()
        default:
            route = "trade-spot"
            slug = normalized.lowercased()
        }
        return URL(string: "https://www.okx.com/\(route)/\(slug)")
    }

    private static func validAsset(_ value: String) -> Bool {
        matches(value, pattern: "^[A-Z0-9]{1,30}$") && value.contains(where: { $0.isLetter })
    }

    private static func validInstrumentID(_ id: String) -> Bool {
        let parts = id.components(separatedBy: "-")
        guard parts.count >= 2, validAsset(parts[0]),
              validAsset(parts[1]) || (parts.count == 5 && parts[1] == "USD_UM") else { return false }
        switch parts.count {
        case 2:
            return true
        case 3:
            return parts[2] == "SWAP" || matches(parts[2], pattern: "^[0-9]{6}$")
        case 5:
            return matches(parts[2], pattern: "^[0-9]{6}$")
                && matches(parts[3], pattern: "^[0-9]+(?:\\.[0-9]+)?$")
                && (Double(parts[3]) ?? 0) > 0
                && (parts[4] == "C" || parts[4] == "P")
        default:
            return false
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
