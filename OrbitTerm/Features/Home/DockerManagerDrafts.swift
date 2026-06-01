import Foundation

struct DockerConnectionDraft {
    var host: String = ""
    var username: String = ""
    var password: String = ""
}

struct DockerContainerRenameDraft {
    var target: DockerContainerCard?
    var name: String = ""

    var isPresented: Bool {
        target != nil
    }

    var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func begin(_ container: DockerContainerCard) {
        target = container
        name = container.name
    }

    mutating func reset() {
        target = nil
        name = ""
    }
}

struct DockerContainerUpdateDraft {
    var restartPolicy: String = "unless-stopped"
    var memoryLimit: String = ""
    var cpuSharesText: String = ""

    var options: DockerContainerUpdateOptions {
        DockerContainerUpdateOptions(
            restartPolicy: restartPolicy,
            memoryLimit: memoryLimit,
            cpuShares: Int(cpuSharesText)
        )
    }

    mutating func reset() {
        restartPolicy = "unless-stopped"
        memoryLimit = ""
        cpuSharesText = ""
    }
}
