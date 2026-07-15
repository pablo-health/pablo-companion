using RecordHarness;

// Scenario dispatch, mirroring the Swift practice-harness's PRACTICE_SCENARIO
// switch. Only `record` exists on Windows today; the name is kept so the CI job
// and the macOS one read the same.
var scenario = Harness.Env("PRACTICE_SCENARIO") ?? "record";

try
{
    switch (scenario)
    {
        case "record":
            await RecordScenario.RunAsync();
            break;
        default:
            throw new HarnessException(
                $"unknown PRACTICE_SCENARIO '{scenario}' (supported: record)");
    }
    return 0;
}
catch (HarnessException ex)
{
    // The expected failure shape: a gate that failed or a precondition that
    // wasn't met. The message is the whole story, so no stack trace.
    Harness.Log($"ERROR: {ex.Message}");
    return 1;
}
catch (Exception ex)
{
    // Anything else is a harness bug rather than a gate result — keep the trace.
    Harness.Log($"ERROR: unexpected {ex.GetType().Name}: {ex}");
    return 2;
}
