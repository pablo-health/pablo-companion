using System.Diagnostics;
using System.Text.RegularExpressions;

namespace PabloCompanion.Services;

/// <summary>
/// Launches video calls via URL schemes (Zoom, Teams) or browser (Meet).
/// Mirrors VideoLaunchService.swift on macOS.
/// </summary>
public sealed partial class VideoLaunchService
{
    [GeneratedRegex(@"zoom\.us/j/(\d+)")]
    private static partial Regex ZoomMeetingIdRegex();

    private static readonly HashSet<string> AllowedVideoHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "zoom.us", "us02web.zoom.us", "us04web.zoom.us", "us05web.zoom.us", "us06web.zoom.us",
        "teams.microsoft.com", "teams.live.com",
        "meet.google.com",
    };

    private static bool IsAllowedVideoDomain(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        if (!string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return false;
        var host = uri.Host;
        return AllowedVideoHosts.Contains(host)
            || host.EndsWith(".zoom.us", StringComparison.OrdinalIgnoreCase);
    }

    public void LaunchVideoCall(string? videoLink, string? platform)
    {
        if (string.IsNullOrWhiteSpace(videoLink)) return;

        if (!IsAllowedVideoDomain(videoLink)) return;

        var url = platform?.ToLowerInvariant() switch
        {
            "zoom" => ConvertToZoomScheme(videoLink),
            "teams" => ConvertToTeamsScheme(videoLink),
            _ => videoLink, // Meet and others: open in browser
        };

        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true,
        });
    }

    private static string ConvertToZoomScheme(string url)
    {
        var match = ZoomMeetingIdRegex().Match(url);
        if (match.Success)
        {
            return $"zoommtg://zoom.us/join?confno={match.Groups[1].Value}";
        }
        // If we can't extract the meeting ID, try the URL as-is via browser
        return url;
    }

    private static string ConvertToTeamsScheme(string url)
    {
        if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return "msteams:" + url["https:".Length..];
        }
        return url;
    }
}
