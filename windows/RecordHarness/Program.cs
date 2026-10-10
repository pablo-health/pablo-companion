using RecordHarness;

// Scenario dispatch, mirroring the Swift practice-harness's PRACTICE_SCENARIO
// switch, so the CI jobs and the macOS ones read the same:
//   record   recording -> queue -> signed-URL upload -> SOAP (RecordScenario.cs)
//   consent  the AI-notes consent wire path, no audio (ConsentScenario.cs)
//   visit    consent -> record -> agree (upload -> SOAP) or decline (no audio
//            left), chosen by VISIT_ANSWER (VisitScenario.cs)
var scenario = Harness.Env("PRACTICE_SCENARIO") ?? "record";
var started = DateTimeOffset.UtcNow;

try
{
    switch (scenario)
    {
        case "record":
            await RecordScenario.RunAsync();
            break;
        case "consent":
            await ConsentScenario.RunAsync();
            break;
        case "visit":
            await VisitScenario.RunAsync();
            break;
        default:
            throw new HarnessException(
                $"unknown PRACTICE_SCENARIO '{scenario}' (supported: record, consent, visit)");
    }
    Harness.Log($"{scenario}: {(DateTimeOffset.UtcNow - started).TotalSeconds:F0}s wall clock");
    return 0;
}
catch (HarnessException ex)
{
    // The expected failure shape: a gate that failed or a precondition that
    // wasn't met. The message is the whole story, so no stack trace.
    Harness.Log($"ERROR: {ex.Message}");
    Harness.Log($"{scenario}: {(DateTimeOffset.UtcNow - started).TotalSeconds:F0}s wall clock");
    return 1;
}
catch (Exception ex)
{
    // Anything else is a harness bug rather than a gate result — keep the trace.
    Harness.Log($"ERROR: unexpected {ex.GetType().Name}: {ex}");
    return 2;
}
