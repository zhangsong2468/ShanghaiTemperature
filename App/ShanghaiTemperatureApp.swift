import SwiftUI

@main
struct ShanghaiTemperatureApp: App {
    var body: some Scene {
        WindowGroup("上海温度") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}
