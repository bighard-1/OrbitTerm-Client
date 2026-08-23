using System.Globalization;

namespace OrbitTerm.Application.Sessions;

internal static class RemoteProcessActionPolicy
{
    private const string ResultPrefix = "__ORBIT_PROCESS_ACTION__:";

    public static string BuildCommand(
        uint processId,
        long startIdentity,
        RemoteProcessAction action)
    {
        if (processId <= 1)
        {
            throw new ArgumentOutOfRangeException(nameof(processId), "System process identifiers cannot be managed.");
        }
        if (startIdentity <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(startIdentity), "A valid process start identity is required.");
        }

        var signal = action switch
        {
            RemoteProcessAction.Terminate => "TERM",
            RemoteProcessAction.ForceKill => "KILL",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

        // Only validated numeric values and a closed signal enum are inserted.
        // The remote process name, owner and command line never enter the shell.
        return string.Concat(
            "pid=", processId.ToString(CultureInfo.InvariantCulture),
            "; expected=", startIdentity.ToString(CultureInfo.InvariantCulture),
            "; now=$(date +%s 2>/dev/null); ",
            "elapsed=$(LC_ALL=C ps -p \"$pid\" -o etimes= 2>/dev/null | tr -d '[:space:]'); " +
            "result=not_found; case \"$elapsed\" in ''|*[!0-9]*) result=not_found ;; *) " +
            "current=$((now-elapsed)); delta=$((current-expected)); " +
            "[ \"$delta\" -lt 0 ] && delta=$((-delta)); " +
            "if [ \"$pid\" -le 1 ]; then result=protected; " +
            "elif [ \"$delta\" -gt 2 ]; then result=identity_changed; " +
            "elif kill -", signal, " \"$pid\" 2>/dev/null; then result=completed; " +
            "else result=permission_denied; fi ;; esac; " +
            "printf '", ResultPrefix, "%s\\n' \"$result\"");
    }

    public static RemoteProcessActionResult Parse(
        VerifiedSessionLease lease,
        uint processId,
        RemoteProcessAction action,
        BatchExecResult result)
    {
        if (result is BatchExecResult.Failed failed)
        {
            return new RemoteProcessActionResult.Failed(failed.Code, failed.MessageKey);
        }

        var completed = (BatchExecResult.Completed)result;
        var marker = completed.Stdout
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault(line => line.StartsWith(ResultPrefix, StringComparison.Ordinal));
        return marker?[ResultPrefix.Length..] switch
        {
            "completed" => new RemoteProcessActionResult.Completed(lease, processId, action),
            "not_found" => new RemoteProcessActionResult.NotFound(processId),
            "identity_changed" => new RemoteProcessActionResult.IdentityChanged(processId),
            "protected" => new RemoteProcessActionResult.Protected(processId),
            "permission_denied" => new RemoteProcessActionResult.PermissionDenied(processId),
            _ => new RemoteProcessActionResult.Failed(
                "process_action_invalid_response",
                "error.process.action.invalid_response"),
        };
    }
}
