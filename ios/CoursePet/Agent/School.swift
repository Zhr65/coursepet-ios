// MARK: - 全国学校目录（MVP：先只塞新疆理工，扩目录 = 往 schools 数组加元素）
// 设计：目录内嵌 App（不打服务器，避免本次改动要重新部署后端）。
// 每所学校带 extractorJS —— WebView 登录进教务后，对「课表页」执行这段 JS 抽课程，
// 再由 mapCourses 映射成 Course（节次→具体时间用默认作息表占位，用户在导入预览里逐课改）。
// 新学校 = 加一条 + 写对应 extractorJS（JS 侧按该校课表页结构解析成统一课程字段），
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
    /// 课表页地址。登录成功后 WebView 自动跳这里再抽课表；nil = 用户自己导航。
    /// 新疆理工实测（2026-10-15）：jw.xjit.edu.cn/jsxsd/xskb/xskb_list.do，
    /// 金智 jsxsd 系，服务端渲染 HTML（非 JSON），学年学期默认当前学期。
    let courseListURL: String?
    /// 抽课表 JS（在课表页 document 上执行，返回 JSON {courses:[…]}）
    let extractorJS: String
}

/// extractorJS 返回的单条原始课程（JS 侧已把网页结构解析成字段，Swift 只管映射）
struct RawCourse: Decodable {
    let name: String
    let teacher: String
    let location: String
    let day: Int              // 1=周一 … 7=周日
    let startWeek: Int
    let endWeek: Int
    /// both / single(单周) / double(双周)，对应 WeekParity
    let parity: String
    let startPeriod: Int      // 节次号，如 01-02节 → 1
    let endPeriod: Int

    enum CodingKeys: String, CodingKey {
        case name, teacher, location, day, startWeek, endWeek, parity, startPeriod, endPeriod
    }

    // 手写 init：JS 可能缺 teacher/location/parity，缺省给空值而不是整包解析失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        teacher = try c.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        day = try c.decode(Int.self, forKey: .day)
        startWeek = try c.decode(Int.self, forKey: .startWeek)
        endWeek = try c.decode(Int.self, forKey: .endWeek)
        parity = try c.decodeIfPresent(String.self, forKey: .parity) ?? "both"
        startPeriod = try c.decode(Int.self, forKey: .startPeriod)
        endPeriod = try c.decode(Int.self, forKey: .endPeriod)
    }
}

