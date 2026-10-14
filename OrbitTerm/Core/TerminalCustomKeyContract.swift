import Foundation

struct TerminalCustomKeyValue: Codable, Equatable {
    let label: String
    let payload: String
    let section: String
    let order: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Swift String equality normalizes canonical Unicode equivalents. Payload
        // identity is byte identity, matching Kotlin and terminal transmission.
        lhs.label.utf8.elementsEqual(rhs.label.utf8) && lhs.payload.utf8.elementsEqual(rhs.payload.utf8)
            && lhs.section == rhs.section && lhs.order == rhs.order
    }
}

struct TerminalCustomKeyRevision: Codable, Equatable {
    let id: String
    let clock: [String: Int64]
    /// nil is a deletion, not a missing or invalid value.
    let value: TerminalCustomKeyValue?

    enum CodingKeys: String, CodingKey { case id, clock, value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(clock, forKey: .clock)
        try container.encode(value, forKey: .value)
    }
}

struct TerminalCustomKeyEnvelope: Codable, Equatable {
    let kind: String
    let version: Int
    let payloadSyntaxVersion: Int
    let revisions: [TerminalCustomKeyRevision]

    static func v1(_ revisions: [TerminalCustomKeyRevision]) -> Self {
        .init(kind: "terminal_custom_keys", version: 1, payloadSyntaxVersion: 1, revisions: revisions)
    }
}

/// A complete, normalized review snapshot, never a guessed "latest" version.
struct TerminalCustomKeyConflict: Equatable, Identifiable {
    let id: String
    let revisions: [TerminalCustomKeyRevision]
    var explanation: String {
        revisions.contains { $0.value == nil }
            ? "同一按键存在并发修改或删除，无法自动判断应保留哪个版本。"
            : "同一按键存在并发修改，无法自动判断应保留哪个版本。"
    }
}

struct TerminalCustomKeyImportPlan {
    struct Change: Identifiable {
        let id: String
        let before: [TerminalCustomKeyRevision]
        let after: [TerminalCustomKeyRevision]
    }
    let before: TerminalCustomKeyEnvelope
    let incoming: TerminalCustomKeyEnvelope
    let merged: TerminalCustomKeyEnvelope
    let changes: [Change]
    let activeCount: Int
    let conflictCount: Int

    static func make(current: TerminalCustomKeyEnvelope, incoming: TerminalCustomKeyEnvelope) throws -> Self {
        let before = try TerminalCustomKeyContract.merge(current, .v1([]))
        let merged = try TerminalCustomKeyContract.merge(before, incoming)
        let old = Dictionary(grouping: before.revisions, by: \.id)
        let new = Dictionary(grouping: merged.revisions, by: \.id)
        let changes = Set(old.keys).union(new.keys).sorted().compactMap { id -> Change? in
            let a = old[id] ?? [], b = new[id] ?? []
            return a == b ? nil : Change(id: id, before: a, after: b)
        }
        return .init(before: before, incoming: incoming, merged: merged, changes: changes,
                     activeCount: try TerminalCustomKeyContract.active(merged).count,
                     conflictCount: try TerminalCustomKeyContract.conflicts(merged).count)
    }
}

/// Pure, account-agnostic model. Callers must provide a complete account snapshot;
/// this does not enable network writes or persist decrypted command material.
enum TerminalCustomKeyContract {
    enum Failure: Error { case invalid, unsupported, capacity, revisionCollision }
    static let maxCounter: Int64 = 9_007_199_254_740_991
    static let maxBytes = 262_144

    static func validID(_ value: String) -> Bool {
        value.utf8.count == 36 && value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    static func decode(_ data: Data) throws -> TerminalCustomKeyEnvelope {
        guard data.count <= maxBytes else { throw Failure.capacity }
        // Codable ignores unknown fields. Check shape first to avoid dropping future
        // fields when a supposedly v1 document is later encoded or merged.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["kind"] as? String == "terminal_custom_keys" else { throw Failure.invalid }
        guard try hasUniqueObjectKeys(data) else { throw Failure.invalid }
        guard let version = root["version"] as? NSNumber,
              let syntax = root["payloadSyntaxVersion"] as? NSNumber,
              version == 1, syntax == 1 else { throw Failure.unsupported }
        guard Set(root.keys) == ["kind", "version", "payloadSyntaxVersion", "revisions"],
              let rows = root["revisions"] as? [[String: Any]] else { throw Failure.invalid }
        for row in rows {
            guard Set(row.keys) == ["id", "clock", "value"] else { throw Failure.invalid }
            if !(row["value"] is NSNull) {
                guard let value = row["value"] as? [String: Any],
                      Set(value.keys) == ["label", "payload", "section", "order"] else { throw Failure.invalid }
            }
        }
        let result = try JSONDecoder().decode(TerminalCustomKeyEnvelope.self, from: data)
        try validate(result)
        return result
    }

    static func encode(_ envelope: TerminalCustomKeyEnvelope) throws -> Data {
        try validate(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= maxBytes else { throw Failure.capacity }
        return data
    }

    static func validate(_ envelope: TerminalCustomKeyEnvelope) throws {
        guard envelope.kind == "terminal_custom_keys", envelope.version == 1,
              envelope.payloadSyntaxVersion == 1 else { throw Failure.unsupported }
        guard envelope.revisions.count <= 256 else { throw Failure.capacity }
        let grouped = Dictionary(grouping: envelope.revisions, by: \.id)
        guard grouped.values.allSatisfy({ $0.count <= 8 }),
              Set(envelope.revisions.filter { $0.value != nil }.map(\.id)).count <= 64 else { throw Failure.capacity }
        for row in envelope.revisions {
            guard validID(row.id), !row.clock.isEmpty, row.clock.count <= 32,
                  row.clock.allSatisfy({ validID($0.key) && $0.value > 0 && $0.value <= maxCounter }) else { throw Failure.invalid }
            if let value = row.value {
                let scalars = value.label.unicodeScalars
                guard (1...16).contains(scalars.count), scalars.contains(where: { $0.value != 32 }),
                      !scalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }),
                      ["common", "symbols"].contains(value.section), (0...1_000_000).contains(value.order),
                      TerminalCustomKeyPayload.decode(value.payload) != nil else { throw Failure.invalid }
            }
        }
        for rows in grouped.values {
            for a in rows {
                if rows.contains(where: { $0.clock == a.clock && $0.value != a.value }) { throw Failure.revisionCollision }
            }
        }
    }

