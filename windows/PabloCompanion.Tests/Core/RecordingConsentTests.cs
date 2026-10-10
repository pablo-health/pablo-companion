using System.Globalization;
using System.Net;
using System.Text.Json;
using PabloCompanion.Core;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// The decision a client's answer about AI-assisted notes makes for a recording,
/// the read-aloud script, the request bodies, and the consent client against a
/// stubbed transport. Ported from macOS <c>RecordingConsentTests.swift</c>.
/// </summary>
public class RecordingConsentTests
{
    private static readonly RecordingConsent Clear = RecordingConsent.ClearValue;
    private static readonly AiConsentModality InPerson = AiConsentModality.InPerson;
    private static readonly AiConsentModality Tele = AiConsentModality.Telehealth;

    private static AiConsentEntry Entry(string decision) => new(decision, "2026-09-01");

    // --- decision ---

    [Fact]
    public void SettingOff_IsClearWhateverTheClientSaid()
    {
        Assert.Equal(Clear, RecordingConsent.Evaluate(asksClients: false, current: null));
        Assert.Equal(Clear, RecordingConsent.Evaluate(asksClients: false, current: Entry("declined")));
    }

    [Fact]
    public void SettingOn_WithNoAnswerInPerson_AsksOnceRecordingStarts()
        => Assert.Equal(new RecordingConsent.AskOnRecording(InPerson), RecordingConsent.Evaluate(true, null));

    [Fact]
    public void SettingOn_ConsentedIsClear_DeclinedStopsWithItsDate()
    {
        Assert.Equal(Clear, RecordingConsent.Evaluate(true, Entry("consented")));
        Assert.Equal(new RecordingConsent.Declined("2026-09-01"), RecordingConsent.Evaluate(true, Entry("declined")));
    }

    /// <summary>The gate decision across where the session is and what is on file.</summary>
    [Theory]
    [InlineData(false, null, "ask:in_person")]
    [InlineData(true, null, "ask:telehealth")]
    [InlineData(false, "consented", "clear")]
    [InlineData(true, "consented", "clear")]
    [InlineData(false, "declined", "declined:2026-09-01")]
    [InlineData(true, "declined", "declined:2026-09-01")]
    public void Gate_WhereTheSessionIsByWhatIsOnFile(bool telehealth, string? onFile, string expected)
    {
        var current = onFile is null ? null : Entry(onFile);
        Assert.Equal(expected, Describe(RecordingConsent.Evaluate(true, current, telehealth)));
    }

    [Fact]
    public void SettingOff_IsClearForTelehealthToo()
        => Assert.Equal(Clear, RecordingConsent.Evaluate(asksClients: false, current: null, telehealth: true));

    // --- hand-off ---

    [Fact]
    public void InPersonHandOffTheWebAlreadyAskedAbout_DoesNotAskAgain()
    {
        Assert.Equal(Clear, new RecordingConsent.AskOnRecording(InPerson).HandedOff(webAlreadyAsked: true));
        Assert.Equal(Clear, Clear.HandedOff(webAlreadyAsked: true));
    }

    [Fact]
    public void ADeclineStillStopsAHandOffTheWebAlreadyAskedAbout()
        => Assert.Equal(new RecordingConsent.Declined("2026-09-01"),
            new RecordingConsent.Declined("2026-09-01").HandedOff(webAlreadyAsked: true));

    [Fact]
    public void WithoutTheWebsAnswer_AHandOffStillAsks()
    {
        Assert.Equal(new RecordingConsent.AskOnRecording(InPerson),
            new RecordingConsent.AskOnRecording(InPerson).HandedOff(webAlreadyAsked: false));
        Assert.Equal(new RecordingConsent.Declined("2026-09-01"),
            new RecordingConsent.Declined("2026-09-01").HandedOff(webAlreadyAsked: false));
        Assert.Equal(Clear, Clear.HandedOff(webAlreadyAsked: false));
    }

    [Fact]
    public void AWebRecordAnyway_NeverClearsATelehealthStartWithNothingOnFile()
        => Assert.Equal(new RecordingConsent.AskOnRecording(Tele),
            new RecordingConsent.AskOnRecording(Tele).HandedOff(webAlreadyAsked: true));

