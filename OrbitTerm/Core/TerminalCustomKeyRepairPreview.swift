import Foundation
import CoreFoundation
import CryptoKit

enum TerminalCustomKeyRepairSource: Equatable { case appleDocument, androidLegacy }
enum TerminalCustomKeyRepairBlockedReason: Equatable { case malformedOrAmbiguous, rootNotEnumerable, tooManyItems }
enum TerminalCustomKeyRepairIssue: Equatable, Hashable {
    case rowNotObject, unknownFields, missingOrWrongID, invalidID, duplicateID
    case missingOrWrongLabel, invalidLabel, missingOrWrongPayload, invalidPayload
    case missingOrWrongSection, invalidSection, invalidClock, invalidValue
    case invalidDocumentMetadata, revisionCollision, tooManyVersions, capacitySelectionRequired
}
enum TerminalCustomKeyRepairDisposition: Equatable { case keepUnchanged, manualCorrectionRequired, capacitySelectionRequired, cannotInterpret }

struct TerminalCustomKeyRepairItem: Equatable, Identifiable {
    let index: Int
    let idSummary: String?
    let labelSummary: String?
    let sectionSummary: String?
    let payloadUTF8Bytes: Int?
    let issues: [TerminalCustomKeyRepairIssue]
    let disposition: TerminalCustomKeyRepairDisposition
    /// Ephemeral grouping within this preview only. It is not a stable content
    /// digest and deliberately does not expose the full source identifier.
    let identityGroup: Int?
    let isActive: Bool
    var id: Int { index }
}

struct TerminalCustomKeyRepairPreview: Equatable {
    let source: TerminalCustomKeyRepairSource
    let blockedReason: TerminalCustomKeyRepairBlockedReason?
    let documentIssues: [TerminalCustomKeyRepairIssue]
    let items: [TerminalCustomKeyRepairItem]
    let protectedSourcePresent: Bool
}

enum TerminalCustomKeyRepairChoice: String, CaseIterable, Hashable {
    case keep, correct, exclude, capacityExclude
}

struct TerminalCustomKeyRepairCorrection: Equatable {
    var label = ""
    var payload = ""
    var section = "common"
}

struct TerminalCustomKeyRepairDecision: Equatable {
    let choice: TerminalCustomKeyRepairChoice
    let correction: TerminalCustomKeyRepairCorrection?
}

enum TerminalCustomKeyRepairDecisionIssue: Equatable, Hashable {
    case sourceBlocked, protectedSourceConflict, documentMetadataBlocked
    case missingDecision(Int), invalidChoice(Int), invalidCorrection(Int)
    case duplicateRetainedIdentity(Int), tooManyVersions(Int), capacityExceeded(Int)
}

struct TerminalCustomKeyRepairDecisionRow: Equatable, Identifiable {
    let index: Int
    let choice: TerminalCustomKeyRepairChoice
    let idSummary: String?
    let labelSummary: String?
    let sectionSummary: String?
    let payloadUTF8Bytes: Int?
    let included: Bool
    var id: Int { index }
}

/// A non-persistent decision review. It contains summaries and a one-way
/// confirmation baseline, but no replacement payload and no write authority.
struct TerminalCustomKeyRepairDecisionPlan: Equatable {
    let totalCount: Int
    let decidedCount: Int
    let keptCount: Int
    let correctedCount: Int
    let excludedCount: Int
    let activeIdentityCount: Int
    let rows: [TerminalCustomKeyRepairDecisionRow]
    let issues: [TerminalCustomKeyRepairDecisionIssue]
    let confirmationBaseline: String?
    var isReadyForSecondConfirmation: Bool { issues.isEmpty && confirmationBaseline != nil }
    var requiresDataLossAcknowledgement: Bool { excludedCount > 0 }
}

