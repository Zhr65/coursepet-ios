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

                // 右侧：倒数（课前→上课时刻；上课中→下课时刻），timerInterval 倒数 API 系统驱动
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.isClassStarted ? "距离下课" : "距离上课")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Group {
                        if state.isClassStarted {
                            Text(timerInterval: Date()...max(Date(), state.courseEndTime), countsDown: true)
                        } else {
                            Text(timerInterval: Date()...max(Date(), state.courseStartTime), countsDown: true)
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

            // 宠物语录：由 Activity 数据确定性生成（Agent 口吻，让宠物"说话"而不只是计时器）
            Text("🐾 \(petQuote)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
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

    /// 宠物语录：按课程阶段与教室数据组句，用课程开始时间做种子确定性选句——
    /// 同一节课固定一句（避免系统重渲染时句子突变），不同课程/阶段各不同
    private var petQuote: String {
        let name = state.courseName
        let place = state.location
        let pool: [String]
        if state.isClassStarted {
            pool = [
                "\(name)进行中，认真听，下课见",
                "我在岛里陪你上\(name)，加油",
                "快了快了，撑到下课就能休息",
            ]
        } else if place.isEmpty {
            pool = [
                "马上要上\(name)了，收拾一下出发",
                "\(name)要开始了，别迟到哦",
                "深呼吸，\(name)没那么可怕",
            ]
        } else {
            pool = [
                "\(name)在\(place)，提前出发不慌",
                "目的地\(place)，别走错教室",
                "\(place)见！我在这节课等你",
            ]
        }
        let seed = abs(Int(state.courseStartTime.timeIntervalSince1970) % pool.count)
        return pool[seed]
    }
}
