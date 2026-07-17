import Foundation
import Testing
@testable import Pablo

/// Covers the patient pagination guards and the `hasMore` predicate that drives
/// them. Before pagination existed, `loadPatients` fetched page 1 and stopped,
/// so a caseload larger than one page was unreachable.
///
/// The append path itself (page N+1 merging into `patients`) needs a stubbed
/// `URLSession`; `APIClient` calls `URLSession.shared` directly with no seam to
/// inject one. Guard behaviour and the boundary math are covered here.
@Suite("Patient pagination")
@MainActor
struct PatientViewModelTests {

    // MARK: - loadMore guards

    @Test func loadMoreIsNoOpWhenNoMorePages() async {
        let viewModel = PatientViewModel()
        viewModel.hasMorePatients = false

        await viewModel.loadMorePatients()

        // Page must not advance, or the next real load would skip a page.
        #expect(viewModel.currentPage == 1)
    }

    @Test func loadMoreIsNoOpWithoutAuth() async {
        let viewModel = PatientViewModel()
        viewModel.hasMorePatients = true
        // No configureAuth call, so getToken is nil — must not fire a request.

        await viewModel.loadMorePatients()

        #expect(viewModel.currentPage == 1)
    }

    @Test func loadMoreIsNoOpWhileAlreadyLoading() async {
        let viewModel = PatientViewModel()
        viewModel.hasMorePatients = true
        viewModel.isLoading = true

        await viewModel.loadMorePatients()

        #expect(viewModel.currentPage == 1)
    }

    @Test func startsOnFirstPageWithNoMorePages() {
        let viewModel = PatientViewModel()
        #expect(viewModel.currentPage == 1)
        #expect(viewModel.hasMorePatients == false)
        #expect(viewModel.patients.isEmpty)
    }

    // MARK: - hasMore predicate

    @Test func hasMoreIsTrueWhenPageDoesNotCoverTotal() {
        let response = Self.makeResponse(count: 50, total: 120, page: 1, pageSize: 50)
        #expect(response.hasMore)
    }

    @Test func hasMoreIsFalseOnFinalPage() {
        let response = Self.makeResponse(count: 20, total: 120, page: 3, pageSize: 50)
        #expect(!response.hasMore)
    }

    @Test func hasMoreIsFalseWhenTotalFitsOnOnePage() {
        let response = Self.makeResponse(count: 12, total: 12, page: 1, pageSize: 50)
        #expect(!response.hasMore)
    }

    @Test func hasMoreIsFalseWhenTotalExactlyFillsPage() {
        // Boundary: 50 of 50 is not "more", or the UI offers an empty next page.
        let response = Self.makeResponse(count: 50, total: 50, page: 1, pageSize: 50)
        #expect(!response.hasMore)
    }

    @Test func hasMoreIsTrueOneOverPageBoundary() {
        let response = Self.makeResponse(count: 50, total: 51, page: 1, pageSize: 50)
        #expect(response.hasMore)
    }

    @Test func hasMoreIsFalseWhenEmpty() {
        let response = Self.makeResponse(count: 0, total: 0, page: 1, pageSize: 50)
        #expect(!response.hasMore)
    }

    // MARK: - Helpers

    private static func makeResponse(
        count: Int,
        total: UInt32,
        page: UInt32,
        pageSize: UInt32
    ) -> PatientListResponse {
        PatientListResponse(
            data: (0 ..< count).map { makePatient(index: $0) },
            total: total,
            page: page,
            pageSize: pageSize
        )
    }

    private static func makePatient(index: Int) -> Patient {
        Patient(
            id: "patient-\(index)",
            userId: "user-1",
            firstName: "Test",
            lastName: "Patient \(index)",
            email: nil,
            phone: nil,
            status: "active",
            dateOfBirth: nil,
            diagnosis: nil,
            sessionCount: 0,
            lastSessionDate: nil,
            nextSessionDate: nil,
            createdAt: "2026-07-16T00:00:00Z",
            updatedAt: "2026-07-16T00:00:00Z"
        )
    }
}
