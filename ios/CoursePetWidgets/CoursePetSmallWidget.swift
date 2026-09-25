// MARK: - 小尺寸小组件（下一节课 + 宠物）
import SwiftUI
import WidgetKit

struct CoursePetSmallWidget: Widget {
    let kind: String = "CoursePetSmall"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { entry in
            CoursePetSmallWidgetView(entry: entry)
                .widgetURL(URL(string: "coursepet://schedule"))   // 点击直达课表
        }
        .configurationDisplayName("下一节课")
        .description("显示下一节课信息和宠物状态")
        .supportedFamilies([.systemSmall])
    }
}

struct CoursePetSmallWidgetView: View {
    var entry: CoursePetEntry

    var body: some View {
        VStack(spacing: 8) {
            // 宠物区
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 60, height: 60)
                PetAnimationView(
                    action: entry.petAction,
                    charId: entry.charId,
                    speed: entry.animSpeed,
                    size: 50,
                    loop: true
                )
            }

            Divider()

            // 下一节课信息
            if let course = entry.nextCourse {
                VStack(spacing: 4) {
                    Text(course.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(course.startTime + " · " + course.location)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(entry.countdownText)
                        .font(.system(size: 16, weight: .heavy, design: .monospaced))
                        .foregroundColor(.orange)
                }
            } else if let current = entry.currentCourse {
                VStack(spacing: 4) {
                    Text(current.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("上课中")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            } else {
                Text("今日无课")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .widgetBackground(Color.clear)
    }
}

struct CoursePetSmallWidgetEntryView: View {
    var entry: CoursePetEntry

    var body: some View {
        CoursePetSmallWidgetView(entry: entry)
    }
}
