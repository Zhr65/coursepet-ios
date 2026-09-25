// MARK: - 中尺寸小组件（今日课程列表 + 宠物）
import SwiftUI
import WidgetKit

struct CoursePetMediumWidget: Widget {
    let kind: String = "CoursePetMedium"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { entry in
            CoursePetMediumWidgetView(entry: entry)
                .widgetURL(URL(string: "coursepet://schedule"))   // 点击直达课表
        }
        .configurationDisplayName("今日课程")
        .description("显示今日完整课程列表和宠物状态")
        .supportedFamilies([.systemMedium])
    }
}

struct CoursePetMediumWidgetView: View {
    var entry: CoursePetEntry

    var body: some View {
        VStack(spacing: 12) {
            // 顶部：宠物 + 倒计时
            HStack(spacing: 12) {
                // 宠物
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 56, height: 56)
                    PetAnimationView(
                        action: entry.petAction,
                        charId: entry.charId,
                        speed: entry.animSpeed,
                        size: 48,
                        loop: true
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let next = entry.nextCourse {
                        Text(next.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(next.startTime + " · " + next.location)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Text(entry.countdownText)
                        .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        .foregroundColor(.orange)
                }
                Spacer()
            }

            Divider()

            // 今日课程列表
            if !entry.todayCourses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entry.todayCourses) { course in
                            courseChip(course, isCurrent: entry.currentCourse?.id == course.id)
                        }
                    }
                }
            } else {
                Text("今日无课程")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }

    private func courseChip(_ course: Course, isCurrent: Bool) -> some View {
        let color = Color(hex: course.color) ?? Color.orange
        return VStack(alignment: .leading, spacing: 2) {
            Text(course.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
            Text(course.location)
                .font(.system(size: 9))
                .foregroundColor(color.opacity(0.7))
                .lineLimit(1)
            Text(course.startTime)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(isCurrent ? 0.4 : 0.2))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(isCurrent ? 0.8 : 0.3), lineWidth: 1)
        )
    }
}

struct CoursePetMediumWidgetEntryView: View {
    var entry: CoursePetEntry

    var body: some View {
        CoursePetMediumWidgetView(entry: entry)
    }
}
