import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = UIColor(red: 7.0 / 255.0, green: 9.0 / 255.0, blue: 18.0 / 255.0, alpha: 1)
        w.rootViewController = WebViewController()
        w.makeKeyAndVisible()
        window = w

        // 注意：这里不再全局禁锁屏。防锁屏只在「视频真正在播」时由 WebViewController 打开，
        // 否则 App 停在前台不动时屏幕会一直亮着，白耗电。
        return true
    }
}
