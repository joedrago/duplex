import UIKit
import MediaPlayer

/// Hosts the Duplex web client in a private-API UIWebView and routes
/// Siri Remote presses to synthetic JavaScript KeyboardEvents on the
/// document — letting the web client handle navigation and playback
/// without us speaking media APIs directly.
class WebViewController: UIViewController {
    private var tvWebView: TVWebView!
    private var lastSeekTime: TimeInterval = 0
    private static let seekThrottleInterval: TimeInterval = 0.5

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [tvWebView]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.insetsLayoutMarginsFromSafeArea = false
        additionalSafeAreaInsets = .zero

        tvWebView = TVWebView(frame: view.bounds)
        tvWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tvWebView)

        let urlString = Bundle.main.infoDictionary?["WebViewURL"] as? String ?? "http://localhost:2345"
        if let url = URL(string: urlString) {
            tvWebView.load(url)
        }

        // Map the system play/pause control to a Space keystroke so the web
        // client's own keyboard handling (or the native <video> handlers)
        // controls playback consistently.
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.injectKeyEvent("keydown", key: " ")
            self?.injectKeyEvent("keyup", key: " ")
            return .success
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tvWebView.frame = view.bounds
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            // Menu reloads the page (back-to-browse behavior).
            if press.type == .menu {
                tvWebView.evaluateJavaScript("history.length > 1 ? history.back() : location.reload();")
                return
            }
            if let key = keyForPress(press) {
                if key == "ArrowLeft" || key == "ArrowRight" {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastSeekTime < Self.seekThrottleInterval {
                        return
                    }
                    lastSeekTime = now
                }
                injectKeyEvent("keydown", key: key)
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = keyForPress(press) {
                injectKeyEvent("keyup", key: key)
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    private func keyForPress(_ press: UIPress) -> String? {
        switch press.type {
        case .select:     return " "
        case .playPause:  return " "
        case .menu:       return nil
        case .upArrow:    return "ArrowUp"
        case .downArrow:  return "ArrowDown"
        case .leftArrow:  return "ArrowLeft"
        case .rightArrow: return "ArrowRight"
        @unknown default: return nil
        }
    }

    private func injectKeyEvent(_ type: String, key: String) {
        let js = """
            (function() {
                try {
                    var evt = new KeyboardEvent('\(type)', {key:'\(key)', bubbles:true});
                    var target = document.activeElement || document;
                    target.dispatchEvent(evt);
                    document.dispatchEvent(evt);
                } catch(e) {}
            })();
            """
        tvWebView.evaluateJavaScript(js)
    }
}
