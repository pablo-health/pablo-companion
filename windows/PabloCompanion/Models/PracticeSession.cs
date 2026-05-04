namespace PabloCompanion.Models;

/// <summary>
/// Response from POST /api/practice/sessions.
/// </summary>
public sealed record PracticeSessionResponse(
    string SessionId,
    string TopicId,
    string TopicName,
    string Status,
    string WsUrl,
    string WsTicket,
    string CreatedAt
);

/// <summary>
/// Response from POST /api/practice/ws-ticket.
/// </summary>
public sealed record PracticeTicketResponse(
    string Ticket
);

/// <summary>
/// Response from GET /api/practice/sessions/{id}.
/// </summary>
public sealed record PracticeSessionDetail(
    string SessionId,
    string TopicId,
    string TopicName,
    string Status,
    int? DurationSeconds,
    string? StartedAt,
    string? EndedAt,
    string CreatedAt
);
