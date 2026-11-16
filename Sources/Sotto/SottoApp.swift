import SwiftUI

@main
struct SottoApp: App {
    var body: some Scene {
        Window("Sotto", id: "main") {
            Text("Sotto")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}
