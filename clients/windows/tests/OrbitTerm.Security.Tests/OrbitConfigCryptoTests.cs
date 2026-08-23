using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class OrbitConfigCryptoTests
{
    [Fact]
    public void V2RootDerivationMatchesSharedCoreSemantics()
    {
        OrbitNativeLibraryLoader.Register();
        var first = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "account-scope");
        var second = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "account-scope");
        var otherScope = OrbitConfigCrypto.DeriveConfigRootKeyV2("correct horse", "account-other");

        Assert.Equal(32, first.Length);
        Assert.Equal(first, second);
        Assert.NotEqual(first, otherScope);
    }
}
