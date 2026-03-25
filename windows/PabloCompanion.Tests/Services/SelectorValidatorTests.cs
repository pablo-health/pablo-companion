using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class SelectorValidatorTests
{
    [Theory]
    [InlineData(".ProseMirror[aria-label='free-text-1']")]
    [InlineData("#my-element")]
    [InlineData("button.primary")]
    [InlineData("div > span.label")]
    [InlineData("[data-id='123']")]
    public void Validate_AcceptsValidSelectors(string selector)
    {
        var ex = Record.Exception(() => SelectorValidator.Validate(selector));
        Assert.Null(ex);
    }

    [Theory]
    [InlineData("javascript:alert(1)")]
    [InlineData("div; eval(document.cookie)")]
    [InlineData("a[href='javascript:void(0)']")]
    [InlineData("img onerror=alert(1)")]
    [InlineData("<script>alert(1)</script>")]
    [InlineData("div; fetch('http://evil.com')")]
    [InlineData("span; document.cookie")]
    [InlineData("div; window.location='evil'")]
    [InlineData("btn; setTimeout(fn, 0)")]
    [InlineData("x; setInterval(fn, 1000)")]
    [InlineData("x onclick=alert(1)")]
    [InlineData("x onload=alert(1)")]
    [InlineData("x; function(){ }")]
    [InlineData("x; XMLHttpRequest")]
    public void Validate_RejectsForbiddenPatterns(string selector)
    {
        Assert.Throws<EhrNavigatorException>(() => SelectorValidator.Validate(selector));
    }

    [Fact]
    public void Validate_RejectsTooLongSelector()
    {
        var longSelector = new string('a', 501);
        Assert.Throws<EhrNavigatorException>(() => SelectorValidator.Validate(longSelector));
    }

    [Fact]
    public void Validate_AcceptsMaxLengthSelector()
    {
        var selector = new string('a', 500);
        var ex = Record.Exception(() => SelectorValidator.Validate(selector));
        Assert.Null(ex);
    }

    [Fact]
    public void Validate_IsCaseInsensitive()
    {
        // "JAVASCRIPT:" should still be rejected
        Assert.Throws<EhrNavigatorException>(() =>
            SelectorValidator.Validate("JAVASCRIPT:alert(1)"));
    }
}
