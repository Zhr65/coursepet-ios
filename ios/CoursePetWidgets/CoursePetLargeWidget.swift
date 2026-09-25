// MARK: - 大尺寸小组件（本周课表格子概览 + 宠物）
import SwiftUI
import WidgetKit

struct CoursePetLargeWidget: Widget {
    let kind: String = "CoursePetLarge"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoursePetTimelineProvider()) { entry in
            CoursePetLargeWidgetView(entry: entry)
                .widgetURL(URL(string: "coursepet://schedule"))   // 点击直达课表
        }
        .configurationDisplayName("本周课表")
        .description("显示本周课表格子概览和宠物")
        .supportedFamilies([.systemLarge])
    }
}

struct CoursePetLargeWidgetView: View {
    var entry: CoursePetEntry

    private let days = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 8) {
            // 顶部：宠物 + 本周标题
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 44, height: 44)
                    PetAnimationView(
                        action: entry.petAction,
                        charId: entry.charId,
                        speed: entry.animSpeed,
                        size: 36,
                        loop: true
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("本周课表")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    if let next = entry.nextCourse {
                        Text("下节：\(next.name) · \(entry.countdownText)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            // 周表格子
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(days.indices, id: \.self) { dayIndex in
                    VStack(spacing: 4) {
                        // 星期标题
                        Text("周\(days[dayIndex])")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(dayIndex == 4 ? .indigo : .secondary)
                            .frame(maxWidth: .infinity)

                        // 当天课程
                        if dayIndex < entry.weekCourses.count {
                            let dayCourses = entry.weekCourses[dayIndex]
                            ForEach(dayCourses.prefix(3), id: \.id) { course in
                                dayCourseCell(course)
                            }
                            if dayCourses.count > 3 {
                                Text("+\(dayCourses.count - 3) more")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }

    private func dayCourseCell(_ course: Course) -> some View {
        let color = Color(hex: course.color) ?? Color.orange
        return VStack(alignment: .leading, spacing: 1) {
            Text(course.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
            Text(course.startTime)
                .font(.system(size: 8))
                .foregroundColor(color.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.25))
        .cornerRadius(3)
    }
}

struct CoursePetLargeWidgetEntryView: View {
    var entry: CoursePetEntry

    var body: some View {
        CoursePetLargeWidgetView(entry: entry)
    }
}
