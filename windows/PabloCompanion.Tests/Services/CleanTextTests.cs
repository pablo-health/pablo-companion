using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class CleanTextTests
{
    [Fact]
    public void StripQuotes()
    {
        Assert.Equal("Hello world.", WhisperTranscriber.CleanText("\"Hello world.\""));
        Assert.Equal("Hello", WhisperTranscriber.CleanText("  \"Hello\"  "));
    }

    [Fact]
    public void PreserveInnerQuotes()
    {
        Assert.Equal("She said \"hello\" to me.",
            WhisperTranscriber.CleanText("She said \"hello\" to me."));
    }

    [Fact]
    public void EmptyAfterStrip()
    {
        Assert.Equal("", WhisperTranscriber.CleanText("  "));
        Assert.Equal("", WhisperTranscriber.CleanText("\"\""));
    }
}