    [Theory]
    [InlineData(AiConsentModality.InPerson)]
    [InlineData(AiConsentModality.Telehealth)]
    public void AWebAskNow_StartsAskingOnTheRecordingWithoutOfferingItAgain(AiConsentModality modality)
    {
        Assert.Equal(new RecordingConsent.AskingOnRecording(modality),
            new RecordingConsent.AskOnRecording(modality).HandedOff(webAlreadyAsked: false, webAskingOnRecording: true));
        Assert.True(new RecordingConsent.AskingOnRecording(modality).StartsAskingOnRecording);
        Assert.Equal(modality, new RecordingConsent.AskingOnRecording(modality).AskingModality);
        // Answered since the web asked: nothing to ask on the recording.
        Assert.Equal(Clear, Clear.HandedOff(webAlreadyAsked: false, webAskingOnRecording: true));
        Assert.Equal(new RecordingConsent.Declined("2026-09-01"),
            new RecordingConsent.Declined("2026-09-01").HandedOff(webAlreadyAsked: false, webAskingOnRecording: true));
        Assert.False(Clear.StartsAskingOnRecording);
        Assert.False(new RecordingConsent.AskOnRecording(modality).StartsAskingOnRecording);
        Assert.Null(new RecordingConsent.AskOnRecording(modality).AskingModality);
    }

    /// <summary>The full hand-off matrix: every consent by both web answers.</summary>
    [Theory]
    [InlineData("clear", false, false, "clear")]
    [InlineData("clear", true, false, "clear")]
    [InlineData("clear", false, true, "clear")]
    [InlineData("clear", true, true, "clear")]
    [InlineData("ask:in_person", false, false, "ask:in_person")]
    [InlineData("ask:in_person", true, false, "clear")]
    [InlineData("ask:in_person", false, true, "asking:in_person")]
    [InlineData("ask:in_person", true, true, "asking:in_person")]
    [InlineData("ask:telehealth", false, false, "ask:telehealth")]
    [InlineData("ask:telehealth", true, false, "ask:telehealth")]
    [InlineData("ask:telehealth", false, true, "asking:telehealth")]
    [InlineData("ask:telehealth", true, true, "asking:telehealth")]
    [InlineData("declined:2026-09-01", false, false, "declined:2026-09-01")]
    [InlineData("declined:2026-09-01", true, false, "declined:2026-09-01")]
    [InlineData("declined:2026-09-01", false, true, "declined:2026-09-01")]
    [InlineData("declined:2026-09-01", true, true, "declined:2026-09-01")]
    public void HandedOff_Matrix(string from, bool webAlreadyAsked, bool webAskingOnRecording, string expected)
        => Assert.Equal(expected, Describe(Parse(from).HandedOff(webAlreadyAsked, webAskingOnRecording)));

    // --- refusals ---

    [Fact]
    public void TheServersConsentNeededRefusalIsRecognized()
    {
        const string body = """
            {"error": {"code": "CLIENT_AI_CONSENT_NEEDED",
                       "message": "Ask this client about AI-assisted notes when recording starts."}}
            """;
        Assert.True(RecordingConsent.IsConsentNeeded(403, body));
        Assert.False(RecordingConsent.IsConsentNeeded(409, body));
        const string declined = """{"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "x"}}""";
        Assert.False(RecordingConsent.IsConsentNeeded(403, declined));
        Assert.Null(RecordingConsent.DeclinedOn(403, body));
    }

    [Fact]
    public void TheServersDeclinedRefusalIsRecognizedWithItsDate()
    {
        const string body = """
            {"error": {"code": "CLIENT_DECLINED_AI_NOTES",
                       "message": "This client declined AI-assisted notes.",
                       "details": {"declined_on": "2026-09-01"}}}
            """;
        Assert.Equal("2026-09-01", RecordingConsent.DeclinedOn(403, body));
    }

    [Fact]
    public void ARefusalWithoutADateStillReadsAsDeclined()
        => Assert.Equal("", RecordingConsent.DeclinedOn(403,
            """{"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "x", "details": {}}}"""));

    [Fact]
    public void OtherRefusalsAreNotADecline()
    {
        Assert.Null(RecordingConsent.DeclinedOn(403, """{"error": {"code": "SUBSCRIPTION_REQUIRED", "message": "x"}}"""));
        Assert.Null(RecordingConsent.DeclinedOn(409, """{"error": {"code": "CLIENT_DECLINED_AI_NOTES"}}"""));
        Assert.Null(RecordingConsent.DeclinedOn(403, "not json"));
    }

