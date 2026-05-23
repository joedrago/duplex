import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[Duplex] UNCAUGHT EXCEPTION: %@", exception)
            NSLog("[Duplex] Stack: %@", exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig: Int32 in [SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGBUS] {
            signal(sig) { s in
                NSLog("[Duplex] SIGNAL %d received", s)
                Thread.callStackSymbols.forEach { NSLog("[Duplex] %@", $0) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
