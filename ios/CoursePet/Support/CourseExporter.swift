// MARK: - 课表导出（CSV → 文件 App）
// 为什么不用系统分享面板：iOS 26 上 UIActivityViewController / List 行内 ShareLink 都有闪退案例
// （见 BackupManager 同款说明），所以统一走"写进 Documents/Exports + 文件 App 自取"。
// 为什么是 CSV：Excel / Numbers / WPS 都能直接打开，也能整段发给同学；
// 带 UTF-8 BOM，Windows 版 Excel 打开不乱码。
import Foundation

enum CourseExporter {

    enum ExportError: LocalizedError {
        case empty
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "当前课表是空的，没有可导出的课程"
            case .writeFailed(let detail):
                return "写入失败：\(detail)"
            }
        }
    }

    /// 导出当前活动课表为 CSV，返回写入的文件地址
    @discardableResult
    static func exportCurrentTimetable() throws -> URL {
        let dm = DataManager.shared
        let courses = dm.courses.sorted {
            $0.dayOfWeek == $1.dayOfWeek ? $0.startTime < $1.startTime : $0.dayOfWeek < $1.dayOfWeek
        }
        guard !courses.isEmpty else { throw ExportError.empty }

        // BOM：Windows Excel 靠它判定 UTF-8，缺了中文列名会变乱码
        var csv = "\u{FEFF}课程名称,教师,地点,星期,开始时间,结束时间,开始周,结束周,单双周\n"
        let weekNames = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for c in courses {
            let day = (1...7).contains(c.dayOfWeek) ? weekNames[c.dayOfWeek] : "周\(c.dayOfWeek)"
            let parity: String
            switch c.weekParity {
            case .both: parity = "每周"
            case .single: parity = "单周"
            case .double: parity = "双周"
            }
            let fields = [c.name, c.teacher, c.location, day, c.startTime, c.endTime,
                          "\(c.startWeek)", "\(c.endWeek)", parity]
            csv += fields.map(csvEscape).joined(separator: ",") + "\n"
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName())
            try Data(csv.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// CSV 字段转义：含逗号/引号/换行时用双引号包裹，内部引号双写
    private static func csvEscape(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func fileName() -> String {
        let dm = DataManager.shared
        let table = dm.activeTimetableName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTable = table.isEmpty ? "课表" : table.replacingOccurrences(of: "/", with: "-")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "CoursePet-\(safeTable)-\(fmt.string(from: Date())).csv"
    }
}
