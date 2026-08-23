# Apple resource-budget stress gate

## Scope

This gate covers the bounded in-memory primitives used by Apple clients. It
uses synthetic payloads only and never opens a network connection, creates an
SSH session, reads an account, or records remote output.

## Deterministic SLOs

| Surface | Production bound | Stress proof |
| --- | --- | --- |
| Terminal pending delivery | 1 MiB/channel | 16 MiB synthetic output retains only the newest 1 MiB. |
| Terminal detached replay | 8 MiB/channel | The same run retains only the newest 8 MiB. |
| Docker log presentation | 1 MiB/view | A 2 MiB synthetic log, including truncation notice, remains at or below 1 MiB. |
| Monitor history | 600 points/panel | 60,000 samples retain chronological newest 600 points. |
| SFTP transfer admission | 3 concurrent operations | A 10,000-operation burst never exceeds three admitted slots. |
| Sync delivery | 1 concurrent delivery | A 10,000-decision burst never admits a second delivery. |

Each deterministic component run must finish within five seconds on the CI
runner. This is a regression ceiling for these pure data structures, not a
claim about network latency, remote command duration, or device-wide memory.

## CI evidence

`scripts/security/check_apple_release_gates.sh` executes
`OperationResourceBudgetTests` and `OperationResourceBudgetStressTests` as a
named Apple release gate. The XCTest result and CI log are the retained
evidence. Device profiling remains a separate release-candidate activity.
