using OrbitTerm.Application.Security;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SshPrivateKeyInspectorTests
{
    private const string Ed25519OpenSshKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYgAAAJgAIAxdACAM
        XQAAAAtzc2gtZWQyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYg
        AAAEC2BsIi0QwW2uFscKTUUXNHLsYX4FxlaSDSblbAj7WR7bM+rvN+ot98qgEN796jTiQf
        ZfG1KaT0PtFDJ/XFSqtiAAAAEHVzZXJAZXhhbXBsZS5jb20BAgMEBQ==
        -----END OPENSSH PRIVATE KEY-----
        """;

    [Fact]
    public void LiveCoreRecognizesPortableEd25519Material()
    {
        OrbitNativeLibraryLoader.Register();

        var result = SshPrivateKeyInspector.Inspect(Ed25519OpenSshKey, string.Empty);

        Assert.Equal("ssh-ed25519", result.Algorithm);
        Assert.Equal("Ed25519", result.DisplayName);
    }

    [Fact]
    public void StructuralPolicyRejectsLegacyDsaBeforePersistence()
    {
        const string dsa = "-----BEGIN DSA PRIVATE KEY-----\nnot-key-material\n-----END DSA PRIVATE KEY-----";

        var error = Assert.Throws<ArgumentException>(() => SshKeyMaterialPolicy.NormalizePrivateKey(dsa));

        Assert.Contains("DSA", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void LiveCoreRejectsContainerOnlyFalsePositive()
    {
        const string malformed = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-key-material\n-----END OPENSSH PRIVATE KEY-----";
        OrbitNativeLibraryLoader.Register();

        var error = Assert.Throws<ArgumentException>(() =>
            SshPrivateKeyInspector.Inspect(malformed, string.Empty));

        Assert.Contains("无法解析", error.Message, StringComparison.Ordinal);
    }
}
