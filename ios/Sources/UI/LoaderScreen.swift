import SwiftUI

/// A scrolling screen fed by one GET: a spinner first, the saved copy at once if there is one, an error with "Try again" if there is nothing
/// to show, and pull-down to refresh. The screen's content is built from the decoded answer.
struct LoaderScreen<T: Decodable, Content: View>: View {
    @StateObject private var loader: Loader<T>
    private let content: (T) -> Content

    init(api: APIClient, path: String, query: [String: String] = [:], @ViewBuilder content: @escaping (T) -> Content) {
        _loader = StateObject(wrappedValue: Loader(api: api, path: path, query: query))
        self.content = content
    }

    var body: some View {
        Group {
            switch loader.phase {
            case .loading:
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                LoadFailure(message: message) { Task { await loader.refresh() } }
            case .loaded(let value):
                ScrollView {
                    VStack(spacing: 14) {
                        StaleNote(message: loader.staleMessage)
                        content(value)
                    }
                    .padding(16)
                }
                .refreshable { await loader.refresh() }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await loader.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .ridesChanged)) { _ in
            Task { await loader.refresh() }
        }
    }
}
