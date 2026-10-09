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

    // MARK: - 悬浮条 UI（灵动岛同款黑胶囊）
    // 纯玻璃胶囊悬浮在页面玻璃卡片上时，卡片边缘会从胶囊四周透出来，
    // 被误读成"胶囊外面还套了个框"（2026-10-09 反馈）；垫一层深色实底 +
    // 固定亮色文字 + 胶囊形投影后，浮层轮廓分明，任何页面上都不会混淆。
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
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    // 最底层深色实底：把底下页面内容的亮边压住（投影也挂这层，轮廓就是胶囊形）
                    Capsule().fill(Color.black.opacity(0.55))
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                    // 玻璃层保留：仍跟随设置 → 外观 → 玻璃质感的四档联动
                    GlassSurface(cornerRadius: 20, capsule: true)
                        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                }
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: title)
    }
}
