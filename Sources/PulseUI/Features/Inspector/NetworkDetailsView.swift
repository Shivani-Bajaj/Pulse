// The MIT License (MIT)
//
// Copyright (c) 2020–2022 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Pulse

struct NetworkDetailsView: View {
    // TODO: Fix liofecycle on iOS 14+
    private let viewModel: NetworkDetailsViewModel
    private var title: String
    @State private var isShowingShareSheet = false

    init(viewModel: KeyValueSectionViewModel) {
        self.title = viewModel.title
        self.viewModel = NetworkDetailsViewModel { viewModel.asAttributedString() }
    }

    init(title: String, text: @autoclosure @escaping () -> NSAttributedString) {
        self.title = title
        self.viewModel = NetworkDetailsViewModel(text)
    }

    func title(_ title: String) -> NetworkDetailsView {
        var copy = self
        copy.title = title
        return copy
    }

    #if os(iOS)
    var body: some View {
        contents
            .navigationBarTitle(title)
    }
    #else
    var body: some View {
        contents
    }
    #endif

    @ViewBuilder
    private var contents: some View {
        if viewModel.text.text.length == 0 {
            PlaceholderView(imageName: "folder", title: "Empty")
        } else {
            RichTextView(viewModel: viewModel.text)
        }
    }
}

final class NetworkDetailsViewModel {
    private(set) lazy var text = RichTextViewModel(string: makeString())
    private let makeString: () -> NSAttributedString

    init(_ closure: @escaping () -> NSAttributedString) {
        self.makeString = closure
    }
}

#if DEBUG
struct NetworkDetailsView_Previews: PreviewProvider {
    static var previews: some View {
#if !os(watchOS)
        NavigationView {
            NetworkDetailsView(title: "JWT", text: KeyValueSectionViewModel.makeDetails(for: jwt))
        }
                .previewDisplayName("JWT")
#endif
    }
}

private let jwt = try! JWT("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
#endif