    [Fact]
    public void APIClientCarriesTheRefusalsCodeAndDetailsOntoPabloException()
    {
        var declined = APIClient.MapError(403, """
            {"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "x", "details": {"declined_on": "2026-09-01"}}}
            """);
        Assert.Equal((ushort)403, declined.StatusCode);
        Assert.Equal(RecordingConsent.DeclinedErrorCode, declined.ErrorCode);
        Assert.Equal("2026-09-01", declined.ErrorDetails["declined_on"]);

        var needed = APIClient.MapError(403, """{"error": {"code": "CLIENT_AI_CONSENT_NEEDED", "message": "x"}}""");
        Assert.Equal(RecordingConsent.ConsentNeededErrorCode, needed.ErrorCode);
        Assert.Empty(needed.ErrorDetails);

        var other = APIClient.MapError(403, "Forbidden");
        Assert.Null(other.ErrorCode);
        Assert.Empty(other.ErrorDetails);
    }

    // --- telehealth ---

    [Fact]
    public void TelehealthIsAVideoServiceAVideoLinkOrATelehealthPlace()
    {
        Assert.True(Telehealth.IsTelehealth("doxy_me", null, null));
        Assert.True(Telehealth.IsTelehealth(null, "https://video.example/room", null));
        Assert.True(Telehealth.IsTelehealth(null, null, "10"));
        Assert.True(Telehealth.IsTelehealth(null, null, "02"));
        Assert.False(Telehealth.IsTelehealth(null, null, "11"));
        Assert.False(Telehealth.IsTelehealth(null, null, null));
        Assert.False(Telehealth.IsTelehealth("", "", null));
        Assert.Equal(Tele, Telehealth.Modality(null, null, "02"));
        Assert.Equal(InPerson, Telehealth.Modality(null, null, "11"));
    }

    [Fact]
    public void DatesReadTheWayAPersonSaysThem()
    {
        var enUS = CultureInfo.GetCultureInfo("en-US");
        Assert.Equal("Oct 5, 2026", RecordingConsent.DisplayDate("2026-10-05", enUS));
        Assert.Equal("garbage", RecordingConsent.DisplayDate("garbage", enUS));
    }

    // --- script ---

    [Fact]
    public void RetentionReadsInYearsWhenItIsWholeYears()
    {
        Assert.Equal("1 year", ConsentScript.Retention(365));
        Assert.Equal("2 years", ConsentScript.Retention(730));
        Assert.Equal("90 days", ConsentScript.Retention(90));
        Assert.Equal("1 day", ConsentScript.Retention(1));
    }

    [Theory]
    [InlineData(0, "The audio is deleted once your note is signed.")]
    [InlineData(1, "The audio is kept for up to 1 day.")]
    [InlineData(365, "The audio is kept for up to 1 year.")]
    [InlineData(730, "The audio is kept for up to 2 years.")]
    public void TheScriptNamesThePracticesRetentionWindow(int days, string retentionLine)
    {
        // Word for word the web app's script.
        Assert.Equal(
            [
                "I've started recording our session.",
                "The recording is turned into a written transcript, and an AI tool uses it to draft my notes. "
                    + "I read and correct every note myself.",
                retentionLine,
                "You can say no, now or at any time.",
                "Is that all right with you?",
            ],
            ConsentScript.Lines(days));
    }

    [Fact]
    public void AtZeroDaysTheScriptNeverSaysZeroDays()
    {
        var lines = ConsentScript.Lines(0);
        Assert.Equal(5, lines.Count);
        Assert.DoesNotContain("0 days", string.Concat(lines));
    }

    // --- request bodies ---

    [Fact]
    public void AnAnswerGivenInTheRoomSaysInPersonAndWhoAnswered_AndNeverAPlace()
    {
        var answer = new AiConsentAnswer(AiConsentEntry.ConsentedDecision, InPerson, AiConsentGiver.Parent, "Office");
        Assert.Equal(
            new Dictionary<string, string> { ["decision"] = "consented", ["modality"] = "in_person", ["consented_by"] = "parent" },
            answer.Body);
    }

    [Fact]
    public void ATelehealthAnswerCarriesWhereTheClientSaidTheyWere_Trimmed()
    {
        var answer = new AiConsentAnswer("consented", Tele, AiConsentGiver.Client, "  At home  ");
        Assert.Equal(
            new Dictionary<string, string>
            {
                ["decision"] = "consented",
                ["modality"] = "telehealth",
                ["consented_by"] = "client",
                ["client_stated_location"] = "At home",
            },
            answer.Body);
    }

    [Fact]
    public void ABlankPlaceOrOneGivenInPerson_IsNotSent()
    {
        var blank = new AiConsentAnswer("declined", Tele, AiConsentGiver.Guardian, "  ");
        Assert.False(blank.Body.ContainsKey("client_stated_location"));
        Assert.Equal("guardian", blank.Body["consented_by"]);
        var inPerson = new AiConsentAnswer("consented", InPerson, AiConsentGiver.Client, "Office");
        Assert.False(inPerson.Body.ContainsKey("client_stated_location"));
    }

