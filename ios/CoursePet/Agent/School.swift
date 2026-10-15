// MARK: - 全国学校目录（MVP：先只塞新疆理工，扩目录 = 往 schools 数组加元素）
// 设计：目录内嵌 App（不打服务器，避免本次改动要重新部署后端）。
// 每所学校带 extractorJS —— WebView 登录进教务后，对「课表页」执行这段 JS 抽原始表格，
// 再由 mapRows 把原始行列映射成 Course。新学校 = 加一条 + 写对应 extractorJS/映射，
// 不必改别的代码（后续可整体迁移到后端 /schools 下发）。
import Foundation

struct School: Identifiable, Codable {
    let id: Int
    let name: String
    /// 教务认证类型：cas = Apereo CAS 统一认证（新疆理工即此）；后续可扩 oauth/portal 等
    let jiaowuType: String
    /// 教务系统根地址（WebView 加载它，未登录会自动跳 CAS）
    let loginBaseURL: String
    /// CAS 登录页（jiaowuType=cas 时展示/兜底用）
    let casLoginURL: String?
    /// 抽课表 JS（在课表页 document 上执行，返回 JSON {rows:[[cell,...],...]}）
    let extractorJS: String
}

enum SchoolCatalog {
    /// 当前目录（MVP 仅新疆理工）。扩全国 = 在此加元素 + 写各校 extractorJS。
    static let schools: [School] = [
        School(
            id: 1,
            name: "新疆理工学院",
            jiaowuType: "cas",
            loginBaseURL: "https://jw.xjit.edu.cn/",
            casLoginURL: "https://cas.xjit.edu.cn/cas/login",
            extractorJS: genericTableExtractor
        )
    ]

    static func school(byId id: Int) -> School? {
        schools.first { $0.id == id }
    }

    /// 通用兜底抽取器：选页面里单元格最多的 <table>，整表行列原样导出。
    /// 不假设任何厂商结构（正方/URP/强智都先靠它跑通），截图校准后换成各校专属 JS。
    static let genericTableExtractor = """
    (function(){
      var tables = Array.from(document.querySelectorAll('table'));
      var best = null, bestCells = 0;
      tables.forEach(function(t){
        var c = t.querySelectorAll('td,th').length;
        if (c > bestCells) { bestCells = c; best = t; }
      });
      if (!best) return JSON.stringify({rows:[]});
      var rows = Array.from(best.querySelectorAll('tr')).map(function(tr){
        return Array.from(tr.querySelectorAll('td,th')).map(function(td){
          return (td.innerText || td.textContent || '').replace(/\\s+/g, ' ').trim();
        });
      });
      return JSON.stringify({rows: rows});
    })()
    """

    /// 把抽取出的原始行列映射成 Course（MVP 启发式，截图校准后按学校细化）。
    /// 假设最大表是「周课表网格」：表头含 周一..周日 → 列号即星期；
    /// 每个非空单元格一行课程，单元格文本按行拆 课程名/教师/地点。
    /// 开始/结束时间先用节次默认值占位（用户在导入预览里逐课改），降低对未知作息的耦合。
    static func mapRows(_ rows: [[String]], school: School) -> [Course] {
        guard rows.count > 1 else { return [] }
        // 找表头行（含 周一..周日 / 星期 / Mon）
        var headerIdx = -1
        for (i, r) in rows.enumerated() {
            let joined = r.joined()
            if joined.contains("周一") || joined.contains("周二") || joined.contains("星期")
               || joined.contains("Mon") || joined.contains("周一") {
                headerIdx = i; break
            }
        }
        let dataRows = headerIdx >= 0 ? Array(rows[(headerIdx + 1)...]) : rows
        var courses: [Course] = []
        for (ri, row) in dataRows.enumerated() {
            for (ci, cell) in row.enumerated() where !cell.isEmpty {
                let day = ci + 1
                guard (1...7).contains(day) else { continue }
                let (name, teacher, loc) = parseCell(cell)
                guard !name.isEmpty else { continue }
                let (s, e) = periodTimes(ri)
                courses.append(Course(
                    name: name, teacher: teacher, location: loc,
                    dayOfWeek: day, startTime: s, endTime: e,
                    startWeek: 1, endWeek: 18, weekParity: .both,
                    color: CourseColorPalette.color(forDay: day)))
            }
        }
        return courses
    }

    /// 单元格文本拆 课程名 / 教师 / 地点（启发式；新疆理工截图校准后细化）
    private static func parseCell(_ cell: String) -> (name: String, teacher: String, location: String) {
        let lines = cell.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let name = lines.first, !name.isEmpty else { return ("", "", "") }
        var teacher = "", location = ""
        for line in lines.dropFirst() {
            if line.contains("室") || line.contains("楼") || line.contains("教") {
                location = line
            } else if line.contains("老师") || line.contains("教师") || line.contains("@") {
                teacher = line
            } else if location.isEmpty, line.count <= 12 {
                location = line   // 兜底：短行当地点
            }
        }
        return (name, teacher, location)
    }

    /// 节次 → 默认时间占位（用户导入预览里改）。5 节次循环兜底。
    private static let periodSchedule = [
        ("08:00", "09:40"), ("10:00", "11:40"), ("14:00", "15:40"),
        ("16:00", "17:40"), ("19:00", "20:40"), ("20:50", "22:30")
    ]
    private static func periodTimes(_ rowIndex: Int) -> (String, String) {
        let p = periodSchedule[rowIndex % periodSchedule.count]
        return p
    }
}
