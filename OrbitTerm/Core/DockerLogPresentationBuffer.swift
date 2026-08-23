import Foundation

/// Bounds the text retained by a Docker log screen independently of transport
/// limits. The notice is included inside the budget rather than appended past
/// it, so rendered text has one enforceable memory ceiling.
enum DockerLogPresentationBuffer {
    static func renderedText(_ text: String) -> String {
        guard !text.isEmpty else { return "(暂无日志)" }

        let source = text.utf8
        let maximumBytes = OperationResourceBudget.dockerRenderedLogBytes
        guard source.count > maximumBytes else { return text }

        let notice = "(为控制内存，仅显示最新日志)\n\n"
        let retainedBytes = max(0, maximumBytes - notice.utf8.count)
        let tail = String(decoding: source.suffix(retainedBytes), as: UTF8.self)
        return notice + tail
    }
}
