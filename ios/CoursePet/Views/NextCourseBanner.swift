// MARK: - 全局"下节课"悬浮条
// 任意页面底部悬浮显示：正在上课 / 课前 15 分钟内即将上课。
// 点击跳转课表页。数据为空或无临近课程时自动隐藏。
import SwiftUI

struct NextCourseBanner: View {
    @EnvironmentObject var dataManager: DataManager
    /// 点击后切换到的 tab index（由父视图注入）
    var onTap: () -> Void

    // 每秒心跳（倒计时刷新）
    @State private var tick: Date = Date()

    // ── 展示模型 ──
    private enum BannerState {
        case hidden
        case inClass(Course, String)          // 课程，教室
        case upcoming(Course, String, Int)    // 课程，教室，距开始分钟
    }

    private var state: BannerState {
        guard !dataManager.courses.isEmpty,
              let week = WeekMath.currentWeekNumber(startDateStr: dataManager.semesterStartDate) else { return .hidden }
        let weekCourses = ScheduleHelpers.courses(forWeek: week, courses: dataManager.courses)
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: tick)
        if let current = result.current {
            return .inClass(current, current.location)
        }
        if let next = result.next {
            let minutes = Int(next.startDate.timeIntervalSince(tick) / 60)
            // 提前 15 分钟展示（超过 15 分钟不悬浮，避免常驻打扰）
            if minutes > 0 && minutes <= 15 {
                return .upcoming(next.course, next.course.location, minutes)
            }
        }
        return .hidden
    }

    var body: some View {
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .inClass(let course, let location):
                banner(icon: "figure.run", tint: .green,
                       title: "正在上《\(course.name)》",
                       subtitle: location.isEmpty ? "上课中 · 加油" : "📍 \(location)") {
                    onTap()
                }
            case .upcoming(let course, let location, let minutes):
                banner(icon: "clock.badge.exclamationmark", tint: .orange,
                       title: "《\(course.name)》\(minutes) 分钟后上课",
                       subtitle: location.isEmpty ? "快收拾一下出发吧" : "📍 \(location)") {
                    onTap()
                }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { t in
            tick = t
        }
    }

    // MARK: - 悬浮条 UI（液态玻璃胶囊）
    private func banner(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: title)
    }
}
