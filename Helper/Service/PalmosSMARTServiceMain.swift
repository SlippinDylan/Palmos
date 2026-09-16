import Foundation

@main
struct PalmosSMARTServiceMain {
    static func main() {
        let listener = NSXPCListener(
            machServiceName: Bundle.main.bundleIdentifier ?? "com.palmos.smartservice"
        )
        let delegate = PalmosSMARTXPCDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
