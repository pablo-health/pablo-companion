using System.Text.Json;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// The exchange response's <c>enrollment</c> field says whether this PC was
/// registered. A payload that could not be built is a failure whatever the
/// server says; a server that omits the field leaves nothing to report.
/// Mirrors <c>DeviceEnrollmentTests</c> on macOS.
/// </summary>
public class DeviceEnrollmentOutcomeTests
{
    private static EnrollmentOutcome Outcome(bool sentPayload, string json)
    {
        using var doc = JsonDocument.Parse(json);
        return DeviceEnrollment.Outcome(sentPayload, doc.RootElement);
    }

    [Fact]
    public void PayloadNotBuilt_IsFailed_WhateverTheServerSays()
    {
        Assert.Equal(EnrollmentOutcome.Failed, Outcome(false, """{"enrollment":"enrolled"}"""));
        Assert.Equal(EnrollmentOutcome.Failed, Outcome(false, "{}"));
    }

    [Fact]
    public void ServerReportsFailed_IsFailed() =>
        Assert.Equal(EnrollmentOutcome.Failed, Outcome(true, """{"enrollment":"failed"}"""));

    [Fact]
    public void ServerReportsEnrolled_IsEnrolled() =>
        Assert.Equal(EnrollmentOutcome.Enrolled, Outcome(true, """{"id_token":"t","enrollment":"enrolled"}"""));

    [Theory]
    [InlineData("""{"id_token":"t"}""")]
    [InlineData("""{"enrollment":null}""")]
    [InlineData("""{"enrollment":"pending"}""")]
    [InlineData("[]")]
    public void FieldMissingOrUnknown_IsUnreported(string json) =>
        Assert.Equal(EnrollmentOutcome.Unreported, Outcome(true, json));
}
