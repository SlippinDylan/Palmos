import Foundation

@main
struct DrivePulseSMARTServiceMain {
    static func main() {
        let listener = NSXPCListener(
            machServiceName: Bundle.main.bundleIdentifier ?? "com.drivepulse.smartservice"
        )
        let delegate = DrivePulseSMARTXPCDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
