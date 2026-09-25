// MARK: - 事务页两个分区：快递取件 + 极简记账
// 由 TodoView（事务页）的分段控件挂载，共享同一套玻璃列表风格。
import SwiftUI

// ════════════════════════════════════════════════════════════
// 快递取件
// ════════════════════════════════════════════════════════════
struct ParcelSection: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showAdd = false

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
            AddParcelView()
        }
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
                if days >= 3 {
                    Text("已入库 \(days) 天")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text(days == 0 ? "今天到的" : "\(days) 天前到")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
}

// MARK: - 添加快递弹层
private struct AddParcelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    @State private var code = ""
    @State private var station = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("📦 快递信息") {
                    TextField("取件码（必填，如 3-2-5088）", text: $code)
                        .autocorrectionDisabled()
                    TextField("驿站 / 位置（如 菜鸟驿站·东门）", text: $station)
                    TextField("备注（可选，如 顺丰·是书）", text: $note)
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
        }
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
        }
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
