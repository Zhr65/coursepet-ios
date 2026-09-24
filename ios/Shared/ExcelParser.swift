// MARK: - Excel (.xlsx) 解析器
// .xlsx 文件是一个 ZIP 压缩包，内部结构：
//   xl/sharedStrings.xml  — 所有字符串的共享池
//   xl/worksheets/sheet1.xml — 单元格数据（含列/行索引和值引用）
// 本文件使用 SSZipArchive + Swift XMLParser 实现纯原生解析

import Foundation
import SSZipArchive

// MARK: - 列映射（支持不同表头命名）
enum SheetColumn: String {
    case name, teacher, location, day, startTime, endTime, startWeek, endWeek
}

extension SheetColumn {
    /// 根据表头关键词自动推断列类型
    static func detect(from header: String) -> SheetColumn? {
        let h = header.lowercased().trimmingCharacters(in: .whitespaces)
        if h.contains("课程") || h.contains("名称") || h.contains("科目") || h.contains("name") { return .name }
        if h.contains("教师") || h.contains("老师") || h.contains("professor") || h.contains("teacher") { return .teacher }
        if h.contains("地点") || h.contains("教室") || h.contains("位置") || h.contains("location") || h.contains("教室") { return .location }
        if h.contains("星期") || h.contains("周几") || h.contains("day") || h.contains("周") { return .day }
        if h.contains("开始") || h.contains("起始") || h.contains("start") { return .startTime }
        if h.contains("结束") || h.contains("终止") || h.contains("end") { return .endTime }
        if h.contains("起始周") || h.contains("开始周") { return .startWeek }
        if h.contains("结束周") || h.contains("终止周") { return .endWeek }
        return nil
    }
}

// MARK: - 解析结果
struct ParsedSheet {
    let courses: [Course]
    let headers: [String]
}

// MARK: - ExcelParser
struct ExcelParser {