struct ExtractResult: Decodable {
    let courses: [RawCourse]
    /// 页面结构诊断（JS 侧总能给出）：抽取失败时弹窗展示这些数字，
    /// 用户截图/复制发回即可精确定位是「不在课表页」「表未渲染完」还是「结构没认出来」。
    struct Diag: Decodable {
        let tables: Int?       // 页面里 <table> 总数
        let header: Bool?      // 是否找到「星期一…星期日」网格表头
        let sections: Int?     // 识别出的节次行数
        let week: Int?         // 页面周次下拉当前值（单双周两段式提取的上下文；null=没切周次/全周视图）
        let cas: Bool?         // 是否 CAS 登录页（未登录拦截判据）
    }
    let diag: Diag?
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
            courseListURL: "https://jw.xjit.edu.cn/jsxsd/xskb/xskb_list.do",
            extractorJS: xjitExtractor
        )
    ]

    static func school(byId id: Int) -> School? {
        schools.first { $0.id == id }
    }

    /// 新疆理工（金智 jsxsd 系）课表页抽取器 v2（2026-10-17）。
    /// v1 真机实测（2026-10-16）登录自动跳到课表页仍抽到 0 门课，v2 针对性加固：
    ///   1. 顶层 document 找不到网格表时递归 iframe/frame（金智部分入口把课表嵌在框架页里）
    ///   2. 节次行不再要求整行精确等于「第N大节」：行内含「第N节/第N大节/第a-b节」都认
    ///      （v1 遇到「第一大节 08:00-09:40」这类带时间的行标签会整列跳过 → 全表 0 门）
    ///   3. 全角括号统一转半角再匹配周次/节次
    ///   4. 返回 diag 诊断（表格数/表头/节次行数/周次/CAS），失败弹窗直接展示，可远程定位
    ///   5. 读取页面周次下拉当前值：非空时把本次全部课程 parity 强制标为该周奇偶
    ///      （单双周两段式提取：用户切到单周提一次、双周提一次，App 侧 mergeCourses 合并）
    ///   6. 检测 CAS 登录表单（fm1/casLoginForm/密码框+验证码文案），未登录时给专用提示
    /// 页面结构基线（2026-10-15 校准）：
    ///   - 网格表：表头行 = 空 + 星期一..星期日；数据行首列 = 「第N大节」
    ///   - 单元格内每门课几行文本：课程名 / 教师? / "1-16周(01-02节)" / "上课地点【教室】"
    ///   - 一格多课并排，按「名称→教师?→周次行→地点行」状态机切块
    ///   - 周次写法两种："1-16周" 与 "2,4,6,8,10,12,14,16周"（→ 双周）
    /// 返回 {courses:[{name,teacher,location,day,startWeek,endWeek,parity,startPeriod,endPeriod}], diag:{…}}
    static let xjitExtractor = #"""
    (function(){
      var CN_NUM = {'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9};
      var CN_DAY = {'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'日':7};
      function cnNum(s){
        if (!s) return null;
        if (/^\d+$/.test(s)) return parseInt(s, 10);
        if (s === '十') return 10;
        if (s.length === 1) return CN_NUM[s] || null;
        if (s.indexOf('十') === 0) return 10 + (CN_NUM[s[1]] || 0);
        if (s.indexOf('十') === 1) return (CN_NUM[s[0]] || 0) * 10;
        if (s.indexOf('十') === 2) return (CN_NUM[s[0]] || 0) * 10 + (CN_NUM[s[2]] || 0);
        return null;
      }
      // 全角括号转半角：周次/节次行两种写法都见过
      function clean(s){ return (s || '').replace(/\s+/g, ' ').replace(/（/g, '(').replace(/）/g, ')').trim(); }
      function isWeek(line){ return /\d[\d,\-]*\s*周/.test(line); }
      // 地点行特征：金智教室一律带【】；个别只写 "xx楼xx室"
      function looksLikeLocation(line){
        return line.indexOf('【') >= 0 || /(室|楼|馆|场|校区|园区)/.test(line);
      }
      // 把单元格 DOM 拍平成文本行：<br> 与块级子元素都算换行（金智一格多课两种排法都见过）
      function cellLines(cell){
        var lines = [], cur = '';
        (function walk(node){
          for (var n = node.firstChild; n; n = n.nextSibling) {
            if (n.nodeType === 3) { cur += n.textContent; continue; }
            if (n.nodeType !== 1) continue;
            if (n.tagName === 'BR') { lines.push(cur); cur = ''; continue; }
            var isBlock = (n.tagName === 'DIV' || n.tagName === 'P' || n.tagName === 'LI');
            if (isBlock && cur.trim()) { lines.push(cur); cur = ''; }
            walk(n);
            if (isBlock && cur.trim()) { lines.push(cur); cur = ''; }
          }
        })(cell);
        if (cur.trim()) lines.push(cur);
        return lines.map(clean).filter(function(s){ return s.length > 0; });
      }
      // 单元格文本行 → 课程块 [{name, teacher, weekline, loc[]}]
      // 状态机：名称 → (教师：下一行即周次行时才存在) → 周次行 → 地点行(可多行)
      function parseBlocks(lines){
        var blocks = [];
        var i = 0;
        while (i < lines.length) {
          var name = lines[i];
          var j = i + 1;
          var teacher = '';
          if (j + 1 < lines.length && !isWeek(lines[j]) && isWeek(lines[j + 1])) {
            teacher = lines[j]; j += 1;
          }
          if (j >= lines.length || !isWeek(lines[j])) { i += 1; continue; }
          var weekline = lines[j];
          j += 1;
          var loc = [];
          while (j < lines.length && looksLikeLocation(lines[j])) { loc.push(lines[j]); j += 1; }
          if (name && !isWeek(name)) {
            blocks.push({ name: name, teacher: teacher, weekline: weekline, loc: loc });
          }
          i = j;
        }
        return blocks;
      }
      // 按 colspan/rowspan 建网格：备注行跨列、空单元格被 HTML 省略时列号都不错位
      function buildGrid(table){
        var grid = [];
        Array.from(table.querySelectorAll('tr')).forEach(function(tr, r){
          var col = 0;
          Array.from(tr.querySelectorAll('td,th')).forEach(function(cell){
            var rs = parseInt(cell.getAttribute('rowspan') || '1', 10) || 1;
            var cs = parseInt(cell.getAttribute('colspan') || '1', 10) || 1;
            while (grid[r] && grid[r][col]) col++;
            for (var dr = 0; dr < rs; dr++)
              for (var dc = 0; dc < cs; dc++){
                if (!grid[r + dr]) grid[r + dr] = [];
                grid[r + dr][col + dc] = cell;
              }
            col += cs;
          });
        });
        return grid;
      }
      // 「第a-b节」直接给区间；「第N大节」→ 2N-1,2N 节；「第N节」→ N 节
      function sectionPeriods(section){
        var s = section || '';
        var r = s.match(/第(\d+)\s*-\s*(\d+)节/);
        if (r) return [parseInt(r[1], 10), parseInt(r[2], 10)];
        var m = s.match(/第([一二三四五六七八九十\d]+)大?节/);
        if (!m) return null;
        var n = cnNum(m[1]);
        if (!n) return null;
        return s.indexOf('大节') >= 0 ? [2 * n - 1, 2 * n] : [n, n];
      }
      // CAS 登录页检测：Apereo CAS 标准表单 id，兜底「密码框 + 验证码文案」
      function isCasDoc(doc){
        if (doc.getElementById('fm1') || doc.getElementById('casLoginForm')) return true;
        var pwd = doc.querySelector('input[type="password"]');
        if (pwd) {
          var t = (doc.body && doc.body.innerText) || '';
          if (t.indexOf('验证码') >= 0) return true;
        }
        return false;
      }
      // 周次下拉当前值：找 options 里含「第N周」的下拉，取选中项数字；全周视图返回 null
      function weekContextOf(doc){
        var sels = doc.querySelectorAll('select');
        for (var i = 0; i < sels.length; i++) {
          var sel = sels[i];
          if (!sel.options || sel.options.length < 2) continue;
          var hasWeek = false;
          for (var j = 0; j < sel.options.length; j++) {
            if (/^第\d+周$/.test((sel.options[j].text || '').replace(/\s/g, ''))) { hasWeek = true; break; }
          }
          if (!hasWeek) continue;
          var cur = sel.options[sel.selectedIndex];
          if (!cur) continue;
          var m = (cur.text || '').replace(/\s/g, '').match(/(\d+)/);
          if (m) return parseInt(m[1], 10);
        }
        return null;
      }
      function scanDoc(doc){
        var out = { courses: [], tables: 0, header: false, sections: 0 };
        var tables = Array.from(doc.querySelectorAll('table'));
        out.tables = tables.length;
        // 找网格表：某一行同时含 星期一 和 星期日（排除下方「无课表课程」等附表）
        var gridTable = null, headerRowIdx = -1;
        for (var ti = 0; ti < tables.length && !gridTable; ti++) {
          var trs = Array.from(tables[ti].querySelectorAll('tr'));
          for (var hi = 0; hi < trs.length; hi++) {
            var t = (trs[hi].textContent || '').replace(/\s/g, '');
            if (t.indexOf('星期一') >= 0 && t.indexOf('星期日') >= 0) {
              gridTable = tables[ti]; headerRowIdx = hi; break;
            }
          }
        }
        if (!gridTable) return out;
        out.header = true;
        var grid = buildGrid(gridTable);
        var colDay = {};
        (grid[headerRowIdx] || []).forEach(function(cell, col){
          if (!cell) return;
          var m = clean(cell.textContent).match(/星期([一二三四五六日])/);
          if (m) colDay[col] = CN_DAY[m[1]];
        });
        function parseWeekSpec(spec){
          var weeks = [];
          spec.split(',').forEach(function(part){
            part = part.trim();
            var r = part.match(/^(\d+)\s*-\s*(\d+)$/);
            if (r) { var a = +r[1], b = +r[2]; for (var i = a; i <= b; i++) weeks.push(i); }
            else if (/^\d+$/.test(part)) weeks.push(+part);
          });
          return weeks;
        }
        for (var r = headerRowIdx + 1; r < grid.length; r++) {
          var row = grid[r] || [];
          var section = row[0] ? clean(row[0].textContent).replace(/\s/g, '') : '';
          // 放宽：行首列只要含「第…节」就算节次行（兼容带时间的「第一大节 08:00-09:40」）
          if (!/第.+节/.test(section)) continue;
          var per = sectionPeriods(section);
          if (!per) continue;
          out.sections++;
          var seenCells = [];   // colspan 单元格在网格里占多列，只认第一个列号
          Object.keys(colDay).forEach(function(colStr){
            var col = parseInt(colStr, 10);
            var cell = row[col];
            if (!cell || seenCells.indexOf(cell) >= 0) return;
            seenCells.push(cell);
            parseBlocks(cellLines(cell)).forEach(function(b){
              var name = b.name.replace(/^备注[:：]\s*/, '').trim();
              if (!name) return;
              var weeks = parseWeekSpec((b.weekline.match(/([\d,\-]+)\s*周/) || [null, ''])[1] || '');
              var pm = b.weekline.match(/\((\d+)\s*-\s*(\d+)节\)/);
              var sp = pm ? +pm[1] : null, ep = pm ? +pm[2] : null;
              if (sp === null) { sp = per[0]; ep = per[1]; }
              if (!weeks.length) return;
              var parity = 'both';
              if (weeks.every(function(w){ return w % 2 === 1; })) parity = 'single';
              else if (weeks.every(function(w){ return w % 2 === 0; })) parity = 'double';
              out.courses.push({
                name: name,
                teacher: b.teacher,
                location: b.loc.join(' ').trim(),
                day: colDay[col],
                startWeek: Math.min.apply(null, weeks),
                endWeek: Math.max.apply(null, weeks),
                parity: parity,
                startPeriod: sp, endPeriod: ep || sp
              });
            });
          });
        }
        return out;
      }
      // 顶层找不到网格表 → 递归 iframe/frame（同源才能读 contentDocument，跨域静默跳过）
      var res = scanDoc(document);
      if (!res.header) {
        var fr = document.querySelectorAll('iframe,frame');
        for (var fi = 0; fi < fr.length; fi++) {
          var fdoc = null;
          try { fdoc = fr[fi].contentDocument; } catch (e) { fdoc = null; }
          if (!fdoc) continue;
          var r2 = scanDoc(fdoc);
          if (r2.header) { res = r2; break; }
        }
      }
      // 周次上下文：页面切到第 N 周时，可见课块即该周真实课表 → parity 强制按 N 奇偶
      var wk = weekContextOf(document);
      if (wk) {
        res.courses.forEach(function(c){
          c.parity = (wk % 2 === 1) ? 'single' : 'double';
        });
      }
      var diag = { tables: res.tables, header: res.header, sections: res.sections, week: wk, cas: isCasDoc(document) };
      return JSON.stringify({ courses: res.courses, diag: diag });
    })()
    """#

    /// 原始课程 → Course。节次→时间用默认作息表占位（导入预览里可逐课改）。
    /// 按 名称+星期+时间+周次 去重：单双周拆两格的同一门课会各自成条，不合并也不重复。
    static func mapCourses(_ raw: [RawCourse]) -> [Course] {
        var seen = Set<String>()
        var out: [Course] = []
        for r in raw {
            guard (1...7).contains(r.day) else { continue }
            guard r.startWeek >= 1, r.endWeek >= r.startWeek, r.endWeek <= 30 else { continue }
            let times = periodTimes(startPeriod: r.startPeriod, endPeriod: r.endPeriod)
            let key = "\(r.name)|\(r.day)|\(times.0)|\(r.startWeek)-\(r.endWeek)|\(r.parity)"
            guard seen.insert(key).inserted else { continue }
            let parity: WeekParity
            switch r.parity {
            case "single": parity = .single
            case "double": parity = .double
            default: parity = .both
            }
            out.append(Course(
                name: r.name, teacher: r.teacher, location: r.location,
                dayOfWeek: r.day, startTime: times.0, endTime: times.1,
                startWeek: r.startWeek, endWeek: r.endWeek,
                weekParity: parity,
                color: CourseColorPalette.color(forDay: r.day)))
        }
        return out
    }

    /// 节次 → 默认时间占位（用户导入预览里改）。新疆理工真实作息未知，
    /// 按国内常见 2 节/大节 排：01-02 / 03-04 / 05-06 / 07-08 / 09-10 / 11-12。
    private static let periodSchedule = [
        ("08:00", "09:40"), ("10:00", "11:40"), ("14:00", "15:40"),
        ("16:00", "17:40"), ("19:00", "20:40"), ("20:50", "22:30")
    ]

    /// 单双周两段式提取的合并：用户切到单周提一次、双周提一次，这里把两批合成一张表。
    /// 键 = 星期 + 时间段（同一大节格子）。
    /// - 同格同名同 parity：去重保留一条（同一周次重复提取 / 全周视图重复）
    /// - 同格同名但 parity 一单一双：合并成 both（该课每周上），周次取并集范围
    /// - 同格不同课名（单周高数 / 双周英语）：各自成条
    /// - 只在其中一批出现：保留该批的 parity
    static func mergeCourses(_ old: [Course], _ new: [Course]) -> [Course] {
        var out = old
        for c in new {
            if let idx = out.firstIndex(where: {
                $0.dayOfWeek == c.dayOfWeek && $0.startTime == c.startTime && $0.endTime == c.endTime
            }) {
                let o = out[idx]
                guard o.name == c.name else {
                    out.append(c)   // 同格不同课：单双周各是一门
                    continue
                }
                if o.weekParity != c.weekParity, o.weekParity != .both, c.weekParity != .both {
                    out[idx] = Course(
                        name: o.name, teacher: o.teacher, location: o.location,
                        dayOfWeek: o.dayOfWeek, startTime: o.startTime, endTime: o.endTime,
                        startWeek: min(o.startWeek, c.startWeek),
                        endWeek: max(o.endWeek, c.endWeek),
                        weekParity: .both,
                        color: o.color)
                }
                // 同名同 parity：保留 old，跳过 new
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func periodTimes(startPeriod: Int, endPeriod: Int) -> (String, String) {
        let idx = (max(1, startPeriod) - 1) / 2
        guard idx >= 0, idx < periodSchedule.count else { return periodSchedule[0] }
        return periodSchedule[idx]
    }
}