    [Fact]
    public void APlaceLongerThanTheServerKeepsIsCutToFit()
    {
        var answer = new AiConsentAnswer("consented", Tele, AiConsentGiver.Client, new string('a', 300));
        Assert.Equal(AiConsentAnswer.LocationMaxLength, answer.Body["client_stated_location"].Length);
    }

    [Fact]
    public void AStartAskingOnTheRecordingSaysSo_AnyOtherStartSendsNoBody()
    {
        Assert.Null(RecordingConsentClient.StartSessionBody(askingConsentOnRecording: false));
        var body = RecordingConsentClient.StartSessionBody(askingConsentOnRecording: true);
        Assert.NotNull(body);
        Assert.Equal(new Dictionary<string, bool> { ["asking_consent_on_recording"] = true },
            JsonSerializer.Deserialize<Dictionary<string, bool>>(body!));
    }

    // --- client, against a stubbed transport ---

    private const string SettingOn = """{"ask_clients_about_ai_notes": true, "audio_retention_days": 365, "can_change": false}""";
    private const string SettingOff = """{"ask_clients_about_ai_notes": false, "audio_retention_days": 30, "can_change": true}""";
    private const string NoAnswer = """{"current": null, "history": []}""";

    private static RecordingConsentClient MakeClient(StubHandler handler) => new(
        baseUrl: () => "https://backend.test",
        token: () => Task.FromResult("test-bearer"),
        attachBinding: request =>
        {
            request.Headers.Add("DPoP", "proof-abc");
            request.Headers.Add("X-Install-ID", "install-1");
        },
        http: new HttpClient(handler, disposeHandler: false));