enum TerminalCustomKeyRepairDecisionPlanner {
    static func make(preview: TerminalCustomKeyRepairPreview, sessionToken: String,
                     decisions: [Int: TerminalCustomKeyRepairDecision]) -> TerminalCustomKeyRepairDecisionPlan {
        var issues: [TerminalCustomKeyRepairDecisionIssue] = []
        if preview.blockedReason != nil { issues.append(.sourceBlocked) }
        if preview.protectedSourcePresent { issues.append(.protectedSourceConflict) }
        if !preview.documentIssues.isEmpty { issues.append(.documentMetadataBlocked) }

        var rows: [TerminalCustomKeyRepairDecisionRow] = []
        var retainedGroups: [Int: Int] = [:]
        var activeGroups: Set<Int> = []
        for item in preview.items {
            guard let decision = decisions[item.index] else {
                issues.append(.missingDecision(item.index)); continue
            }
            switch decision.choice {
            case .keep:
                let permitted = item.disposition == .keepUnchanged || item.disposition == .capacitySelectionRequired
                if !permitted { issues.append(.invalidChoice(item.index)) }
                rows.append(result(item, choice: .keep, correction: nil, included: permitted))
                if permitted { retain(item, retained: &retainedGroups, active: &activeGroups) }
            case .correct:
                guard correctable(item), let correction = decision.correction, valid(correction) else {
                    issues.append(.invalidCorrection(item.index))
                    rows.append(result(item, choice: .correct, correction: nil, included: false)); continue
                }
                rows.append(result(item, choice: .correct, correction: correction, included: true))
                retain(item, retained: &retainedGroups, active: &activeGroups, forceActive: true)
            case .exclude:
                rows.append(result(item, choice: .exclude, correction: nil, included: false))
            case .capacityExclude:
                let permitted = item.issues.contains(.capacitySelectionRequired)
                if !permitted { issues.append(.invalidChoice(item.index)) }
                rows.append(result(item, choice: .capacityExclude, correction: nil, included: false))
            }
        }
        for (group, count) in retainedGroups {
            if preview.source == .androidLegacy, count > 1 { issues.append(.duplicateRetainedIdentity(group)) }
            if preview.source == .appleDocument, count > 8 { issues.append(.tooManyVersions(group)) }
        }
        if activeGroups.count > 64 { issues.append(.capacityExceeded(activeGroups.count)) }
        issues = unique(issues)
        rows.sort { $0.index < $1.index }
        let excluded = rows.filter { !$0.included }.count
        let baseline = issues.isEmpty ? baseline(preview: preview, sessionToken: sessionToken, decisions: decisions) : nil
        return .init(totalCount: preview.items.count, decidedCount: decisions.keys.filter { key in preview.items.contains { $0.index == key } }.count,
                     keptCount: rows.filter { $0.choice == .keep && $0.included }.count,
                     correctedCount: rows.filter { $0.choice == .correct && $0.included }.count,
                     excludedCount: excluded, activeIdentityCount: activeGroups.count,
                     rows: rows, issues: issues, confirmationBaseline: baseline)
    }

    private static func correctable(_ item: TerminalCustomKeyRepairItem) -> Bool {
        guard item.identityGroup != nil else { return false }
        let unrepairable: Set<TerminalCustomKeyRepairIssue> = [
            .rowNotObject, .missingOrWrongID, .invalidID, .invalidClock, .revisionCollision,
        ]
        return unrepairable.isDisjoint(with: item.issues)
    }

    private static func valid(_ correction: TerminalCustomKeyRepairCorrection) -> Bool {
        let scalars = correction.label.unicodeScalars
        return (1...16).contains(scalars.count) && scalars.contains { $0.value != 32 } &&
            !scalars.contains { $0.value < 32 || (127...159).contains($0.value) || [0x2028, 0x2029].contains($0.value) } &&
            ["common", "symbols"].contains(correction.section) &&
            TerminalCustomKeyPayload.decode(correction.payload) != nil
    }

