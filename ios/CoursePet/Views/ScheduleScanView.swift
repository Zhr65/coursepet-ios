// MARK: - 课表截图导入（Vision OCR）
// 流程：相册选课表截图 → Vision 文字识别（含文字包围盒）→
//       按表头"星期"列锚点做列对齐，解析出课程草稿 → 确认页逐条修正后批量导入。
// 说明：不同学校课表版式差异极大，识别结果仅供参考，
//       因此设计了"确认页"让用户逐条检查修正，而不是直接静默导入。
import SwiftUI
import PhotosUI
import Vision

// MARK: - OCR 单行结果（文本 + 归一化包围盒，0~1，Y 向上为正已换算成向下）
struct OCRLine {
    let text: String
    let minX: CGFloat
    let maxX: CGFloat
    let midX: CGFloat
    let midY: CGFloat   // 0 = 图片顶部，1 = 底部（便于"从上往下"排序）
}

// MARK: - 课程草稿（导入前可编辑）
struct CourseDraft: Identifiable {
    var id = UUID()
    var isSelected = true
    var name: String
    var room: String
    var day: Int            // 1=周一…7=周日
    var startPeriod: Int    // 开始节次 1~11
    var endPeriod: Int
    var startWeek: Int = 1
    var endWeek: Int = 20
    var parity: WeekParity = .both
}

// MARK: - 默认作息表（第几节 → 上下课时间；各校不同，导入后可在课程编辑里微调）
enum PeriodTimes {
    /// (开始节, 结束节) → 时间字符串
    static func start(_ p: Int) -> String {
        let starts = ["08:00", "08:55", "10:00", "10:55", "14:00", "14:55", "16:00", "16:55", "19:00", "19:55", "20:50"]
        return p >= 1 && p <= 11 ? starts[p - 1] : "08:00"
    }
    static func end(_ p: Int) -> String {
        let ends = ["08:45", "09:40", "10:45", "11:40", "14:45", "15:40", "16:45", "17:40", "19:45", "20:40", "21:35"]
        return p >= 1 && p <= 11 ? ends[p - 1] : "08:45"
    }
}