    [Fact]
    public async Task SettingOff_OneRequest_Clear_AndTheClientIsNeverLookedUp()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, SettingOff);

        var check = await MakeClient(handler).CheckAsync("appt-1");

        Assert.Equal(new RecordingConsentCheck(Clear, false, 30, null), check);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("/api/users/me/practice/ai-notes-consent", request.Path);
        Assert.Equal("Bearer test-bearer", request.Authorization);
        Assert.Equal("proof-abc", request.Headers["DPoP"]);
    }

    [Fact]
    public async Task AHandOffWithOnlyAnAppointmentId_LooksUpItsClient_ThenTheAnswer()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, SettingOn)
            .Respond(HttpStatusCode.OK, """{"id": "appt-1", "patient_id": "pat-9", "title": "x"}""")
            .Respond(HttpStatusCode.OK, NoAnswer);

        var check = await MakeClient(handler).CheckAsync("appt-1");

        Assert.Equal(new RecordingConsent.AskOnRecording(InPerson), check.Consent);
        Assert.Equal("pat-9", check.PatientId);
        Assert.Equal(365, check.AudioRetentionDays);
        Assert.Equal(
            ["/api/users/me/practice/ai-notes-consent", "/api/appointments/appt-1", "/api/patients/pat-9/ai-consent"],
            handler.Requests.Select(r => r.Path));
    }

    [Fact]
    public async Task AKnownClientSkipsTheAppointmentLookup_ADeclineCarriesItsDate()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, SettingOn)
            .Respond(HttpStatusCode.OK, """
                {"current": {"id": "e1", "decision": "declined", "effective_on": "2026-09-01", "source": "clinician",
                             "recorded_by_name": "A", "recorded_at": "2026-09-01T10:00:00Z"},
                 "history": []}
                """);

        var check = await MakeClient(handler).CheckAsync("appt-1", patientId: "pat-9");

        Assert.Equal(new RecordingConsent.Declined("2026-09-01"), check.Consent);
        Assert.Equal(
            ["/api/users/me/practice/ai-notes-consent", "/api/patients/pat-9/ai-consent"],
            handler.Requests.Select(r => r.Path));
    }

    [Fact]
    public async Task AnAppointmentWithNoClientYet_IsClear()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, SettingOn)
            .Respond(HttpStatusCode.OK, """{"id": "appt-1", "patient_id": ""}""");

        var check = await MakeClient(handler).CheckAsync("appt-1");

        Assert.Equal(Clear, check.Consent);
        Assert.True(check.AsksClients);
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task AHandOffReadsTelehealthFromTheAppointment_WhenTheRedeemDidNotSay()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, SettingOn)
            .Respond(HttpStatusCode.OK, """{"id": "appt-1", "patient_id": "pat-9", "video_link": "https://video.example/r"}""")
            .Respond(HttpStatusCode.OK, NoAnswer);

        var check = await MakeClient(handler).CheckAsync("appt-1");

        Assert.Equal(new RecordingConsent.AskOnRecording(Tele), check.Consent);
    }

    [Fact]
    public async Task TheCallersTelehealthAnswerWinsOverTheAppointments()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, SettingOn)
            .Respond(HttpStatusCode.OK, NoAnswer);

        var check = await MakeClient(handler).CheckAsync("appt-1", patientId: "pat-9", modality: Tele);

        Assert.Equal(new RecordingConsent.AskOnRecording(Tele), check.Consent);
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task ATelehealthAnswerPostsHowItWasGiven_WithNoDate()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.Created, NoAnswer);

        await MakeClient(handler).RecordAsync(
            new AiConsentAnswer("consented", Tele, AiConsentGiver.Guardian, "At home"), "pat-9");

        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("/api/patients/pat-9/ai-consent", request.Path);
        Assert.Equal("application/json; charset=utf-8", request.ContentType);
        Assert.Equal(
            new Dictionary<string, string>
            {
                ["decision"] = "consented",
                ["modality"] = "telehealth",
                ["consented_by"] = "guardian",
                ["client_stated_location"] = "At home",
            },
            JsonSerializer.Deserialize<Dictionary<string, string>>(request.Body));
    }

    [Fact]
    public async Task AnInPersonAnswerPostsHowItWasGiven_WithNoDate()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.Created, """
            {"current": {"id": "e2", "decision": "consented", "effective_on": "2026-10-05", "source": "clinician",
                         "recorded_by_name": "A", "recorded_at": "2026-10-05T10:00:00Z"},
             "history": []}
            """);

        await MakeClient(handler).RecordAsync(
            new AiConsentAnswer(AiConsentEntry.ConsentedDecision, InPerson, AiConsentGiver.Client), "pat-9");

        var request = Assert.Single(handler.Requests);
        Assert.Equal(
            new Dictionary<string, string> { ["decision"] = "consented", ["modality"] = "in_person", ["consented_by"] = "client" },
            JsonSerializer.Deserialize<Dictionary<string, string>>(request.Body));
    }

    [Fact]
    public async Task AFailedRequestSurfacesItsStatusAndCode()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.Unauthorized,
            """{"error": {"code": "IDLE_TIMEOUT", "message": "x"}}""");

        var ex = await Assert.ThrowsAsync<ConsentRequestException>(() => MakeClient(handler).RecordAsync(
            new AiConsentAnswer("consented", InPerson, AiConsentGiver.Client), "pat-9"));

        Assert.Equal(401, ex.StatusCode);
        Assert.Equal("IDLE_TIMEOUT", ex.Code);
    }

    // --- helpers ---

    private static string Describe(RecordingConsent consent) => consent switch
    {
        RecordingConsent.Clear => "clear",
        RecordingConsent.AskOnRecording ask => $"ask:{ask.Modality.Wire()}",
        RecordingConsent.AskingOnRecording asking => $"asking:{asking.Modality.Wire()}",
        RecordingConsent.Declined declined => $"declined:{declined.On}",
        _ => "?",
    };

    private static RecordingConsent Parse(string text) => text switch
    {
        "clear" => Clear,
        "ask:in_person" => new RecordingConsent.AskOnRecording(InPerson),
        "ask:telehealth" => new RecordingConsent.AskOnRecording(Tele),
        _ when text.StartsWith("declined:", StringComparison.Ordinal) => new RecordingConsent.Declined(text["declined:".Length..]),
        _ => throw new ArgumentException(text),
    };

    private sealed record Recorded(
        HttpMethod Method, string Path, string Body, string? Authorization,
        Dictionary<string, string> Headers, string? ContentType);

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Queue<(HttpStatusCode Status, string Body)> _responses = new();

        public List<Recorded> Requests { get; } = [];

        public StubHandler Respond(HttpStatusCode status, string body)
        {
            _responses.Enqueue((status, body));
            return this;
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add(new Recorded(
                request.Method,
                request.RequestUri!.AbsolutePath,
                body,
                request.Headers.Authorization?.ToString(),
                request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value)),
                request.Content?.Headers.ContentType?.ToString()));

            Assert.True(_responses.Count > 0, $"unexpected request: {request.Method} {request.RequestUri}");
            var (status, responseBody) = _responses.Dequeue();
            return new HttpResponseMessage(status) { Content = new StringContent(responseBody) };
        }
    }
}
