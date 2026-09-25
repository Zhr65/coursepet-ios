// MARK: - 灵动岛 Live Activity 视图（紧凑模式 + 展开模式）
import SwiftUI
import ActivityKit

struct CoursePetLiveActivityView: View {
    var attributes: CourseActivityAttributes
    var state: CourseActivityAttributes.ContentState

    var body: some View {
        // 灵动岛自动管理紧凑/展开模式，无需手动判断
        // 紧凑模式下 VStack 内容会自动压缩
        HStack(spacing: 12) {
            // 左侧：宠物动画
            PetAnimationView(
                action: state.petAction,
                charId: "char1",
                speed: .mid,
                size: 36,
                loop: true,
                liveActivityMode: true
            )
            .frame(width: 36, height: 36)

            // 右侧：课程信息
            VStack(alignment: .leading, spacing: 2) {
                Text(state.courseName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(state.location)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 倒计时（使用系统 timerInterval 驱动，系统自动刷新）
            if let courseStart = state.courseStartTime {
                Text(state.countdownText)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
