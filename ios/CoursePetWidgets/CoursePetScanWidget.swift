// MARK: - 扫一扫小组件（锁屏 accessory：锁屏点一下直达扫码器，复刻「一扫」）
// 点击 → widgetURL coursepet://scan → App 冷/热启动都进扫码全屏页。
// accessoryCircular iOS 16 起整体可点且尊重 widgetURL，无需 AppIntent。
import SwiftUI
import WidgetKit

struct CoursePetScanWidget: Widget {
    let kind: String = "CoursePetScan"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { _ in
            ScanWidgetIconView()
                .widgetURL(URL(string: "coursepet://scan"))
                .widgetBackground(Color.clear)
        }
        .configurationDisplayName("扫一扫")
        .description("锁屏一键打开扫码器：二维码/快递条码直达目标应用")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ScanWidgetIconView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.orange, Color(red: 0.98, green: 0.55, blue: 0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
        }
    }
}
