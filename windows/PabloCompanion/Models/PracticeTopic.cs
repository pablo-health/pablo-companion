namespace PabloCompanion.Models;

/// <summary>
/// A practice session topic from the backend catalog.
/// </summary>
public sealed record PracticeTopic(
    string Id,
    string Name,
    string Description,
    string Category,
    int EstimatedDurationMinutes
);

public sealed record PracticeTopicListResponse(
    PracticeTopic[] Data,
    int Total
);
