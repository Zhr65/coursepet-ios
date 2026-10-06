// MARK: - 宠物面板（Muse 式三页签：形象 / 活动 / 连接）
// 聊天页顶部悬浮形象点击弹出。形象页=大图+改名+主打形象网格+形象仓库二级页；
// 活动页=Agent 干过什么的时间线（ActivityTimelineList）；连接页=系统能力授权中心（ConnectorsView）。
// 形象全部自由切换，无等级 / 累计专注 / 连续打卡解锁门槛。
import SwiftUI

struct PetAvatarSheet: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renameTip = ""
    @State private var tab = 0   // 0 形象 1 活动 2 连接

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    /// 显式空初始化器：private @State 会让合成的成员初始化器变 private，跨文件调用不保险
    init() { }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 当前形象大图（立体微动画，换形象立即变化）——恒显示，是面板的"头"
                    VStack(spacing: 6) {
                        PetModelView(
                            action: "idle",
                            charId: dataManager.charId,
                            speed: dataManager.animSpeed,
                            size: 120,
                            threeDEffect: true
                        )
                        .id("avatar-sheet-\(dataManager.charId)-\(dataManager.animSpeed)")
                        Text(dataManager.petName)
                            .font(.headline)
                        Text("Lv.\(dataManager.petLevel) · 使用中")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 12)

                    // 页签：形象 / 活动 / 连接（Muse 的图标页签同位）
                    Picker("页签", selection: $tab) {
                        Text("形象").tag(0)
                        Text("活动").tag(1)
                        Text("连接").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    switch tab {
                    case 0:
                        avatarTab
                    case 1:
                        activityTab
                    default:
                        ConnectorsView()
                    }
                }
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("虚拟形象")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { newName = dataManager.petName }
        }
    }

    // MARK: 形象页签（改名 + 主打形象网格 + 形象仓库入口）
    @ViewBuilder
    private var avatarTab: some View {
        VStack(spacing: 18) {
            // 编辑名称（Muse "编辑名称"同款）
            VStack(alignment: .leading, spacing: 6) {
                Text("名字").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("宠物名字", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("改名") { rename() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !renameTip.isEmpty {
                    Text(renameTip).font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)

            // 动画速度（从设置页迁移过来：形象/名字/速度一站式管理）
            VStack(alignment: .leading, spacing: 6) {
                Text("动画速度").font(.caption).foregroundColor(.secondary)
                Picker("动画速度", selection: Binding(
                    get: { dataManager.animSpeed },
                    set: { newValue in
                        dataManager.animSpeed = newValue
                        dataManager.savePublishedState()
                    }
                )) {
                    Text("🐢 慢").tag(AppSettings.AnimSpeed.slow)
                    Text("🐾 中").tag(AppSettings.AnimSpeed.mid)
                    Text("⚡ 快").tag(AppSettings.AnimSpeed.fast)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)

            // 桌面图标跟随形象：切换形象时同步换 App 图标（AppIconSync）
            VStack(alignment: .leading, spacing: 6) {
                Toggle("桌面图标跟随形象", isOn: Binding(
                    get: { AppIconSync.isEnabled },
                    set: { newValue in
                        AppIconSync.isEnabled = newValue
                        // 重新打开时立即对齐当前形象：修"关→切形象→再开"
                        // 后图标停在旧形象的窗口（否则要等下次切形象才自愈）
                        if newValue { AppIconSync.sync(charId: dataManager.charId) }
                    }
                ))
                Text("换形象时桌面图标一起换，系统会弹一次「图标已更改」确认框")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            // 主打形象网格：默认只放前 featuredCount 个，全部可直接切换；
            // 末尾一格是形象仓库入口，剩下的形象都在二级页里
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PetCatalog.featured) { ch in
                    AvatarCell(char: ch, isSelected: dataManager.charId == ch.id) {
                        selectAvatar(ch)
                    }
                }
                if !PetCatalog.warehouse.isEmpty {
                    NavigationLink {
                        AvatarWarehouseView()
                    } label: {
                        warehouseTile
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 形象仓库入口瓦片（与形象格子同尺寸）
    private var warehouseTile: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.12))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.indigo)
            }
            .frame(width: 60, height: 60)
            Text("形象仓库")
                .font(.caption2)
                .foregroundColor(.primary)
            Text("\(PetCatalog.warehouse.count) 个形象")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }

    // MARK: 活动页签（时间线）
    private var activityTab: some View {
        ActivityTimelineList()
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let old = dataManager.petName
        dataManager.petName = String(trimmed.prefix(12))
        dataManager.savePublishedState()
        renameTip = "已改名为 \(dataManager.petName)"
        // 改名也是它生活里的一件事：记进活动时间线（名字真变了才记）
        if dataManager.petName != old {
            ActivityTimelineStore.record(icon: "pencil", title: "改名为「\(dataManager.petName)」")
        }
    }
}

// MARK: - 形象格子（形象页与形象仓库共用）
private struct AvatarCell: View {
    let char: PetCharacter
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Group {
                    if let img = SettingsView.shopPreviewImage(char.id) {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
                .frame(width: 60, height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2.5)
                )
                Text(char.name)
                    .font(.caption2)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundColor(.primary)
                Text(isSelected ? "使用中" : " ")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .indigo : .secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.indigo.opacity(0.10) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 形象仓库（主打之外的全部形象，自由切换）
private struct AvatarWarehouseView: View {
    @ObservedObject private var dataManager = DataManager.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PetCatalog.warehouse) { ch in
                    AvatarCell(char: ch, isSelected: dataManager.charId == ch.id) {
                        selectAvatar(ch)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("形象仓库")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 切换形象：写 charId + 持久化 + 同步桌面图标（形象页与仓库共用）
private func selectAvatar(_ ch: PetCharacter) {
    DataManager.shared.charId = ch.id
    DataManager.shared.savePublishedState()
    AppIconSync.sync(charId: ch.id)
}