    private static func retain(_ item: TerminalCustomKeyRepairItem, retained: inout [Int: Int],
                               active: inout Set<Int>, forceActive: Bool = false) {
        guard let group = item.identityGroup else { return }
        retained[group, default: 0] += 1
        if forceActive || item.isActive { active.insert(group) }
    }

    private static func result(_ item: TerminalCustomKeyRepairItem, choice: TerminalCustomKeyRepairChoice,
                               correction: TerminalCustomKeyRepairCorrection?, included: Bool) -> TerminalCustomKeyRepairDecisionRow {
        .init(index: item.index, choice: choice, idSummary: item.idSummary,
              labelSummary: correction.map { TerminalCustomKeyRepairPreviewParser.safe($0.label) } ?? item.labelSummary,
              sectionSummary: correction.map(\.section) ?? item.sectionSummary,
              payloadUTF8Bytes: correction.map { $0.payload.utf8.count } ?? item.payloadUTF8Bytes,
              included: included)
    }

    private static func baseline(preview: TerminalCustomKeyRepairPreview, sessionToken: String,
                                 decisions: [Int: TerminalCustomKeyRepairDecision]) -> String {
        var canonical = ""
        func append(_ value: String) { canonical += "\(value.utf8.count):\(value)|" }
        append(sessionToken); append(preview.source == .appleDocument ? "apple" : "android")
        for item in preview.items.sorted(by: { $0.index < $1.index }) {
            append(String(item.index)); append(item.idSummary ?? ""); append(String(item.identityGroup ?? -1)); append(item.isActive ? "1" : "0")
            guard let decision = decisions[item.index] else { continue }
            append(decision.choice.rawValue)
            if let correction = decision.correction {
                append(correction.label); append(correction.payload); append(correction.section)
            }
        }
        return SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ values: [TerminalCustomKeyRepairDecisionIssue]) -> [TerminalCustomKeyRepairDecisionIssue] {
        var seen: Set<TerminalCustomKeyRepairDecisionIssue> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Bounded, read-only diagnosis of the authenticated raw Apple document. It
/// deliberately produces no replacement bytes and never includes raw payloads.
enum TerminalCustomKeyRepairPreviewParser {
    private struct Parsed {
        let id: String?
        let clock: String?
        let valueFingerprint: Data?
        let active: Bool
    }
    private static let maximumItems = 256
    private static let documentKeys: Set<String> = ["version", "account", "actor", "envelope"]
    private static let envelopeKeys: Set<String> = ["kind", "version", "payloadSyntaxVersion", "revisions"]
    private static let revisionKeys: Set<String> = ["id", "clock", "value"]
    private static let valueKeys: Set<String> = ["label", "payload", "section", "order"]

    static func appleDocument(_ data: Data, rescueAccount: String) -> TerminalCustomKeyRepairPreview {
        guard data.count <= TerminalCustomKeyRecoveryPackage.maxRescuePlaintext,
              (try? TerminalCustomKeyContract.hasUniqueObjectKeys(data)) == true,
              let root = try? JSONSerialization.jsonObject(with: data) else { return blocked(.malformedOrAmbiguous) }
        guard let document = root as? [String: Any] else { return blocked(.rootNotEnumerable) }
        guard let envelope = document["envelope"] as? [String: Any],
              let rows = envelope["revisions"] as? [Any] else { return blocked(.rootNotEnumerable) }
        guard rows.count <= maximumItems else { return blocked(.tooManyItems) }

        var documentIssues: [TerminalCustomKeyRepairIssue] = []
        if Set(document.keys) != documentKeys || integer(document["version"]) != 1 ||
            document["account"] as? String != rescueAccount ||
            (document["actor"] as? String).map(TerminalCustomKeyContract.validID) != true {
            documentIssues.append(.invalidDocumentMetadata)
        }
        if Set(envelope.keys) != envelopeKeys || envelope["kind"] as? String != "terminal_custom_keys" ||
            integer(envelope["version"]) != 1 || integer(envelope["payloadSyntaxVersion"]) != 1 {
            documentIssues.append(.invalidDocumentMetadata)
        }

        var parsed: [Parsed] = []
        for element in rows {
            guard let row = element as? [String: Any] else {
                parsed.append(.init(id: nil, clock: nil, valueFingerprint: nil, active: false)); continue
            }
            let id = row["id"] as? String
            let clock = clockSignature(row["clock"])
            let value = row["value"]
            let fingerprint = value.flatMap { value in
                try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            }
            parsed.append(.init(id: id, clock: clock, valueFingerprint: fingerprint, active: !(value is NSNull)))
        }
        let versionCounts = Dictionary(grouping: parsed.compactMap { $0.id }, by: { $0 }).mapValues(\.count)
        var identityGroups: [String: Int] = [:]
        for id in parsed.compactMap(\.id) where TerminalCustomKeyContract.validID(id) {
            if identityGroups[id] == nil { identityGroups[id] = identityGroups.count }
        }
        let collisionKeys = Set(Dictionary(grouping: parsed.indices.compactMap { index -> String? in
            guard let id = parsed[index].id, let clock = parsed[index].clock else { return nil }
            return id + "|" + clock
        }, by: { $0 }).compactMap { key, occurrences -> String? in
            let fingerprints = parsed.filter { item in
                guard let id = item.id, let clock = item.clock else { return false }
                return id + "|" + clock == key
            }.compactMap(\.valueFingerprint)
            return occurrences.count > 1 && Set(fingerprints).count > 1 ? key : nil
        })
        let capacity = Set(parsed.filter { $0.active && ($0.id.map(TerminalCustomKeyContract.validID) ?? false) }.compactMap(\.id)).count > 64

        let items = rows.enumerated().map { index, element -> TerminalCustomKeyRepairItem in
            guard let row = element as? [String: Any] else {
                return item(index, nil, nil, nil, nil, [.rowNotObject], .cannotInterpret, nil, false)
            }
            let id = row["id"] as? String
            let label: String?
            let payload: String?
            let section: String?
            var issues: [TerminalCustomKeyRepairIssue] = []
            if Set(row.keys) != revisionKeys { issues.append(.unknownFields) }
            if id == nil { issues.append(.missingOrWrongID) }
            else if !TerminalCustomKeyContract.validID(id!) { issues.append(.invalidID) }
            if parsed[index].clock == nil { issues.append(.invalidClock) }
            if row["value"] is NSNull { label = nil; payload = nil; section = nil }
            else if let value = row["value"] as? [String: Any] {
                if Set(value.keys) != valueKeys { issues.append(.unknownFields) }
                label = value["label"] as? String
                payload = value["payload"] as? String
                section = value["section"] as? String
                if label == nil { issues.append(.missingOrWrongLabel) }
                else if !validLabel(label!) { issues.append(.invalidLabel) }
                if payload == nil { issues.append(.missingOrWrongPayload) }
                else if TerminalCustomKeyPayload.decode(payload!) == nil { issues.append(.invalidPayload) }
                if section == nil { issues.append(.missingOrWrongSection) }
                else if !["common", "symbols"].contains(section!) { issues.append(.invalidSection) }
                guard let order = integer(value["order"]), (0...1_000_000).contains(order) else {
                    issues.append(.invalidValue)
                    return finish(index, id, label, section, payload, issues, parsed, versionCounts, collisionKeys, capacity, identityGroups[id])
                }
            } else {
                label = nil; payload = nil; section = nil; issues.append(.invalidValue)
            }
            return finish(index, id, label, section, payload, issues, parsed, versionCounts, collisionKeys, capacity, identityGroups[id])
        }
        return .init(source: .appleDocument, blockedReason: nil,
                     documentIssues: unique(documentIssues), items: items, protectedSourcePresent: false)
    }

    private static func finish(_ index: Int, _ id: String?, _ label: String?, _ section: String?, _ payload: String?,
                               _ initial: [TerminalCustomKeyRepairIssue], _ parsed: [Parsed],
                               _ versionCounts: [String: Int], _ collisionKeys: Set<String>, _ capacity: Bool,
                               _ identityGroup: Int?) -> TerminalCustomKeyRepairItem {
        var issues = initial
        if let id, (versionCounts[id] ?? 0) > 8 { issues.append(.tooManyVersions) }
        if let id, let clock = parsed[index].clock, collisionKeys.contains(id + "|" + clock) {
            issues.append(.revisionCollision)
        }
        if capacity { issues.append(.capacitySelectionRequired) }
        let hasNonCapacity = issues.contains { $0 != .capacitySelectionRequired }
        let disposition: TerminalCustomKeyRepairDisposition = hasNonCapacity ? .manualCorrectionRequired
            : capacity ? .capacitySelectionRequired : .keepUnchanged
        return item(index, id, label, section, payload?.utf8.count, issues, disposition, identityGroup, parsed[index].active)
    }

    private static func clockSignature(_ value: Any?) -> String? {
        guard let clock = value as? [String: Any], !clock.isEmpty, clock.count <= 32 else { return nil }
        var values: [String: Int64] = [:]
        for (actor, raw) in clock {
            guard TerminalCustomKeyContract.validID(actor), let count = integer(raw),
                  (1...TerminalCustomKeyContract.maxCounter).contains(count) else { return nil }
            values[actor] = count
        }
        return values.keys.sorted().map { "\($0):\(values[$0]!)" }.joined(separator: ";")
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.int64Value
        return number.doubleValue == Double(result) ? result : nil
    }

    private static func validLabel(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (1...16).contains(scalars.count) && scalars.contains { $0.value != 32 } &&
            !scalars.contains { $0.value < 32 || (127...159).contains($0.value) || [0x2028, 0x2029].contains($0.value) }
    }

    private static func item(_ index: Int, _ id: String?, _ label: String?, _ section: String?, _ payloadBytes: Int?,
                             _ issues: [TerminalCustomKeyRepairIssue], _ disposition: TerminalCustomKeyRepairDisposition,
                             _ identityGroup: Int?, _ isActive: Bool) -> TerminalCustomKeyRepairItem {
        .init(index: index,
              idSummary: id.map { TerminalCustomKeyContract.validID($0) ? "…\($0.suffix(8))" : safe($0) },
              labelSummary: label.map { safe($0) }, sectionSummary: section.map { safe($0) }, payloadUTF8Bytes: payloadBytes,
              issues: unique(issues), disposition: disposition, identityGroup: identityGroup, isActive: isActive)
    }

    static func safe(_ value: String, limit: Int = 24) -> String {
        var result = "", count = 0, consumed = value.unicodeScalars.startIndex
        while consumed < value.unicodeScalars.endIndex && count < limit {
            let scalar = value.unicodeScalars[consumed], code = scalar.value
            if code == 92 { result += "\\\\" }
            else if code < 32 || (127...159).contains(code) || scalar.properties.generalCategory == .format ||
                        [0x2028, 0x2029].contains(code) { result += "\\u{\(String(code, radix: 16).uppercased())}" }
            else { result.unicodeScalars.append(scalar) }
            consumed = value.unicodeScalars.index(after: consumed); count += 1
        }
        if consumed < value.unicodeScalars.endIndex { result += "…" }
        return result
    }

    private static func blocked(_ reason: TerminalCustomKeyRepairBlockedReason) -> TerminalCustomKeyRepairPreview {
        .init(source: .appleDocument, blockedReason: reason, documentIssues: [], items: [], protectedSourcePresent: false)
    }

    private static func unique(_ values: [TerminalCustomKeyRepairIssue]) -> [TerminalCustomKeyRepairIssue] {
        var seen: Set<TerminalCustomKeyRepairIssue> = []
        return values.filter { seen.insert($0).inserted }
    }
}
