import CompanionSessionCore

extension Appointment {
    /// Held over video or phone: a video service, a video link, or a
    /// telehealth place of service. The server decides the same way.
    var isTelehealth: Bool {
        Telehealth.isTelehealth(provider: provider, videoLink: videoLink, placeOfService: placeOfService)
    }

    var modality: AiConsentModality {
        isTelehealth ? .telehealth : .inPerson
    }
}
