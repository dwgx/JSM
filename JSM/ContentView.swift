import SwiftUI

struct ContentView: View {
    var body: some View {
        MainWindow()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
