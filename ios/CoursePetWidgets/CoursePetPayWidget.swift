// MARK: - 付款码小组件（锁屏 accessoryCircular：点一下直达支付宝/微信付款码）
// 与扫一扫组件并列放在锁屏，形成「扫码 + 付款码」一键直达区。
// 用 widgetURL 直接深链到对应 App 的付款码页，不经本 App 中转（少一次跳转、被杀后台也更稳）。
// scheme 复用 TransactionSections.swift 的「快捷收付款」已验证值：
//   支付宝付款 alipays://platformapi/startapp?appId=20000056
//   微信付款   weixin://widget/pay
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
            .widgetURL(URL(string: "alipays://platformapi/startapp?appId=20000056"))
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
            .widgetURL(URL(string: "weixin://widget/pay"))
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
