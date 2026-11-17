import UIKit
import WebKit

/// 单页外壳：WKWebView 载入本机 127.0.0.1 上的网页（资源全部打包在 App 内）
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var retried = false

    /// 只在「视频真的在播放」时禁止锁屏；暂停/播完/退出播放器立刻恢复系统自动锁屏。
    private let idleHook = """
    (function () {
      if (window.__ljIdleHooked) return;
      window.__ljIdleHooked = true;
      function post(on) {
        try { window.webkit.messageHandlers.lanjue.postMessage({ t: 'idle', on: !!on }); } catch (e) {}
      }
      function isVid(el) { return el && el.tagName === 'VIDEO'; }
      document.addEventListener('play',  function (e) { if (isVid(e.target)) post(true);  }, true);
      document.addEventListener('playing', function (e) { if (isVid(e.target)) post(true); }, true);
      document.addEventListener('pause', function (e) { if (isVid(e.target)) post(false); }, true);
      document.addEventListener('ended', function (e) { if (isVid(e.target)) post(false); }, true);
      document.addEventListener('webkitendfullscreen', function (e) {
        if (isVid(e.target)) post(!e.target.paused);
      }, true);
      window.addEventListener('pagehide', function () { post(false); });
    })();
    """

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 7.0 / 255.0, green: 9.0 / 255.0, blue: 18.0 / 255.0, alpha: 1)

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(iOS 14.0, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        // 视频播放状态 → 原生（决定是否禁止锁屏）
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: idleHook,
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false))
        uc.add(self, name: "lanjue")
        cfg.userContentController = uc

        // 切到后台：让页面立刻停视频、停 HLS 下载、停解码，别在后台偷跑
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(appDidBackground),
                                              name: UIApplication.didEnterBackgroundNotification,
                                              object: nil)

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            webView.isInspectable = true      // 方便真机调试
        }
        view.addSubview(webView)

        loadLocal()
    }

    private func loadLocal() {
        let port = LocalHTTPServer.shared.start()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/index.html") else {
            fail("本机服务启动失败，请重装 App 再试")
            return
        }
        NSLog("[app] loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryOnce()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryOnce()
    }

    private func retryOnce() {
        guard !retried else { return }
        retried = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.loadLocal()
        }
    }

    // 站内跳转一律留在 App 内，别弹 Safari；外链 http(s) 也留在 WebView（片源解析会跳分享页）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // tel: / mailto: / 自定义 scheme 交给系统前先拦下，避免白屏
        decisionHandler(.cancel)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    // MARK: - 省电相关

    /// 页面通过 postMessage 告知视频播放状态
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "lanjue",
              let body = message.body as? [String: Any],
              (body["t"] as? String) == "idle" else { return }
        let playing = body["on"] as? Bool ?? false
        UIApplication.shared.isIdleTimerDisabled = playing
    }

    @objc private func appDidBackground() {
        // 页面里已经写好的钩子：暂停视频、hls.stopLoad、关掉常亮
        webView?.evaluateJavaScript("window.__onAppPause && window.__onAppPause()",
                                    completionHandler: nil)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lanjue")
    }

    private func fail(_ msg: String) {
        let lb = UILabel()
        lb.text = msg
        lb.numberOfLines = 0
        lb.textAlignment = .center
        lb.textColor = .white
        lb.frame = view.bounds
        lb.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(lb)
    }
}