    static func merge(_ left: TerminalCustomKeyEnvelope, _ right: TerminalCustomKeyEnvelope) throws -> TerminalCustomKeyEnvelope {
        try validate(left)
        try validate(right)
        let groups = Dictionary(grouping: left.revisions + right.revisions, by: \.id)
        var result: [TerminalCustomKeyRevision] = []
        for rows in groups.values {
            var unique: [TerminalCustomKeyRevision] = []
            for row in rows {
                if unique.contains(where: { $0.clock == row.clock && $0.value != row.value }) { throw Failure.revisionCollision }
                if !unique.contains(row) { unique.append(row) }
            }
            result += unique.filter { row in !unique.contains { dominates($0.clock, row.clock) } }
        }
        result.sort { $0.id == $1.id ? clockKey($0.clock) < clockKey($1.clock) : $0.id < $1.id }
        let envelope = TerminalCustomKeyEnvelope.v1(result)
        try validate(envelope) // Exceeding a bound blocks the merge; never truncate.
        _ = try encode(envelope)
        return envelope
    }

    /// User edit/delete/resolution after observing ALL revisions for this key.
    static func replacing(_ envelope: TerminalCustomKeyEnvelope, id: String, actor: String,
                          value: TerminalCustomKeyValue?) throws -> TerminalCustomKeyEnvelope {
        try validate(envelope)
        guard validID(id), validID(actor) else { throw Failure.invalid }
        var clock: [String: Int64] = [:]
        for row in envelope.revisions where row.id == id {
            for (actor, count) in row.clock { clock[actor] = max(clock[actor] ?? 0, count) }
        }
        guard (clock[actor] ?? 0) < maxCounter else { throw Failure.capacity }
        clock[actor] = (clock[actor] ?? 0) + 1
        let rows = envelope.revisions.filter { $0.id != id } + [.init(id: id, clock: clock, value: value)]
        return try merge(.v1(rows), .v1([]))
    }

    /// Conflicting IDs (including edit/delete) never become sendable buttons.
    static func active(_ envelope: TerminalCustomKeyEnvelope) throws -> [TerminalCustomKeyRevision] {
        let normalized = try merge(envelope, .v1([]))
        return Dictionary(grouping: normalized.revisions, by: \.id).values
            .compactMap { $0.count == 1 && $0[0].value != nil ? $0[0] : nil }
            .sorted {
                let a = $0.value!, b = $1.value!
                if a.section != b.section { return a.section < b.section }
                if a.order != b.order { return a.order < b.order }
                return $0.id < $1.id
            }
    }

    static func conflicts(_ envelope: TerminalCustomKeyEnvelope) throws -> [TerminalCustomKeyConflict] {
        let normalized = try merge(envelope, .v1([]))
        return Dictionary(grouping: normalized.revisions, by: \.id)
            .filter { $0.value.count > 1 }
            .map { TerminalCustomKeyConflict(id: $0.key, revisions: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// Compare ALL observed branches. A late new branch must force a new review,
    /// not be silently dominated by a decision made on an older screen.
    static func resolving(_ envelope: TerminalCustomKeyEnvelope, observed: TerminalCustomKeyConflict,
                          keeping: TerminalCustomKeyRevision?, actor: String) throws -> TerminalCustomKeyEnvelope {
        guard try conflicts(envelope).contains(observed),
              keeping == nil || (keeping?.value != nil && observed.revisions.contains(keeping!)) else {
            throw Failure.invalid
        }
        return try replacing(envelope, id: observed.id, actor: actor, value: keeping?.value)
    }

    private static func dominates(_ a: [String: Int64], _ b: [String: Int64]) -> Bool {
        let keys = Set(a.keys).union(b.keys)
        return keys.allSatisfy { (a[$0] ?? 0) >= (b[$0] ?? 0) } && keys.contains { (a[$0] ?? 0) > (b[$0] ?? 0) }
    }
    private static func clockKey(_ clock: [String: Int64]) -> String {
        clock.keys.sorted().map { "\($0):\(clock[$0]!)" }.joined(separator: ";")
    }

    // Run only after JSON syntax validation. Foundation and kotlinx.serialization
    // may choose different winners for repeated keys; reject even escaped aliases.
    static func hasUniqueObjectKeys(_ data: Data) throws -> Bool {
        let bytes = Array(data)
        var scopes: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: scopes.append(Set<String>())
            case 91: scopes.append(nil)
            case 125, 93: _ = scopes.popLast()
            case 34:
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard !scopes.isEmpty, var keys = scopes[scopes.count - 1] else { return false }
                    guard keys.insert(key).inserted else { return false }
                    scopes[scopes.count - 1] = keys
                }
            default: break
            }
            index += 1
        }
        return true
    }
}
