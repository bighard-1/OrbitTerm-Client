import Foundation

extension OrbitCStringResultReader {
    static let orbitCore = OrbitCStringResultReader { pointer in
        orbit_free_string(pointer)
    }
}

extension OrbitCoreCheckedFFIFunctions {
    static let orbitCore = OrbitCoreCheckedFFIFunctions(
        connect: { call in
            call.host.withCString { host in
                call.username.withCString { username in
                    call.credentials.password.withCString { password in
                        call.credentials.privateKey.withCString { privateKey in
                            call.credentials.privateKeyPassphrase.withCString { passphrase in
                                call.knownHostsPath.withCString { knownHostsPath in
                                    call.requestID.withCString { requestID in
                                        orbit_ssh_connect_checked_v1(
                                            host,
                                            call.port,
                                            username,
                                            password,
                                            privateKey,
                                            passphrase,
                                            call.credentials.allowPasswordFallback ? 1 : 0,
                                            knownHostsPath,
                                            requestID
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        persist: { call in
            call.challengeID.withCString { challengeID in
                call.knownHostsPath.withCString { knownHostsPath in
                    guard let comment = call.comment else {
                        return orbit_hostkey_challenge_accept_and_persist_v1(
                            challengeID,
                            knownHostsPath,
                            nil
                        )
                    }
                    return comment.withCString { comment in
                        orbit_hostkey_challenge_accept_and_persist_v1(
                            challengeID,
                            knownHostsPath,
                            comment
                        )
                    }
                }
            }
        },
        openTerminal: { call in
            call.requestID.withCString { requestID in
                orbit_terminal_open_checked_v1(
                    call.baseSessionID,
                    call.cols,
                    call.rows,
                    requestID
                )
            }
        },
        openSFTP: { call in
            call.requestID.withCString { requestID in
                orbit_sftp_open_checked_v1(call.baseSessionID, requestID)
            }
        },
        monitorSnapshot: { call in
            call.requestID.withCString { requestID in
                orbit_monitor_snapshot_checked_v1(call.baseSessionID, requestID)
            }
        },
        dockerList: { call in
            call.requestID.withCString { requestID in
                orbit_docker_list_checked_v1(call.baseSessionID, requestID)
            }
        },
        dockerStats: { call in
            call.requestID.withCString { requestID in
                orbit_docker_stats_checked_v1(call.baseSessionID, requestID)
            }
        },
        dockerLogs: { call in
            call.containerID.withCString { containerID in
                call.requestID.withCString { requestID in
                    orbit_docker_logs_checked_v1(
                        call.baseSessionID,
                        containerID,
                        call.tail,
                        requestID
                    )
                }
            }
        },
        dockerAction: { call in
            call.containerID.withCString { containerID in
                call.action.withCString { action in
                    call.requestID.withCString { requestID in
                        orbit_docker_action_checked_v1(
                            call.baseSessionID,
                            containerID,
                            action,
                            requestID
                        )
                    }
                }
            }
        },
        execChecked: { call in
            return call.command.withCString { command in
                call.requestID.withCString { requestID in
                    orbit_exec_checked_v1(
                        call.baseSessionID,
                        command,
                        call.timeoutSeconds,
                        call.maxStdoutBytes,
                        call.maxStderrBytes,
                        requestID
                    )
                }
            }
        }
    )
}

extension OrbitCoreCheckedFFIClient {
    static func live(
        credentialProvider: any CheckedCredentialProvider,
        knownHostsPathProvider: any KnownHostsPathProvider =
            ApplicationSupportKnownHostsPathProvider()
    ) -> OrbitCoreCheckedFFIClient {
        OrbitCoreCheckedFFIClient(
            credentialProvider: credentialProvider,
            knownHostsPathProvider: knownHostsPathProvider,
            functions: .orbitCore,
            resultReader: .orbitCore
        )
    }
}
