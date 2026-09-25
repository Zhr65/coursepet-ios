// MARK: - Excel (.xlsx) 解析器
// .xlsx 文件是一个 ZIP 压缩包，内部结构：
//   xl/sharedStrings.xml  — 所有字符串的共享池
//   xl/worksheets/sheet1.xml — 单元格数据（含列/行索引和值引用）
// 本文件使用系统 Compression 框架原生解压 ZIP，无需第三方依赖

import Foundation
import Compression

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
        if h.contains("地点") || h.contains("教室") || h.contains("位置") || h.contains("location") { return .location }
        if h.contains("星期") || h.contains("周几") || h.contains("day") { return .day }
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

// MARK: - 原生 ZIP 读取器（仅支持 STORED / DEFLATE，满足 .xlsx 需求）
enum ZipReader {

    static func extract(_ data: Data) throws -> [String: Data] {
        // 1. 定位 EOCD（End Of Central Directory，签名 0x06054b50）
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count > 22 else { throw ExcelError.invalidFormat }
        var eocdOffset = -1
        let searchFloor = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= searchFloor {
            if data[i] == eocdSig[0], data[i+1] == eocdSig[1],
               data[i+2] == eocdSig[2], data[i+3] == eocdSig[3] {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ExcelError.invalidFormat }

        // EOCD: totalEntries @ +10, cdOffset @ +16
        let totalEntries = u16(data, eocdOffset + 10)
        var cdOffset = u32(data, eocdOffset + 16)

        // 2. 遍历 Central Directory（条目签名 0x02014b50，固定头 46 字节）
        var result: [String: Data] = [:]
        for _ in 0..<totalEntries {
            guard cdOffset + 46 <= data.count, u32(data, cdOffset) == 0x02014B50 else { break }
            let method = u16(data, cdOffset + 10)
            let compSize = u32(data, cdOffset + 20)
            let nameLen = u16(data, cdOffset + 28)
            let extraLen = u16(data, cdOffset + 30)
            let commentLen = u16(data, cdOffset + 32)
            let localOffset = u32(data, cdOffset + 42)
            let name = String(data: data.subdata(in: (cdOffset+46)..<(cdOffset+46+nameLen)), encoding: .utf8) ?? ""

            if !name.hasSuffix("/") && compSize > 0 && (method == 0 || method == 8) {
                // 3. 定位 Local File Header（签名 0x04034b50，固定头 30 字节）
                if localOffset + 30 <= data.count, u32(data, localOffset) == 0x04034B50 {
                    let lNameLen = u16(data, localOffset + 26)
                    let lExtraLen = u16(data, localOffset + 28)
                    let dataStart = localOffset + 30 + lNameLen + lExtraLen
                    if dataStart + compSize <= data.count {
                        let comp = data.subdata(in: dataStart..<(dataStart+compSize))
                        if method == 0 {
                            result[name] = comp
                        } else if let raw = inflate(comp, uncompressedSize: u32(data, cdOffset + 24)) {
                            result[name] = raw
                        }
                    }
                }
            }
            cdOffset += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// 原始 DEFLATE 解压（Apple COMPRESSION_ZLIB 即 RFC1951 裸 deflate）
    private static func inflate(_ src: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var dst = Data(count: uncompressedSize)
        let decoded = dst.withUnsafeMutableBytes { dstPtr -> Int in
            src.withUnsafeBytes { srcPtr -> Int in
                guard let dBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                      let sBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dBase, uncompressedSize,
                                                 sBase, src.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded > 0 else { return nil }
        return dst.prefix(decoded)
    }

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o + 2 <= d.count else { return 0 }
        return Int(d[o]) | (Int(d[o+1]) << 8)
    }

    private static func u32(_ d: Data, _ o: Int) -> Int {
        guard o + 4 <= d.count else { return 0 }
        return Int(d[o]) | (Int(d[o+1]) << 8) | (Int(d[o+2]) << 16) | (Int(d[o+3]) << 24)
    }
}

// MARK: - ExcelParser
struct ExcelParser {

    // MARK: - 公开接口
    /// 解析单个 .xlsx 文件，返回课程列表
    static func parse(url: URL) throws -> ParsedSheet {
        guard let zipData = try? Data(contentsOf: url) else {
            throw ExcelError.noData
        }

        // 原生解压 ZIP → [文件名: 内容]
        let entries = try ZipReader.extract(zipData)

        // 读取 shared strings
        let sharedStrings: [String]
        if let ssData = entries["xl/sharedStrings.xml"] {
            sharedStrings = parseSharedStringsXML(ssData)
        } else {
            sharedStrings = []
        }

        // 读取 worksheet
        guard let sheetData = entries["xl/worksheets/sheet1.xml"] ?? entries["xl/worksheets/sheet.xml"] else {
            throw ExcelError.noWorksheet
        }
        let (headers, rows) = parseWorksheetXML(sheetData, sharedStrings: sharedStrings)

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
    private static func parseSharedStringsXML(_ data: Data) -> [String] {
        let parser = XMLParser(data: data)
        let delegate = SharedStringsParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private static func parseWorksheetXML(_ data: Data, sharedStrings: [String]) -> (headers: [String], rows: [[String]]) {
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
                map[col] = columnLetter(fromIndex: index)
            }
        }
        return map
    }

    private static func cellValue(row: [String], col: String?) -> String? {
        guard let col = col else { return nil }
        let colIndex = columnLetterToIndex(col)
        guard colIndex < row.count else { return nil }
        return row[colIndex]
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

    /// 0-based 索引转列字母（0→A, 1→B, 25→Z, 26→AA）
    private static func columnLetter(fromIndex index: Int) -> String {
        var n = index + 1
        var letters = ""
        while n > 0 {
            let rem = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = (n - 1) / 26
        }
        return letters
    }

    /// 列字母转 0-based 索引（A=0, B=1, ..., Z=25, AA=26...）
    private static func columnLetterToIndex(_ letter: String) -> Int {
        var result = 0
        for c in letter.uppercased() {
            guard let v = c.wholeNumberValue, v >= 65, v <= 90 else { break }
            result = result * 26 + (v - 64)
        }
        return result - 1
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
    /// 每行按列索引展开的数组（row[colIndex] = 单元格值）
    var rows: [[String]] = []

    private var currentRowIdx = 0
    private var currentRowData: [Int: String] = [:]
    private var inValue = false
    private var currentValue = ""
    private var currentColIdx = 0

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
        if elementName == "row", let r = attributes["r"], let row = Int(r) {
            currentRowIdx = row - 1
            currentRowData = [:]
        }
        if elementName == "c", let ref = attributes["r"] {
            currentValue = ""
            currentColIdx = columnIndex(fromRef: ref)
            let t = attributes["t"] ?? ""
            inValue = (t != "s") // 共享字符串类型需另外解析 <v> 索引
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
            // t="s" 类型：值是 sharedStrings 的下标
            if Int(currentValue) != nil, currentValue.count < 6 {
                let idx = Int(currentValue) ?? -1
                if idx >= 0 && idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                }
            }
            currentRowData[currentColIdx] = resolved
        }
        if elementName == "row" {
            let maxCol = currentRowData.keys.max() ?? -1
            var arr = Array(repeating: "", count: maxCol + 1)
            for (col, value) in currentRowData where col >= 0 {
                arr[col] = value
            }
            if currentRowIdx == 0 {
                headers = arr
            }
            rows.append(arr)
        }
    }

    /// 单元格引用转列索引（"C5" → 2）
    private func columnIndex(fromRef ref: String) -> Int {
        var result = 0
        for c in ref.uppercased() {
            guard let v = c.wholeNumberValue, v >= 65, v <= 90 else { break }
            result = result * 26 + (v - 64)
        }
        return result - 1
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
