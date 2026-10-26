import SwiftUI

/// 「我发了」：平台只有一个号时点一下；有几个号时弹出来选哪个号发了
struct PostedToggle<Label: View>: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    let platform: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        let accs = store.accounts(on: platform)
        if accs.count > 1, let a = store.article(articleId) {
            Menu {
                ForEach(accs) { acc in
                    Button((store.isPosted(a, acc) ? "✓ " : "") + acc.name) { store.togglePosted(articleId, platform, acc) }
                }
            } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        } else {
            Button { store.togglePosted(articleId, platform, accs.first) } label: { label() }
                .buttonStyle(RowButton())
        }
    }
}
