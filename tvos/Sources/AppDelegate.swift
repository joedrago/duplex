import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let webURL = info["WebViewURL"] as? String ?? "?"
        NSLog("[Duplex] ============================================================")
        NSLog("[Duplex] Duplex tvOS launched (v%@ build %@)", version, build)
        NSLog("[Duplex] WebViewURL=%@", webURL)
        NSLog("[Duplex] Device: %@ / %@ %@",
              UIDevice.current.model,
              UIDevice.current.systemName,
              UIDevice.current.systemVersion)
        NSLog("[Duplex] ============================================================")

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

    func applicationDidBecomeActive(_ application: UIApplication) {
        NSLog("[Duplex] lifecycle: applicationDidBecomeActive")
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NSLog("[Duplex] lifecycle: applicationWillResignActive")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NSLog("[Duplex] lifecycle: applicationDidEnterBackground")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        NSLog("[Duplex] lifecycle: applicationWillEnterForeground")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NSLog("[Duplex] lifecycle: applicationWillTerminate")
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        NSLog("[Duplex] WARN: applicationDidReceiveMemoryWarning")
    }
}
