using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Verifies per-user encryption key scoping. In particular, the app must never fall
/// through to a shared <c>encryptionKey_</c> entry when no user is signed in.
/// </summary>
public class CredentialManagerKeyScopingTests
{
    [Fact]
    public void GetOrCreateUserEncryptionKey_ReturnsNull_WhenNoActiveUser()
    {
        var credentials = new CredentialManager { ActiveUserEmail = null };

        var key = credentials.GetOrCreateUserEncryptionKey();

        Assert.Null(key);
    }

    [Fact]
    public void GetOrCreateUserEncryptionKey_ReturnsNull_WhenActiveUserIsEmpty()
    {
        var credentials = new CredentialManager { ActiveUserEmail = "" };

        var key = credentials.GetOrCreateUserEncryptionKey();

        Assert.Null(key);
    }

    [Fact]
    public void GetOrCreateUserEncryptionKey_ReturnsNull_WhenActiveUserIsWhitespace()
    {
        var credentials = new CredentialManager { ActiveUserEmail = "   " };

        var key = credentials.GetOrCreateUserEncryptionKey();

        Assert.Null(key);
    }

    [Fact]
    public void GetOrCreateEncryptionKey_ReturnsNull_OnEmptyEmail()
    {
        var credentials = new CredentialManager();

        Assert.Null(credentials.GetOrCreateEncryptionKey(""));
        Assert.Null(credentials.GetOrCreateEncryptionKey("   "));
    }
}
