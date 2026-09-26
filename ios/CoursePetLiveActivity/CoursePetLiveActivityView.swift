// MARK: - 灵动岛 Live Activity 视图（锁屏横幅 + 长按展开区共用）
import SwiftUI
import ActivityKit

struct CoursePetLiveActivityView: View {
    var attributes: CourseActivityAttributes
    var state: CourseActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // 左侧：宠物真形象（扩展专用极简组件：低内存单帧，零重副作用）
                LiveActivitySafePet(
                    action: state.petAction,
                    charId: state.charId,
                    size: 40
                )

                // 中间：课程信息 + 状态
                VStack(alignment: .leading, spacing: 3) {
                    // 状态行：上课中 / 即将上课
                    Text(state.isClassStarted ? "上课中 · 加油" : "快收拾一下，准备出发")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(state.isClassStarted ? .green : .orange)
                    Text(state.courseName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !state.location.isEmpty {
                        Text("📍 \(state.location)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // 右侧：倒数（课前→上课时刻；上课中→下课时刻），系统驱动实时跳动
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.isClassStarted ? "距离下课" : "距离上课")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Group {
                        if state.isClassStarted {
                            Text(state.courseEndTime, style: .timer)
                        } else {
                            Text(state.courseStartTime, style: .timer)
                        }
                    }
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .frame(maxWidth: 88)
                }
            }

            // 上课进度条：上课中显示进度（周期更新刷新），课前显示空槽预告
            ProgressView(value: classProgress)
                .progressViewStyle(.linear)
                .tint(state.isClassStarted ? .green : .orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 上课进度 0...1（课前为 0；防除零与越界）
    private var classProgress: Double {
        let total = state.courseEndTime.timeIntervalSince(state.courseStartTime)
        guard total > 0 else { return state.isClassStarted ? 1 : 0 }
        let elapsed = Date().timeIntervalSince(state.courseStartTime)
        return min(1, max(0, elapsed / total))
    }
}
