import Aria
import AriaTesting

/// A small CLI that demonstrates Aria is wired up correctly. This is a
/// scaffolding placeholder; once the core types are implemented it will grow
/// into a useful demo (mock provider + scripted conversation + streaming
/// output). For now it confirms the package builds and runs.
@main
enum AriaCLI {
    static func main() async {
        print("Aria \(AriaInfo.version)")
        print("Composable on-device agent runtime for Apple platforms.")
        print("")
        print("AriaTesting version: \(AriaTesting.version)")
        print("")
        print("This is a scaffolding placeholder. Implementation is pending.")
        print("See docs/ for the architecture and design.")
    }
}
