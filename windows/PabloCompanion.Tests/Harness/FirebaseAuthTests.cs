using RecordHarness;

namespace PabloCompanion.Tests.Harness;

/// <summary>
/// Which sign-in failures the harness retries in the next TOTP window: only a
/// refused code at MFA finalize, the shape a concurrent sign-in to the shared
/// test account produces. Anything else must fail the run as before.
/// </summary>
public class FirebaseAuthTests
{
    [Fact]
    public void IsCodeAlreadyUsed_TrueForInvalidCodeAtFinalize()
    {
        var ex = new HarnessException(
            "v2/accounts/mfaSignIn:finalize failed: 400 {\"error\":{\"code\":400,\"message\":\"INVALID_CODE\"}}");

        Assert.True(FirebaseAuth.IsCodeAlreadyUsed(ex));
    }

    [Theory]
    [InlineData("v1/accounts:signInWithPassword failed: 400 {\"error\":{\"message\":\"INVALID_PASSWORD\"}}")]
    [InlineData("v2/accounts/mfaSignIn:finalize failed: 400 {\"error\":{\"message\":\"MISSING_MFA_PENDING_CREDENTIAL\"}}")]
    [InlineData("v2/accounts/mfaSignIn:finalize failed: 500 {\"error\":{\"message\":\"INVALID_CODE\"}}")]
    [InlineData("mfaSignIn:finalize response missing idToken/refreshToken")]
    public void IsCodeAlreadyUsed_FalseForEveryOtherFailure(string message)
    {
        Assert.False(FirebaseAuth.IsCodeAlreadyUsed(new HarnessException(message)));
    }
}
