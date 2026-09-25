// MARK: - Excel 导入视图（支持 .xlsx）
import SwiftUI
import UniformTypeIdentifiers

struct ExcelImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager
    @State private var selectedFile: URL?
    @State private var showFilePicker = false
    @State private var parsedCourses: [Course] = []
    @State private var importMode: ImportMode = .single
    @State private var secondFile: URL?
    @State private var showSecondPicker = false
    @State private var errorMessage: String?
    @State private var showPreview = false

    enum ImportMode: String, CaseIterable {
        case single, both
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("导入课表")
                    .font(.title2)
                    .fontWeight(.bold)

                // 模式选择
                Picker("导入模式", selection: $importMode) {
                    Text("单周课表").tag(ImportMode.single)
                    Text("单周 + 双周").tag(ImportMode.both)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)

                // 第一个文件
                fileButton(title: "选择文件", url: $selectedFile, showPicker: $showFilePicker)

                // 第二个文件（双周模式）
                if importMode == .both {
                    Divider()
                    fileButton(title: "选择双周课表（可选）", url: $secondFile, showPicker: $showSecondPicker)
                }

                // 错误提示
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                // 预览 / 导入按钮
                if !parsedCourses.isEmpty {
                    VStack(spacing: 12) {
                        Text("已解析 \(parsedCourses.count) 条课程，请确认后导入")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ScrollView {
                            ForEach(parsedCourses) { course in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(course.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                        Text("\(course.teacher) · \(course.location)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("\(dayLabel(course.dayOfWeek)) \(course.startTime)-\(course.endTime)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(8)
                            }
                        }
                        .frame(height: 160)

                        Button {
                            importCourses()
                        } label: {
                            Text("确认导入")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .cornerRadius(12)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data]
            ) { result in
                handleFileResult(result, isSecond: false)
            }
            .fileImporter(
                isPresented: $showSecondPicker,
                allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data]
            ) { result in
                handleFileResult(result, isSecond: true)
            }
        }
    }

    // MARK: - 子视图
    private func fileButton(title: String, url: Binding<URL?>, showPicker: Binding<Bool>) -> some View {
        Button {
            showPicker.wrappedValue = true
        } label: {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(url.wrappedValue?.lastPathComponent ?? title)
                        .font(.body)
                    if let file = url.wrappedValue {
                        Text(file.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 1)
        }
    }

    // MARK: - 文件处理
    private func handleFileResult(_ result: Result<URL, Error>, isSecond: Bool) {
        switch result {
        case .success(let url):
            if isSecond {
                secondFile = url
            } else {
                selectedFile = url
            }
            parseFiles()
        case .failure(let error):
            errorMessage = "文件选择失败：\(error.localizedDescription)"
        }
    }

    private func parseFiles() {
        errorMessage = nil
        var allCourses: [Course] = []

        if let url = selectedFile {
            do {
                let result = try ExcelParser.parse(url: url)
                allCourses.append(contentsOf: result.courses)
            } catch {
                errorMessage = "解析失败：\(error.localizedDescription)"
                return
            }
        }

        if importMode == .both, let url = secondFile {
            do {
                let result = try ExcelParser.parse(url: url)
                allCourses.append(contentsOf: result.courses)
            } catch {
                errorMessage = "双周课表解析失败：\(error.localizedDescription)"
                return
            }
        }

        if allCourses.isEmpty {
            errorMessage = "未解析到课程数据，请检查 Excel 文件格式\n\n支持的列名：课程名称、教师、地点、星期几(1-7)、开始时间、结束时间、起始周、结束周"
            return
        }

        parsedCourses = allCourses
    }

    // MARK: - 工具方法
    private func dayLabel(_ day: Int) -> String {
        ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"][day] ?? ""
    }

    private func importCourses() {
        var state = dataManager.loadState()
        state.courses.append(contentsOf: parsedCourses)
        dataManager.saveState(state)
        dismiss()
    }
}
