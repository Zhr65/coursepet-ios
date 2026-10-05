// MARK: - 宠物形象目录
// 所有形象自由切换（无等级 / 累计专注 / 连续打卡门槛）。
// 形象页默认只展示前 featuredCount 个主打形象，其余全部收在「形象仓库」里选。
// 帧图来源：App Bundle AppPetAssets/{charId}/，由 PetAssetInstaller 启动时装入 App Group。
import Foundation

struct PetCharacter: Identifiable {
    let id: String
    let name: String
}

enum PetCatalog {
    /// 形象页默认展示的主打形象数量（其余进「形象仓库」）
    static let featuredCount = 3

    /// 全部形象。新增形象直接往后追加即可（超出的自动落进形象仓库）
    /// char10~15 目前只提供一张静态图（pet_idle_0.png），由 PetFrameLocator 兜底到所有动作
    static let all: [PetCharacter] = [
        .init(id: "char1", name: "小狼"),
        .init(id: "char2", name: "猪护士"),
        .init(id: "char3", name: "小青蛙"),
        .init(id: "char4", name: "小猫咪"),
        .init(id: "char5", name: "炸毛猫"),
        .init(id: "char6", name: "刘海狗"),
        .init(id: "char7", name: "蛋壳鸡"),
        .init(id: "char8", name: "榴莲刺猬"),
        .init(id: "char9", name: "小黑驴"),
        .init(id: "char10", name: "斗篷牛"),
        .init(id: "char11", name: "眼镜仓鼠"),
        .init(id: "char12", name: "拳击猫"),
        .init(id: "char13", name: "天使鼠"),
        .init(id: "char14", name: "工程猪"),
        .init(id: "char15", name: "爱心狗"),
    ]

    /// 形象页默认展示的主打形象
    static var featured: [PetCharacter] { Array(all.prefix(featuredCount)) }

    /// 形象仓库：主打之外的全部形象
    static var warehouse: [PetCharacter] { Array(all.dropFirst(featuredCount)) }

    static func character(id: String) -> PetCharacter? {
        return all.first { $0.id == id }
    }
}