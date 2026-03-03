import SwiftUI

extension View {
    /// Plain list style with hidden scroll background — applied to every pablo List.
    func pabloListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
    }

    /// Clear row background + hidden separator — applied to every pablo list row.
    func pabloListRowStyle() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// White card with rounded corners and a subtle lifted shadow.
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        )
    }
}
