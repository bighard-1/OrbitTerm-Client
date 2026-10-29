using System.Reflection;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class CheckedSftpDownloadPathTests
{
    private static readonly MethodInfo ValidatePath = typeof(CheckedOrbitCoreClient).GetMethod(
        "EnsureNewLocalDownloadPath",
        BindingFlags.NonPublic | BindingFlags.Static)!;

    [Fact]
    public void ExistingAbsolutePathReachesAtomicCoreCheckInsteadOfManagedPreflight()
    {
        var path = Path.GetTempFileName();
        try
        {
            var original = File.ReadAllBytes(path);

            ValidatePath.Invoke(null, [path]);

            Assert.Equal(original, File.ReadAllBytes(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void RelativePathIsStillRejectedBeforeNativeCall()
    {
        var error = Assert.Throws<TargetInvocationException>(() =>
            ValidatePath.Invoke(null, ["not-an-absolute-path"]));

        Assert.IsType<ArgumentException>(error.InnerException);
    }
}
