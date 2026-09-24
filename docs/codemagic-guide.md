# Codemagic 构建指南（无 Mac 安装到 iPhone）

## 流程总览

```
GitHub 推送代码
    ↓
Codemagic 云端 Mac 自动构建
    ↓
下载 IPA 文件
    ↓
AltStore 安装到 iPhone
    ↓
每周重签（免费 Apple ID 需要）
```

---

## 第一步：创建 GitHub 仓库

```bash
cd d:\AI\CoursePet
git init
git add .
git commit -m "CoursePet iOS 项目"
git branch -M main
git remote add origin https://github.com/你的用户名/coursepet-ios.git
git push -u origin main
```

> 如果没有 GitHub 账号，注册一个：https://github.com/signup

---

## 第二步：注册 Codemagic

1. 访问 https://codemagic.io
2. 用 GitHub 账号登录
3. 点击 **Add application** → 选择刚才的 coursepet-ios 仓库
4. 等待仓库被导入

---

## 第三步：配置签名证书（关键步骤）

### 3.1 获取 Apple 开发者证书（免费 Apple ID 也可以）

在 Codemagic 中：
1. 进入项目 → **Settings** → **Security** → **Key Chains**
2. 点击 **Add key chain**
3. 选择 **Generate a new certificate**（免费 Apple ID 选这个）
   - 或者 **Upload your certificate**（如果你有付费开发者账号的 .p12 证书）
4. 输入你的 Apple ID 邮箱和密码
5. Codemagic 会自动生成测试用证书

### 3.2 配置 App Groups

1. **Settings** → **Environment variables**
2. 添加以下变量：
   - `APPLE_DEVELOPER_TEAM_ID`：你的 Team ID（免费账号可在 https://developer.apple.com/account 查看）
   - `APPLE_ID_USERNAME`：你的 Apple ID 邮箱
   - `APPLE_ID_PASSWORD`：你的 Apple ID 密码（或应用专用密码）

---

## 第四步：修改配置并推送

### 4.1 修改 codemagic.yaml

打开 `codemagic.yaml`，找到以下地方替换：

```yaml
# 替换为你的邮箱
- your_email@example.com
# 替换为你的 Bundle ID
BUNDLE_ID: "com.coursepet.app"  # 建议改为 com.你的名字.coursepet
```

### 4.2 推送代码

```bash
git add codemagic.yaml export.plist
git commit -m "添加 Codemagic 配置"
git push
```

---

## 第五步：触发构建

1. 回到 Codemagic 网页
2. 点击 **Manual build** → **Build**
3. 等待约 10-15 分钟（首次构建）
4. 构建完成后下载 `.ipa` 文件

---

## 第六步：安装到 iPhone

### 6.1 安装 AltStore（Windows 版）

1. 下载 AltStore：https://altdre.store
2. 解压后运行 AltServer.exe（需要安装 Microsoft Visual C++ 运行时）
3. 用 USB 线连接 iPhone 和电脑
4. AltServer 会自动检测设备并注入 AltStore 到 iPhone

### 6.2 安装 CoursePet IPA

1. 在 iPhone 上打开 AltStore App
2. 点击 **Install .ipa**
3. 选择从电脑上下载的 CoursePet.ipa（通过 iTunes/Finder 文件传输，或用 AltStore 的网页上传）
4. 输入 Apple ID 密码授权安装

### 6.3 每周重签（重要！）

免费 Apple ID 安装的 App **7 天后会过期**，需要：
1. 电脑和 iPhone 保持同一 WiFi
2. 用 USB 连接 iPhone
3. 打开 AltServer → 点击 **Refresh All**
4. 或者在 iPhone AltStore 里点击 App → Refresh

---

## 替代方案：使用付费开发者账号

如果你有年费 $99 的 Apple Developer 账号：
- App 签名有效期 1 年，无需每周重签
- 可发布到 App Store
- Codemagic 配置更简单（直接上传 .p12 证书）

---

## 常见问题

**Q: 构建失败 "App Group not found"**
A: 在 Codemagic Settings → App Groups 中勾选 `group.com.coursepet.app`

**Q: 签名失败 "Provisioning Profile not found"**
A: 检查 Apple ID 是否正确，或改用 `development` 类型的 provisioning profile

**Q: AltStore 找不到 iPhone**
A: 确保 iPhone 信任此电脑（设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID）

**Q: 灵动岛在模拟器上看不到**
A: 灵动岛需要真机（iPhone 14 Pro 及以上），模拟器无法测试

---

## 快速检查清单

- [ ] GitHub 仓库已创建并推送代码
- [ ] Codemagic 账号已注册并关联仓库
- [ ] Apple ID 已配置到 Codemagic Key Chains
- [ ] App Groups capability 已添加
- [ ] 构建成功并下载了 IPA
- [ ] AltServer 已安装到电脑
- [ ] AltStore 已安装到 iPhone
- [ ] IPA 已成功安装到 iPhone
