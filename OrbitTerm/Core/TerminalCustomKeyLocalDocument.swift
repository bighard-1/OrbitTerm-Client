import Foundation

/// Apple-only local wrapper. Never uploaded; the shared envelope remains v1.
struct TerminalCustomKeyLocalDocument: Codable, Equatable {
    let version: Int
    let account: String
    let actor: String
    var envelope: TerminalCustomKeyEnvelope

    static func empty(account: String) -> Self {
        .init(version: 1, account: account, actor: UUID().uuidString.lowercased(), envelope: .v1([]))
    }

    static func decode(_ data: Data, account: String) throws -> Self {
        guard data.count <= TerminalCustomKeyContract.maxBytes + 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try TerminalCustomKeyContract.hasUniqueObjectKeys(data),
              Set(root.keys) == ["version", "account", "actor", "envelope"],
              let envelope = root["envelope"] else { throw TerminalCustomKeyContract.Failure.invalid }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.version == 1, document.account == account,
              TerminalCustomKeyContract.validID(document.actor) else { throw TerminalCustomKeyContract.Failure.invalid }
        _ = try TerminalCustomKeyContract.decode(JSONSerialization.data(withJSONObject: envelope))
        return document
    }

    func encoded() throws -> Data {
        _ = try TerminalCustomKeyContract.encode(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        _ = try Self.decode(data, account: account)
        return data
    }
}

struct TerminalCustomKeyDraft: Identifiable {
    let id: String
    var label: String
    var payload: String
    var section: String
    var order: Int

    init(id: String = UUID().uuidString.lowercased(), label: String = "", payload: String = "",
         section: String = "common", order: Int = 0) {
        self.id = id
        self.label = label
        self.payload = payload
        self.section = section
        self.order = order
    }

    var value: TerminalCustomKeyValue {
        .init(label: label, payload: payload, section: section, order: order)
    }

    var validationMessage: String? {
        let scalars = label.unicodeScalars
        guard (1...16).contains(scalars.count), scalars.contains(where: { $0.value != 32 }),
              !scalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || [0x2028, 0x2029].contains($0.value) }) else {
            return "名称需为 1–16 个 Unicode 字符，不能只有空格或包含控制字符。"
        }
        guard TerminalCustomKeyPayload.decode(payload) != nil else {
            return "内容需为 1–64 字节；支持 \\t、\\r、\\n、\\e、\\\\ 和 \\xNN，源文本最多 256 字节。"
        }
        guard ["common", "symbols"].contains(section), (0...1_000_000).contains(order),
              TerminalCustomKeyContract.validID(id) else { return "按键配置无效，请重新编辑。" }
        return nil
    }

    var sendsReturn: Bool {
        TerminalCustomKeyPayload.decode(payload)?.contains(where: { $0 == 10 || $0 == 13 }) == true
    }
}
