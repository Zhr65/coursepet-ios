// MARK: - 宠物面板（Muse 式三页签：形象 / 活动 / 连接）
// 聊天页顶部悬浮形象点击弹出。形象页=大图+改名+九形象网格（复用 PetCatalog 解锁判定）；
// 活动页=Agent 干过什么的时间线（ActivityTimelineList）；连接页=系统能力授权中心（ConnectorsView）。
import SwiftUI

struct PetAvatarSheet: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renameTip = ""
    @State private var tab = 0   // 0 形象 1 活动 2 连接

    private var focusMinutes: Int { FocusStore.shared.totalSummary().totalMinutes }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    /// 显式空初始化器：private @State 会让合成的成员初始化器变 private，跨文件调用不保险
    init() { }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 当前形象大图（立体微动画，换形象立即变化）——恒显示，是面板的"头"
                    VStack(spacing: 6) {
                        PetAnimationView(
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

    // MARK: 形象页签（改名 + 九形象网格）
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

            // 形象网格（解锁可选 / 锁定灰色+条件）
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PetCatalog.all) { ch in
                    let unlocked = ch.isUnlocked(
                        level: dataManager.petLevel,
                        focusMinutes: focusMinutes,
                        streak: dataManager.getCheckInStreak())
                    let isSelected = dataManager.charId == ch.id
                    Button {
                        guard unlocked else { return }
                        dataManager.charId = ch.id
                        dataManager.savePublishedState()
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let img = SettingsView.shopPreviewImage(ch.id) {
                                        Image(uiImage: img).resizable().scaledToFit()
                                    } else {
                                        Color.gray.opacity(0.15)
                                    }
                                }
                                .frame(width: 60, height: 60)
                                .saturation(unlocked ? 1 : 0)
                                .opacity(unlocked ? 1 : 0.35)
                                if !unlocked {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Circle().fill(Color.black.opacity(0.55)))
                                        .offset(x: 4, y: -4)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2.5)
                            )
                            Text(ch.name)
                                .font(.caption2)
                                .fontWeight(isSelected ? .bold : .regular)
                                .foregroundColor(.primary)
                            Text(unlocked ? (isSelected ? "使用中" : " ") : ch.unlockText)
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
            .padding(.horizontal, 16)
        }
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