// MARK: - 课表截图解析器（纯逻辑，便于以后抽出来写单元测试）
enum CourseScheduleParser {
    /// 星期表头候选词（长词优先）
    static let dayHeaders: [(text: String, day: Int)] = [
        ("星期一", 1), ("周一", 1), ("星期二", 2), ("周二", 2),
        ("星期三", 3), ("周三", 3), ("星期四", 4), ("周四", 4),
        ("星期五", 5), ("周五", 5), ("星期六", 6), ("周六", 6),
        ("星期日", 7), ("周日", 7), ("星期天", 7), ("周天", 7),
    ]
    /// 周次正则：1-16周 / 1~16周（可带"单周/双周"）
    static let weekRegex = try! NSRegularExpression(pattern: #"(\d{1,2})\s*[-–—~]\s*(\d{1,2})\s*周"#)
    /// 节次正则：第3-4节 / 3-4节
    static let periodRegex = try! NSRegularExpression(pattern: #"第?\s*(\d{1,2})\s*[-–—~]\s*(\d{1,2})\s*节?"#)
    /// 教室正则：教三-401 / A栋301 / 二教201 / 图书馆302 等（中英文字符 + 3~4 位数字）
    static let roomRegex = try! NSRegularExpression(pattern: #"[A-Za-z\u4e00-\u9fa5]{1,5}[-—]?\d{3,4}"#)
    /// 纯时间/节次行（表格左侧的时间列，不能当课程名）
    static let timeOnlyRegex = try! NSRegularExpression(pattern: #"^\s*(第?\s*\d{1,2}\s*[-–—~]?\s*\d{0,2}\s*节?|\d{1,2}:\d{2}|-+)\s*$"#)

    /// 主入口：OCR 全部行 → 课程草稿列表
    static func parse(_ lines: [OCRLine]) -> [CourseDraft] {
        guard !lines.isEmpty else { return [] }

        // ── 第一步：找"星期"表头，建立 7 列的 X 坐标锚点 ──
        var anchors: [Int: CGFloat] = [:]   // day → midX
        for line in lines {
            for header in dayHeaders where anchors[header.day] == nil {
                if line.text.contains(header.text) {
                    anchors[header.day] = line.midX
                }
            }
        }
        // 表头缺失时按列宽均分兜底（跳过左侧可能的行号/时间列，取剩余宽度 7 等分）
        if anchors.count < 3 {
            anchors = [:]
            let left = 0.14, right = 0.98
            let width = (right - left) / 7
            for day in 1...7 {
                anchors[day] = left + width * (CGFloat(day) - 0.5)
            }
        }

        // ── 第二步：把每个 OCR 行归到最近列（阈值 0.09，太远视为不属于任何列） ──
        var columnLines: [Int: [OCRLine]] = [:]
        for line in lines {
            // 纯时间/节次行跳过
            if timeOnlyRegex.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) != nil { continue }
            var bestDay = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (day, x) in anchors {
                let d = abs(line.midX - x)
                if d < bestDist {
                    bestDist = d
                    bestDay = day
                }
            }
            guard bestDist < 0.09 else { continue }
            columnLines[bestDay, default: []].append(line)
        }

        // ── 第三步：每列内按 Y 聚合成单元格（相邻间距小于 0.045 视为同一格），解析每个格子 ──
        var drafts: [CourseDraft] = []
        for (day, colLines) in columnLines {
            let sorted = colLines.sorted { $0.midY < $1.midY }
            var cells: [[OCRLine]] = []
            for line in sorted {
                if var last = cells.last, let lastLine = last.last,
                   line.midY - lastLine.midY < 0.045 {
                    last.append(line)
                    cells[cells.count - 1] = last
                } else {
                    cells.append([line])
                }
            }
            for cell in cells {
                if let draft = parseCell(cell, day: day) {
                    drafts.append(draft)
                }
            }
        }
        return drafts
    }

    // MARK: 单个单元格（若干相邻行）→ 课程草稿
    static func parseCell(_ cell: [OCRLine], day: Int) -> CourseDraft? {
        let fullText = cell.map { $0.text }.joined(separator: "\n")
        let ns = fullText as NSString

        // 周次
        var startWeek = 1, endWeek = 20
        var parity: WeekParity = .both
        if let m = weekRegex.firstMatch(in: fullText, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 {
            startWeek = Int(ns.substring(with: m.range(at: 1))) ?? 1
            endWeek = Int(ns.substring(with: m.range(at: 2))) ?? 20
        } else {
            return nil   // 没有周次信息的文本块大概率不是课程单元格（避免把页脚/标题误收）
        }
        if fullText.contains("单周") { parity = .single }
        if fullText.contains("双周") { parity = .double }

        // 节次（默认 1-2 节）
        var startPeriod = 1, endPeriod = 2
        if let m = periodRegex.firstMatch(in: fullText, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 {
            let s = Int(ns.substring(with: m.range(at: 1))) ?? 1
            let e = Int(ns.substring(with: m.range(at: 2))) ?? s
            if (1...11).contains(s) && (s...11).contains(e) {
                startPeriod = s
                endPeriod = e
            }
        }

        // 课程名与教室：逐行处理；教室先从原始行提取，再把周次/节次/教室片段剔除后取课程名
        var name: String?
        var room: String?
        for raw in cell.map({ $0.text }) {
            let rawNS = raw as NSString
            // 教室候选（清洗前提取，如 "教三-401"、"A栋301"）
            if room == nil, let m = roomRegex.firstMatch(in: raw, range: NSRange(location: 0, length: rawNS.length)) {
                room = rawNS.substring(with: m.range)
            }
            var cleaned = raw
            for regex in [weekRegex, periodRegex, roomRegex] {
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length), withTemplate: " ")
            }
            cleaned = cleaned
                .replacingOccurrences(of: "单周", with: "")
                .replacingOccurrences(of: "双周", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count < 2 { continue }
            if name == nil { name = String(cleaned.prefix(20)) }
            if name != nil && room != nil { break }
        }

        guard let finalName = name, !finalName.isEmpty else { return nil }
        return CourseDraft(
            name: finalName,
            room: room ?? "",
            day: day,
            startPeriod: startPeriod,
            endPeriod: endPeriod,
            startWeek: startWeek,
            endWeek: endWeek,
            parity: parity
        )
    }
}

// MARK: - 扫描入口视图（课表页工具栏进）
struct ScheduleScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    @State private var pickedItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var drafts: [CourseDraft] = []
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 64))
                    .foregroundColor(.indigo)
                Text("课表截图导入")
                    .font(.title2.weight(.semibold))
                Text("从学校 App / 教务系统截图课表，选择图片后自动识别课程。\n识别结果需逐条确认，时间按默认作息换算，可再编辑。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(isScanning ? "识别中…" : "选择课表截图", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.indigo.opacity(0.15))
                        .foregroundColor(.indigo)
                        .cornerRadius(14)
                }
                .disabled(isScanning)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("截图导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: pickedItem) { item in
                guard let item else { return }
                scan(item)
            }
            .sheet(isPresented: $showConfirm) {
                ScanConfirmView(drafts: $drafts)
                    .environmentObject(dataManager)
            }
        }
    }

    // MARK: 选图 → Vision 识别 → 解析
    private func scan(_ item: PhotosPickerItem) {
        isScanning = true
        errorMessage = nil
        item.loadTransferable(type: Data.self) { result in
            defer { DispatchQueue.main.async { isScanning = false } }
            guard case .success(let data?) = result,
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                DispatchQueue.main.async { errorMessage = "图片加载失败，换一张试试" }
                return
            }
            // Vision 文字识别（主线程外执行，回主线程更新 UI）
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    let bb = obs.boundingBox   // origin 在左下角
                    return OCRLine(
                        text: candidate.string,
                        minX: bb.minX,
                        maxX: bb.maxX,
                        midX: bb.midX,
                        midY: 1 - bb.midY       // 换算成"顶部为 0"
                    )
                }
                let parsed = CourseScheduleParser.parse(lines)
                DispatchQueue.main.async {
                    if parsed.isEmpty {
                        errorMessage = "没识别出课程，这张截图可能不是标准课表"
                    } else {
                        drafts = parsed
                        showConfirm = true
                    }
                }
            } catch {
                DispatchQueue.main.async { errorMessage = "识别失败：\(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - 识别结果确认页（逐条修正后导入）
struct ScanConfirmView: View {
    @Binding var drafts: [CourseDraft]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager
    @State private var importedToast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("共识别 \(drafts.count) 门课，取消勾选即不导入。时间按默认作息表换算，导入后可在课表长按编辑微调。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach($drafts) { $draft in
                    Section {
                        // 勾选 + 课程名
                        HStack(spacing: 10) {
                            Button {
                                draft.isSelected.toggle()
                            } label: {
                                Image(systemName: draft.isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(draft.isSelected ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            TextField("课程名", text: $draft.name)
                                .font(.body.weight(.medium))
                        }
                        // 详情行内编辑
                        DisclosureGroup("周\(draft.day) · 第\(draft.startPeriod)-\(draft.endPeriod)节 · \(draft.startWeek)-\(draft.endWeek)周\(parityLabel(draft.parity)) · \(draft.room.isEmpty ? "未识别教室" : draft.room)") {
                            Picker("星期", selection: $draft.day) {
                                ForEach(1...7, id: \.self) { Text("周\(dayName($0))").tag($0) }
                            }
                            Stepper("开始节次：第\(draft.startPeriod)节", value: $draft.startPeriod, in: 1...11)
                            Stepper("结束节次：第\(draft.endPeriod)节", value: $draft.endPeriod, in: draft.startPeriod...11)
                            Stepper("开始周：第\(draft.startWeek)周", value: $draft.startWeek, in: 1...25)
                            Stepper("结束周：第\(draft.endWeek)周", value: $draft.endWeek, in: draft.startWeek...25)
                            Picker("单双周", selection: $draft.parity) {
                                Text("每周").tag(WeekParity.both)
                                Text("单周").tag(WeekParity.single)
                                Text("双周").tag(WeekParity.double)
                            }
                            TextField("教室", text: $draft.room)
                            Text("换算时间：\(PeriodTimes.start(draft.startPeriod)) - \(PeriodTimes.end(draft.endPeriod))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("确认导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("全部导入") { importSelected() }
                        .disabled(!drafts.contains { $0.isSelected && !$0.name.isEmpty })
                }
            }
            .overlay(alignment: .bottom) {
                if let importedToast {
                    Text(importedToast)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(20)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func parityLabel(_ p: WeekParity) -> String {
        switch p {
        case .single: return "（单周）"
        case .double: return "（双周）"
        case .both: return ""
        }
    }
    private func dayName(_ d: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][d - 1]
    }

    // MARK: 批量导入选中草稿
    private func importSelected() {
        let selected = drafts.filter { $0.isSelected && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !selected.isEmpty else { return }
        for d in selected {
            dataManager.addCourse(Course(
                name: d.name,
                location: d.room,
                dayOfWeek: d.day,
                startTime: PeriodTimes.start(d.startPeriod),
                endTime: PeriodTimes.end(d.endPeriod),
                startWeek: d.startWeek,
                endWeek: d.endWeek,
                weekParity: d.parity
            ))
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        importedToast = "已导入 \(selected.count) 门课程"
        // 短暂展示 toast 后关闭整条链路（确认页 + 扫描页）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }
}
