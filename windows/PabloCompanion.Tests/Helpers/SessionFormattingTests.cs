using PabloCompanion.Helpers;
using uniffi.pablo_core;

namespace PabloCompanion.Tests.Helpers;

public class SessionFormattingTests
{
    [Fact]
    public void FormatStatus_InProgress_ReturnsString()
    {
        Assert.Equal("In Progress", SessionFormatting.FormatStatus(SessionStatus.InProgress));
    }

    [Fact]
    public void FormatStatus_Scheduled_ReturnsString()
    {
        Assert.Equal("Scheduled", SessionFormatting.FormatStatus(SessionStatus.Scheduled));
    }
}
