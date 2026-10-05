// MARK: - 专注岛按钮命令日志（主 App ↔ 灵动岛扩展 跨进程对账）
// iOS 17 交互式 Live Activity 的按钮 Intent 运行在扩展进程，改不了 App 内
// FocusView 内存里的计时状态（baseSeconds/isPaused）。按钮在扩展里改完 Activity
// 后，把操作追加到这份共享命令日志（App Group UserDefaults），App 侧按 epoch
// 顺序重放对账。必须数组而非单槽：App 后台期间连续「暂停→继续→暂停」三条命令，
// 单槽会丢中间运行段（计时漏账）。
import Foundation

enum FocusIslandCommandLog {
    enum Action: String, Codable {
        case pause, resume, end
    }

    struct Command: Codable {
        var action: Action
        var epoch: Date          // 操作发生时刻（对账排序 + last-writer-wins 判定）
        var elapsed: Int         // 扩展进程算出的累计专注秒数（end 补发奖励用）
        var taskId: String
    }

    private static let key = "island.focusCmdLog"
    private static let capacity = 20

    private static func read() -> [Command] {
        guard let data = StorageLocation.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Command].self, from: data)) ?? []
    }

    private static func write(_ cmds: [Command]) {
        if let data = try? JSONEncoder().encode(cmds) {
            StorageLocation.defaults.set(data, forKey: key)
        }
    }

    /// 扩展进程（岛按钮 Intent）追加命令
    static func append(_ cmd: Command) {
        var cmds = read()
        cmds.append(cmd)
        if cmds.count > capacity {
            cmds.removeFirst(cmds.count - capacity)
        }
        write(cmds)
        LADebug.log("岛命令入队：\(cmd.action.rawValue) elapsed=\(cmd.elapsed)s")
    }

    /// App 侧：取 cutoff 之后未处理的命令（按 epoch 升序重放）
    static func pendingCommands(after cutoff: Date) -> [Command] {
        read().filter { $0.epoch > cutoff }.sorted { $0.epoch < $1.epoch }
    }

    /// App 侧：清理已对账的命令（每次对账后调用，防无限增长）
    static func prune(keepingAfter cutoff: Date) {
        let all = read()
        let kept = all.filter { $0.epoch > cutoff }
        if kept.count != all.count {
            write(kept)
        }
    }

    /// 冷启动：专注状态只存内存必然丢失，pause/resume 已无法对账（孤儿活动由
    /// cleanupOrphansOnLaunch 清理）；只取 end 命令用于补发奖励，日志整体清空
    static func takeEndCommandsOnLaunch() -> [Command] {
        let all = read()
        write([])
        return all.filter { $0.action == .end }
    }
}