    // MARK: - 公开接口
    /// 解析单个 .xlsx 文件，返回课程列表
    static func parse(url: URL) throws -> ParsedSheet {
        guard let zipData = try? Data(contentsOf: url) else {
            throw ExcelError.noData
        }

        // 解压到临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx_parse_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tempDir)
        SSZipArchive.unzipFile(atPath: url.path, toDestination: tempDir.path, overwrite: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 读取 shared strings
        let sharedStrings = try readSharedStrings(from: tempDir)

        // 读取 worksheet
        let (headers, rows) = try readWorksheet(from: tempDir, sharedStrings: sharedStrings)

        // 自动检测列映射
        let columnMap = detectColumns(headers: headers)

        // 生成 Course 数组
        var courses: [Course] = []
        for row in rows {
            guard let name = cellValue(row: row, col: columnMap[.name]),
                  !name.isEmpty,
                  let dayStr = cellValue(row: row, col: columnMap[.day]),
                  let startTime = cellValue(row: row, col: columnMap[.startTime]),
                  let endTime = cellValue(row: row, col: columnMap[.endTime])
            else { continue }

            let day = Int(dayStr) ?? 0
            guard day >= 1 && day <= 7 else { continue }

            let startWeek = Int(cellValue(row: row, col: columnMap[.startWeek]) ?? "1") ?? 1
            let endWeek = Int(cellValue(row: row, col: columnMap[.endWeek]) ?? "20") ?? 20

            let course = Course(
                name: name,
                teacher: cellValue(row: row, col: columnMap[.teacher]) ?? "",
                location: cellValue(row: row, col: columnMap[.location]) ?? "",
                dayOfWeek: day,
                startTime: trimTime(startTime),
                endTime: trimTime(endTime),
                startWeek: startWeek,
                endWeek: endWeek,
                weekParity: .both
            )
            courses.append(course)
        }

        return ParsedSheet(courses: courses, headers: headers)
    }

    // MARK: - 私有方法
    private static func readSharedStrings(from dir: URL) throws -> [String] {
        let paths = ["xl/sharedStrings.xml", "sharedStrings.xml"]
        for path in paths {
            let fileURL = dir.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return parseSharedStringsXML(content)
        }
        return []
    }

    private static func parseSharedStringsXML(_ xml: String) -> [String] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = SharedStringsParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private static func readWorksheet(from dir: URL, sharedStrings: [String]) throws -> (headers: [String], rows: [[String]]) {
        let paths = ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet.xml", "worksheets/sheet1.xml"]
        for path in paths {
            let fileURL = dir.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return parseWorksheetXML(content, sharedStrings: sharedStrings)
        }
        throw ExcelError.noWorksheet
    }

    private static func parseWorksheetXML(_ xml: String, sharedStrings: [String]) -> (headers: [String], rows: [[String]]) {
        guard let data = xml.data(using: .utf8) else { return ([], []) }
        let parser = XMLParser(data: data)
        let delegate = WorksheetParser(sharedStrings: sharedStrings)
        parser.delegate = delegate
        parser.parse()
        return (delegate.headers, delegate.rows)
    }

    private static func detectColumns(headers: [String]) -> [SheetColumn: String] {
        var map: [SheetColumn: String] = [:]
        for (index, header) in headers.enumerated() {
            if let col = SheetColumn.detect(from: header) {
                map[col] = String(format: "%c", 65 + index) // A, B, C...
            }
        }
        return map
    }

    private static func cellValue(row: [String], col: String?) -> String? {
        guard let col = col else { return nil }
        let colIndex = columnLetterToIndex(col)
        guard colIndex < row.count else { return nil }
        let raw = row[colIndex]
        // 尝试作为 shared string 索引
        if let idx = Int(raw), idx >= 0, idx < 10000 {
            return raw // 由 WorksheetParser 直接解析为字符串
        }
        return raw
    }

    private static func trimTime(_ time: String) -> String {
        let parts = time.split(separator: ":")
        if parts.count >= 2 {
            let h = parts[0].count == 1 ? "0" + parts[0].description : parts[0].description
            let m = parts[1].count == 1 ? "0" + parts[1].description : parts[1].description
            return "\(h):\(m)"
        }
        return time
    }

    /// 列字母转 0-based 索引（A=0, B=1, ..., Z=25, AA=26...）
    private static func columnLetterToIndex(_ letter: String) -> Int {
        var result = 0
        for c in letter.uppercased() {
            guard let digit = c.wholeNumberValue else { break }
            result = result * 26 + (digit - 1)
        }
        return result
    }
}

// MARK: - XML Parser Delegate: sharedStrings.xml
private class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentString = ""
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
        if elementName == "si" { currentString = "" }
        if elementName == "t" { inT = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { currentString += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "t" { inT = false }
        if elementName == "si" { strings.append(currentString) }
    }
}

// MARK: - XML Parser Delegate: worksheet XML
private class WorksheetParser: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var headers: [String] = []
    var rows: [[String]] = []

    private var currentRowIdx = 0
    private var currentRowData: [String: String] = [:]
    private var inValue = false
    private var currentValue = ""
    private var currentCellRef = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
        if elementName == "row", let r = attributes["r"], let row = Int(r) {
            currentRowIdx = row - 1
            currentRowData = [:]
        }
        if elementName == "c", let ref = attributes["r"] {
            currentCellRef = ref
            currentValue = ""
            let t = attributes["t"] ?? ""
            inValue = (t != "s") // 非共享字符串类型直接读值
        }
        if elementName == "v" {
            inValue = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "v" { inValue = false }
        if elementName == "c" {
            var resolved = currentValue
            if let idx = Int(currentValue), idx >= 0, idx < sharedStrings.count {
                resolved = sharedStrings[idx]
            }
            currentRowData[currentCellRef] = resolved
        }
        if elementName == "row" {
            rows.append(currentRowData)
            if currentRowIdx == 0 {
                headers = currentRowData.keys.sorted().map { currentRowData[$0] ?? "" }
            }
        }
    }
}

// MARK: - 错误类型
enum ExcelError: LocalizedError {
    case noData, noWorksheet, invalidFormat
    var errorDescription: String? {
        switch self {
        case .noData: return "无法读取文件数据"
        case .noWorksheet: return "未找到工作表数据"
        case .invalidFormat: return "文件格式无效，请确保是 .xlsx 文件"
        }
    }
}
