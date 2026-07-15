using System.Buffers.Binary;
using System.Security.Cryptography;

namespace RecordHarness;

/// <summary>
/// RFC 6238 TOTP, matching the e2e suite's <c>otplib</c> authenticator defaults
/// (HMAC-SHA1, 6 digits, 30-second step). Used only to sign the pinned test user
/// in; it is not part of the shipping client.
///
/// The C# port of the harness's Swift <c>TOTP</c>.
/// </summary>
public static class Totp
{
    private const int StepSeconds = 30;
    private const int Digits = 6;

    /// <summary>
    /// The TOTP code for <paramref name="base32Secret"/> at <paramref name="now"/>
    /// (default: current time).
    /// </summary>
    public static string Code(string base32Secret, DateTimeOffset? now = null)
    {
        var key = Base32Decode(base32Secret);
        var counter = (ulong)((now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds() / StepSeconds);

        Span<byte> counterBytes = stackalloc byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(counterBytes, counter);

        Span<byte> hash = stackalloc byte[20]; // SHA-1
        HMACSHA1.HashData(key, counterBytes, hash);

        // RFC 4226 §5.4 dynamic truncation.
        var offset = hash[^1] & 0x0F;
        var binary = ((uint)(hash[offset] & 0x7F) << 24)
                   | ((uint)hash[offset + 1] << 16)
                   | ((uint)hash[offset + 2] << 8)
                   | hash[offset + 3];

        return (binary % 1_000_000).ToString($"D{Digits}");
    }

    /// <summary>
    /// Waits for the start of a fresh 30s window before generating a code, so it
    /// isn't milliseconds from expiry when the server checks it. Mirrors
    /// <c>freshTotp</c> in the e2e suite: wait into the last 3s of the current
    /// window, then 3s past the boundary.
    /// </summary>
    public static async Task<string> FreshCodeAsync(
        string base32Secret, CancellationToken cancellationToken = default)
    {
        while (StepSeconds - DateTimeOffset.UtcNow.ToUnixTimeSeconds() % StepSeconds >= 3)
            await Task.Delay(500, cancellationToken);

        await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
        return Code(base32Secret);
    }

    /// <summary>RFC 4648 base32 decode (upper-case alphabet, padding/space tolerant).</summary>
    public static byte[] Base32Decode(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

        var output = new List<byte>(value.Length * 5 / 8 + 1);
        int bits = 0, accumulator = 0;

        foreach (var c in value.ToUpperInvariant())
        {
            if (c is ' ' or '=') continue;
            var index = Alphabet.IndexOf(c, StringComparison.Ordinal);
            if (index < 0) continue; // tolerate formatting characters, as the Swift port does

            accumulator = (accumulator << 5) | index;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                output.Add((byte)((accumulator >> bits) & 0xFF));
            }
        }

        return [.. output];
    }
}
