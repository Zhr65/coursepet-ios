// MARK: - 事务页两个分区：快递取件 + 极简记账
// 由 TodoView（事务页）的分段控件挂载，共享同一套玻璃列表风格。
import SwiftUI

// ════════════════════════════════════════════════════════════
// 快递取件
// ════════════════════════════════════════════════════════════
struct ParcelSection: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showAdd = false
    /// 快捷指令传来的预填短信全文（打开弹层时解析填充，用后即清）
    @State private var prefillSMS: String? = nil

    /// 未取件：入库超 3 天的橙色置顶，其余按入库时间倒序
    private var pendingParcels: [ParcelItem] {
        dataManager.parcels.filter { $0.pickedAt == nil }
            .sorted { a, b in
                let aOld = Date().timeIntervalSince(a.createdAt) > 3 * 86400
                let bOld = Date().timeIntervalSince(b.createdAt) > 3 * 86400
                if aOld != bOld { return aOld }
                return a.createdAt > b.createdAt
            }
    }

    private var pickedParcels: [ParcelItem] {
        dataManager.parcels.filter { $0.pickedAt != nil }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("未取 \(pendingParcels.count) 件", systemImage: "shippingbox")
                    Spacer()
                    Button {
                        showAdd = true
                    } label: {
                        Label("记一个", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }
                }
                .font(.subheadline)
                .glassListRow()
            }

            Section("📦 待取件") {
                if pendingParcels.isEmpty {
                    Text("暂无待取快递，去驿站看看？")
                        .foregroundColor(.secondary)
                        .glassListRow()
                }
                ForEach(pendingParcels) { parcel in
                    parcelRow(parcel)
                }
            }

            if !pickedParcels.isEmpty {
                Section("✅ 已取") {
                    ForEach(pickedParcels) { parcel in
                        parcelRow(parcel)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showAdd) {
            AddParcelView(prefillSMS: prefillSMS)
        }
        .onChange(of: dataManager.pendingParcelSMS) { sms in
            // 快捷指令"收到短信"自动化 → URL scheme → 这里弹预填层（短信全文在弹层内解析）
            consumePendingSMS(sms)
        }
        // 首次挂载兜底：冷启动深链时 ParcelSection 是"分段切过来后才新建"的，
        // 此时 pendingParcelSMS 早已被赋值，onChange 只监听后续变化会漏掉，靠 onAppear 补消费
        .task {
            consumePendingSMS(dataManager.pendingParcelSMS)
        }
    }

    /// 消费快捷指令传来的短信全文：先置 nil 防重复弹出，再弹预填层
    private func consumePendingSMS(_ sms: String?) {
        guard let sms, !sms.isEmpty else { return }
        dataManager.pendingParcelSMS = nil
        prefillSMS = sms
        showAdd = true
    }

    private func parcelRow(_ parcel: ParcelItem) -> some View {
        HStack(spacing: 12) {
            Button {
                dataManager.toggleParcelPicked(id: parcel.id)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: parcel.pickedAt != nil ? "checkmark.circle.fill" : "shippingbox")
                    .font(.title3)
                    .foregroundColor(parcel.pickedAt != nil ? .green : .orange)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                // 取件码大字（核心信息）
                Text(parcel.code)
                    .font(.body.monospaced().weight(.semibold))
                    .strikethrough(parcel.pickedAt != nil, color: .secondary)
                    .foregroundColor(parcel.pickedAt != nil ? .secondary : .primary)
                Text(parcel.station)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let note = parcel.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if parcel.pickedAt == nil {
                let days = Int(Date().timeIntervalSince(parcel.createdAt) / 86400)
                VStack(alignment: .trailing, spacing: 8) {
                    if days >= 3 {
                        Text("已入库 \(days) 天")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text(days == 0 ? "今天到的" : "\(days) 天前到")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    pickupMenu
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                dataManager.deleteParcel(id: parcel.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .glassListRow()
    }

    // MARK: - 去取件（拉起取件 App —— 身份码页无官方深链，只能拉起 App 本体让用户点进去）
    /// 未取件行的跳转入口：点开选菜鸟裹裹 / 拼多多，各走「scheme 直拉 App → 失败回落网页」
    private var pickupMenu: some View {
        Menu {
            ForEach(PickupApp.allCases, id: \.self) { app in
                Button {
                    openPickupApp(app)
                } label: {
                    Label(app.title, systemImage: "arrow.up.forward.app")
                }
            }
        } label: {
            Label("去取件", systemImage: "qrcode.viewfinder")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.indigo.opacity(0.12))
                .foregroundColor(.indigo)
                .clipShape(Capsule())
        }
    }

    /// 多级跳：依次尝试候选 scheme 直拉 App，全部失败（没装 / 被拦）再开网页兜底
    private func openPickupApp(_ app: PickupApp) {
        tryOpen(app.urls, fallback: app.web)
    }

    private func tryOpen(_ urls: [URL], fallback: URL?) {
        guard let url = urls.first else {
            if let fallback { UIApplication.shared.open(fallback) }
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            tryOpen(Array(urls.dropFirst()), fallback: fallback)
            return
        }
        UIApplication.shared.open(url) { ok in
            if !ok { tryOpen(Array(urls.dropFirst()), fallback: fallback) }
        }
    }
}

/// 「去取件」跳转目标：淘宝身份码（菜鸟驿站）与拼多多身份码（多多买菜）
/// urls 里用到的 scheme（tbopen / taobao / pinduoduo）必须同步声明在
/// Info.plist 的 LSApplicationQueriesSchemes，否则 canOpenURL 恒为 false
private enum PickupApp: CaseIterable {
    case taobaoIdentity
    case pinduoduo

    var title: String {
        switch self {
        case .taobaoIdentity: return "淘宝身份码 · 菜鸟"
        case .pinduoduo:      return "拼多多身份码 · 多多买菜"
        }
    }

    /// 按顺序尝试的拉起地址，任一成功即停。
    /// 淘宝优先用阿里妈妈官方文档的「流量宝 Deeplink」格式
    /// （tbopen://…action=ali.open.nav&module=h5&h5Url=<编码后的身份码页>），
    /// 失败再退到旧版 taobao:// 直达写法（社区逆向，可能随淘宝改版失效）。
    /// 拼多多优先级码页 H5 在 App 内打开，失败再直接开该 H5。
    var urls: [URL] {
        switch self {
        case .taobaoIdentity:
            let h5 = "https://pages-fast.m.taobao.com/wow/z/uniapp/1011717/last-mile-fe/end-collect-platform/identity-code"
            let encoded = h5.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? h5
            return [
                URL(string: "tbopen://m.taobao.com/tbopen/index.html?&action=ali.open.nav&module=h5&source=coursepet&h5Url=\(encoded)&backURL=coursepet%3A%2F%2F"),
                URL(string: "taobao://m.taobao.com/tbopen/index.html?h5Url=\(h5)")
            ].compactMap { $0 }
        case .pinduoduo:
            // 拼多多的 scheme 形如 pinduoduo://com.xunmeng.pinduoduo/<页面>，
            // 官方映射规律是「去掉域名、保留路径」：
            //   https://jinbao.pinduoduo.com/mobile/common-recharge-center.html
            //   → pinduoduo://com.xunmeng.pinduoduo//mobile/common-recharge-center.html
            // 早期试过的 http?url=<整段网址> 桥接页实机只出"页面加载不成功"，
            // 故改为路径直拼。失败再直接开 H5——
            // 若 m.pinduoduo.net 注册了 Universal Link 会进 App，否则走 Safari
            let h5 = "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE"
            return [
                URL(string: "pinduoduo://com.xunmeng.pinduoduo/mdkd/package?tab=ID_CODE"),
                URL(string: h5)
            ].compactMap { $0 }
        }
    }

    /// 没装 App / 拉起失败时的网页回落（身份码 H5 / 移动版首页）
    var web: URL? {
        switch self {
        case .taobaoIdentity: return URL(string: "https://m.taobao.com/")
        case .pinduoduo:      return URL(string: "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE")
        }
    }
}

// MARK: - 添加快递弹层
private struct AddParcelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    /// 快捷指令传来的短信全文（有值时优先解析它，否则走剪贴板检测）
    var prefillSMS: String? = nil

    @State private var code = ""
    @State private var station = ""
    @State private var note = ""
    // 是否自动识别预填（显示提示行）
    @State private var recognized = false

    var body: some View {
        NavigationStack {
            Form {
                Section("📦 快递信息") {
                    // 手动识别入口：自动检测没触发（如没授权粘贴）时点这里兜底
                    Button {
                        detectClipboard(force: true)
                    } label: {
                        Label("从剪贴板识别取件短信", systemImage: "wand.and.stars")
                            .foregroundColor(.indigo)
                    }
                    TextField("取件码（必填，如 3-2-5088）", text: $code)
                        .autocorrectionDisabled()
                    TextField("驿站 / 位置（如 菜鸟驿站·东门）", text: $station)
                    TextField("备注（可选，如 顺丰·是书）", text: $note)
                    if recognized {
                        Label("已从剪贴板自动识别，可修改后保存", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Text("保存")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.indigo)
                    }
                }
            }
            .navigationTitle("记快递")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                // 快捷指令预填：优先解析传入的短信全文；否则照旧走剪贴板检测
                if let sms = prefillSMS, let parsed = ParcelSmsParser.parse(sms) {
                    code = parsed.code
                    station = parsed.station ?? ""
                    if note.isEmpty { note = String(sms.prefix(60)) }
                    recognized = true
                } else {
                    detectClipboard()
                }
            }
        }
    }

    // MARK: - 剪贴板自动识别
    /// 打开弹层时自动检测剪贴板；force=true 表示用户手动点击按钮，强制覆盖已有表单内容。
    /// 首次读取剪贴板系统会弹"允许粘贴"授权，允许后识别才会生效。
    private func detectClipboard(force: Bool = false) {
        if !force {
            guard code.isEmpty, station.isEmpty, note.isEmpty else { return }
        }
        // hasStrings 只读元数据不触发系统"允许粘贴"弹窗；确认有文本才读正文（此时系统会弹一次授权）
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string else {
            if force {
                recognized = false
            }
            return
        }
        guard let parsed = ParcelSmsParser.parse(text) else {
            if force {
                recognized = false
            }
            return
        }
        code = parsed.code
        if let stationName = parsed.station {
            station = stationName
        }
        recognized = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func save() {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return }
        dataManager.addParcel(ParcelItem(
            code: trimmedCode,
            station: trimmedStation.isEmpty ? "驿站" : trimmedStation,
            note: note.isEmpty ? nil : note
        ))
        dismiss()
    }
}

// MARK: - 取件短信识别已迁移至 Support/ParcelSmsParser.swift（供剪贴板/URL scheme/AI 工具三处共用）

// ════════════════════════════════════════════════════════════
// 极简记账
// ════════════════════════════════════════════════════════════
struct LedgerSection: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showAdd = false

    /// 本月流水（倒序）
    private var monthEntries: [LedgerEntry] {
        let cal = Calendar.current
        let now = Date()
        return dataManager.ledgerEntries
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .sorted { $0.date > $1.date }
    }

    /// 本月各分类合计（降序）
    private var categoryTotals: [(name: String, total: Double)] {
        var dict: [String: Double] = [:]
        for e in monthEntries { dict[e.category, default: 0] += e.amount }
        return dict.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        let total = monthEntries.reduce(0) { $0 + $1.amount }
        List {
            // ── 本月总支出 ──
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本月支出")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("¥\(String(format: "%.2f", total))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.indigo)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassListRow()
            }

            // ── 分类占比条 ──
            if !categoryTotals.isEmpty {
                Section("分类占比") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(categoryTotals, id: \.name) { item in
                            HStack(spacing: 8) {
                                Image(systemName: LedgerCategory.icons[item.name] ?? "ellipsis.circle")
                                    .font(.caption)
                                    .frame(width: 20)
                                    .foregroundColor(.indigo)
                                Text(item.name)
                                    .font(.caption)
                                    .frame(width: 32, alignment: .leading)
                                // 占比条
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.indigo.opacity(0.12))
                                        Capsule().fill(Color.indigo)
                                            .frame(width: total > 0 ? geo.size.width * item.total / total : 0)
                                    }
                                }
                                .frame(height: 8)
                                Text("¥\(Int(item.total))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .glassListRow()
                }
            }

            // ── 本月流水 ──
            Section {
                HStack {
                    Label("本月 \(monthEntries.count) 笔", systemImage: "yensign.circle")
                    Spacer()
                    Button {
                        showAdd = true
                    } label: {
                        Label("记一笔", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }
                }
                .font(.subheadline)
                .glassListRow()
            } header: {
                Text("本月流水")
            }

            if monthEntries.isEmpty {
                Section {
                    Text("这个月还没记过账，点「记一笔」开始")
                        .foregroundColor(.secondary)
                        .glassListRow()
                }
            } else {
                ForEach(monthEntries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: LedgerCategory.icons[entry.category] ?? "ellipsis.circle")
                            .font(.body)
                            .foregroundColor(.indigo)
                            .frame(width: 32, height: 32)
                            .background(Color.indigo.opacity(0.1))
                            .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.category)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let note = entry.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("-¥\(String(format: "%.2f", entry.amount))")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                            Text(Self.dayString(entry.date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            dataManager.deleteLedgerEntry(id: entry.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .glassListRow()
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showAdd) {
            AddLedgerView()
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()
    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - 记一笔弹层
private struct AddLedgerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager
    // 语音记账控制器（端侧语音识别 + 口语解析）
    @StateObject private var speechCtl = SpeechLedgerController()

    @State private var amountText = ""
    @State private var category = "餐饮"
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("💰 金额") {
                    HStack {
                        Text("¥")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.indigo)
                        TextField("0.00", text: $amountText)
                            .font(.title2.monospacedDigit())
                            .keyboardType(.decimalPad)
                        Spacer()
                        // 语音记账按钮：录音中变红并脉冲提示
                        Button {
                            speechCtl.toggle()
                        } label: {
                            Image(systemName: speechCtl.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title2)
                                .foregroundColor(speechCtl.isRecording ? .red : .indigo)
                        }
                        .buttonStyle(.plain)
                    }
                    // 录音中：实时转写
                    if speechCtl.isRecording {
                        Label(speechCtl.transcript.isEmpty ? "请说出这笔花销，如「午饭花了十五块」…" : speechCtl.transcript,
                              systemImage: "waveform")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if let error = speechCtl.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                Section("🏷️ 分类") {
                    // 6 分类宫格（3 列）
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(LedgerCategory.all, id: \.self) { name in
                            Button {
                                category = name
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: LedgerCategory.icons[name] ?? "ellipsis.circle")
                                        .font(.body)
                                    Text(name)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(category == name ? Color.indigo.opacity(0.18) : Color.indigo.opacity(0.06))
                                .foregroundColor(category == name ? .indigo : .primary)
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("备注（可选，如 食堂午饭）", text: $note)
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Text("记下这一笔")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.indigo)
                    }
                }
            }
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            // 停止录音后解析口语句，自动填金额/分类/备注
            .onChange(of: speechCtl.isRecording) { recording in
                if !recording {
                    applySpeech(speechCtl.transcript)
                }
            }
            .onDisappear {
                speechCtl.teardown()
            }
        }
    }

    /// 口语句 → 表单预填
    private func applySpeech(_ text: String) {
        guard !text.isEmpty, let parsed = LedgerNLParser.parse(text) else { return }
        // 金额：整数不带小数位，带小数保留
        amountText = parsed.amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(parsed.amount))
            : String(format: "%.2f", parsed.amount)
        category = parsed.category
        if let parsedNote = parsed.note, note.isEmpty {
            note = parsedNote
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func save() {
        // 金额解析：支持 "12" / "12.5" / "12,5"（手滑逗号）
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount > 0 else { return }
        dataManager.addLedgerEntry(LedgerEntry(
            amount: amount,
            category: category,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        ))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }
}
