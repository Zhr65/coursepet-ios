// MARK: - 灵动岛诊断日志
// 无 Mac 环境看不到系统控制台，把 Live Activity 启动链路的关键状态写入
// UserDefaults，由设置页的「灵动岛诊断」面板展示，用于远程定位上岛失败原因。
// 三 target 共编：主 App 进程记录启动过程；扩展进程不会写入，无副作用。
import Foundation

enum LADebug {
    private static let key = "coursepet_la_debug"
    private static let maxLines = 10

    /// 追加一条诊断日志（带时间戳，保留最近 maxLines 条）
    static func log(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(message)"
        var all = UserDefaults.standard.string(forKey: key)?
            .split(separator: "\n").map(String.init) ?? []
        all.append(line)
        if all.count > maxLines {
            all = Array(all.suffix(maxLines))
        }
        UserDefaults.standard.set(all.joined(separator: "\n"), forKey: key)
        #if DEBUG
        print("[LA]", line)
        #endif
    }

    /// 当前完整日志文本（诊断面板展示用）
    static func text() -> String {
        UserDefaults.standard.string(forKey: key) ?? "（暂无日志）"
    }

    /// 清空日志
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
