using System.Reflection;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// PkceHelper is internal to the PabloCompanion assembly, so we reach it via reflection
/// rather than leaking it into the public API just for tests.
/// </summary>
public class OAuthStateTests
{
    private static readonly Type PkceHelperType =
        typeof(AuthViewModel).Assembly.GetType("PabloCompanion.ViewModels.PkceHelper")
        ?? throw new InvalidOperationException("PkceHelper type not found");

    private static string GenerateState() =>
        (string)PkceHelperType.GetMethod("GenerateState", BindingFlags.Public | BindingFlags.Static)!
            .Invoke(null, null)!;

    private static bool ConstantTimeEquals(string a, string b) =>
        (bool)PkceHelperType.GetMethod("ConstantTimeEquals", BindingFlags.Public | BindingFlags.Static)!
            .Invoke(null, [a, b])!;

    [Fact]
    public void GeneratedStateIsUrlSafe()
    {
        var state = GenerateState();
        foreach (var ch in state)
        {
            Assert.True(
                char.IsLetterOrDigit(ch) || ch == '-' || ch == '_',
                $"state contained non-URL-safe char: {ch}");
        }
    }

    [Fact]
    public void GeneratedStateHasSufficientEntropy()
    {
        var state = GenerateState();
        Assert.True(state.Length >= 43, $"state too short: {state.Length}");
    }

    [Fact]
    public void GeneratedStatesAreUnique()
    {
        var seen = new HashSet<string>();
        for (var i = 0; i < 100; i++) seen.Add(GenerateState());
        Assert.Equal(100, seen.Count);
    }

    [Fact]
    public void ConstantTimeEquals_AcceptsEqual() =>
        Assert.True(ConstantTimeEquals("abc123", "abc123"));

    [Fact]
    public void ConstantTimeEquals_RejectsDifferent() =>
        Assert.False(ConstantTimeEquals("abc123", "abc124"));

    [Fact]
    public void ConstantTimeEquals_RejectsDifferentLengths() =>
        Assert.False(ConstantTimeEquals("abc", "abcd"));

    [Fact]
    public void ConstantTimeEquals_HandlesEmpty() =>
        Assert.True(ConstantTimeEquals("", ""));

    [Fact]
    public void ConstantTimeEquals_EmptyVsNonEmpty() =>
        Assert.False(ConstantTimeEquals("", "abc"));
}
