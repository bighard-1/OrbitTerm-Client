import Foundation

enum ShellPathResolver {
    static func resolve(command: String, currentPath: String, username: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 仅提取首段命令（支持 `cd /a && ls`、`cd /a; pwd` 等）。
        let firstSegment = trimmed
            .components(separatedBy: "&&").first?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed

        guard firstSegment == "cd" || firstSegment.hasPrefix("cd ") else { return nil }

        let rawArg = String(firstSegment.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawArg.isEmpty else { return nil }

        let unquoted: String
        if (rawArg.hasPrefix("'") && rawArg.hasSuffix("'")) || (rawArg.hasPrefix("\"") && rawArg.hasSuffix("\"")) {
            unquoted = String(rawArg.dropFirst().dropLast())
        } else {
            unquoted = rawArg
        }

        guard !unquoted.isEmpty else { return nil }

        let unescaped = unquoted
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")

        let merged: String
        if unescaped == "-" {
            return nil
        } else if unescaped == "~" {
            merged = homePath(for: username)
        } else if unescaped.hasPrefix("~/") {
            merged = homePath(for: username) + "/" + String(unescaped.dropFirst(2))
        } else if unescaped.hasPrefix("/") {
            merged = unescaped
        } else {
            let base = currentPath == "/" ? "" : currentPath
            merged = "\(base)/\(unescaped)"
        }
        return normalize(merged)
    }

    static func fallbackPaths(for resolvedPath: String, username: String) -> [String] {
        var list: [String] = []
        if username == "root", resolvedPath.hasPrefix("/home/root/") {
            list.append(resolvedPath.replacingOccurrences(of: "/home/root/", with: "/root/"))
        } else if username != "root", resolvedPath.hasPrefix("/root/") {
            list.append(resolvedPath.replacingOccurrences(of: "/root/", with: "/home/\(username)/"))
        }
        return list.map(normalize)
    }

    private static func homePath(for username: String) -> String {
        username == "root" ? "/root" : "/home/\(username)"
    }

    private static func normalize(_ path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [Substring] = []
        for comp in comps {
            if comp == "." {
                continue
            } else if comp == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(comp)
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}
