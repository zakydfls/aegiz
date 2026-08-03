import SwiftUI

struct ModuleFoundationView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            AegizPageHeader(
                title,
                subtitle: "Adapter foundation",
                symbol: symbol
            ) { EmptyView() }
            Divider()
            ContentUnavailableView {
                Label("\(title) workspace", systemImage: symbol)
            } description: {
                Text(message)
            }
        }
        .background(AegizTheme.raised)
        .navigationTitle(title)
    }
}
