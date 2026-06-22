import Foundation

/// Defensive parser for `container ls --format json`.
///
/// VERIFY: the exact JSON schema apple/container emits is not stable. Rather than
/// bind to one Codable shape, we walk the JSON loosely and probe several likely
/// key names for each field. If the real schema is known, tighten this — but
/// keeping it lenient means a key rename degrades gracefully (a field goes nil)
/// instead of failing the whole tick.
enum ContainerJSON {
    static func parse(_ text: String, logger: Logger) -> [ContainerSummary] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }

        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // Some CLIs emit newline-delimited JSON objects rather than an array.
            let objs = trimmed.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
                return o
            }
            if objs.isEmpty {
                logger.warn("could not parse `container ls` JSON: \(error)")
                return []
            }
            return objs.compactMap(summary(from:))
        }

        if let arr = top as? [[String: Any]] {
            return arr.compactMap(summary(from:))
        }
        if let obj = top as? [String: Any] {
            // Possibly wrapped, e.g. {"containers": [...]}.
            for key in ["containers", "items", "list"] {
                if let arr = obj[key] as? [[String: Any]] {
                    return arr.compactMap(summary(from:))
                }
            }
            if let single = summary(from: obj) { return [single] }
        }
        return []
    }

    private static func summary(from obj: [String: Any]) -> ContainerSummary? {
        guard let name = firstString(obj, keyPaths: [
            ["name"], ["names"], ["Names"], ["Name"],
            ["configuration", "id"], ["configuration", "name"], ["id"], ["ID"]
        ]) else { return nil }

        let image = firstString(obj, keyPaths: [
            ["image"], ["Image"], ["configuration", "image", "reference"],
            ["configuration", "image"], ["imageReference"]
        ])

        let stateRaw = firstString(obj, keyPaths: [
            ["status"], ["Status"], ["state"], ["State"], ["status", "state"]
        ])

        let exit = firstInt(obj, keyPaths: [
            ["exitCode"], ["ExitCode"], ["exit_code"], ["status", "exitCode"]
        ])

        return ContainerSummary(
            name: name,
            image: image,
            state: ContainerState.normalize(stateRaw),
            exitCode: exit
        )
    }

    // MARK: - loose accessors

    private static func value(_ obj: [String: Any], path: [String]) -> Any? {
        var cur: Any? = obj
        for key in path {
            guard let dict = cur as? [String: Any] else { return nil }
            cur = dict[key]
        }
        return cur
    }

    private static func firstString(_ obj: [String: Any], keyPaths: [[String]]) -> String? {
        for path in keyPaths {
            if let v = value(obj, path: path) {
                if let s = v as? String, !s.isEmpty { return s }
                if let arr = v as? [String], let s = arr.first, !s.isEmpty { return s }
            }
        }
        return nil
    }

    private static func firstInt(_ obj: [String: Any], keyPaths: [[String]]) -> Int? {
        for path in keyPaths {
            if let v = value(obj, path: path) {
                if let i = v as? Int { return i }
                if let n = v as? NSNumber { return n.intValue }
                if let s = v as? String, let i = Int(s) { return i }
            }
        }
        return nil
    }
}
