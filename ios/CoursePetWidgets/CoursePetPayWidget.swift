// MARK: - 付款码小组件（锁屏 accessoryCircular：点一下直达支付宝/微信付款码）
// 与扫一扫组件并列放在锁屏，形成「扫码 + 付款码」一键直达区。
//
// 跳转链路（2026-11-01 修）：小组件**不直接** open 第三方 App，而是发
// coursepet://pay?app=… 回到主 App，由主 App 的 QuickPayLauncher 唤起。
// 根因：widgetURL 的打开动作跑在小组件扩展进程，该进程调 openURL 会丢掉
// URL 的 path/query —— 直接写 alipays://…?appId=20000056 的结果是「支付宝打开了，
// 但停在首页」，用户还得自己点一次付款码。中转一层即可绕开这个限制。
import SwiftUI
import WidgetKit

// 支付宝付款码
struct CoursePetAlipayPayWidget: Widget {
    let kind: String = "CoursePetAlipayPay"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { _ in
            PayWidgetIconView(
                color: Color(red: 0.086, green: 0.466, blue: 1.0), // 支付宝蓝 #1677FF
                systemImage: "barcode.viewfinder"
            )
            .widgetURL(URL(string: "coursepet://pay?app=alipay"))
            .widgetBackground(Color.clear)
        }
        .configurationDisplayName("支付宝付款码")
        .description("锁屏一键打开支付宝付款码")
        .supportedFamilies([.accessoryCircular])
    }
}

// 微信付款码
struct CoursePetWechatPayWidget: Widget {
    let kind: String = "CoursePetWechatPay"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { _ in
            PayWidgetIconView(
                color: Color(red: 0.027, green: 0.757, blue: 0.376), // 微信绿 #07C160
                systemImage: "barcode"
            )
            .widgetURL(URL(string: "coursepet://pay?app=wechat"))
            .widgetBackground(Color.clear)
        }
        .configurationDisplayName("微信付款码")
        .description("锁屏一键打开微信付款码")
        .supportedFamilies([.accessoryCircular])
    }
}

// 共享图标：圆底 + 居中条码图标
struct PayWidgetIconView: View {
    let color: Color
    let systemImage: String

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
        }
    }
}
