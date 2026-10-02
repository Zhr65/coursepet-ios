# 计划：RAG 课件知识库 + 语音对话管家

## Context

用户认为现有功能（课表/专注/快递）偏浅，缺少"硬核"功能点。已选定两个新功能：
1. **RAG 课件知识库（文件级）**：iOS 选文件（PDF/TXT/DOCX/PPTX）→ 服务器抽文本+分块+嵌入+pgvector → 现有 `search_course_materials` 工具自然召回 → Agent 回答可引用课件原文；端侧模式降级（PDF/TXT 本机解析，DOCX/PPTX 提示需服务器模式）。
2. **语音对话管家**：聊天页语音输入（STT）+ 朗读 AI 回复（TTS）。

现有基础：后端已有 `/sync/docs`（纯文本单行入库）、`embed()` 256 维哈希嵌入、`search_course_materials` 工具；iOS 已有 `AgentDocStore`（端侧 RAG）、`AgentRemoteClient`（JWT/401 重试）、`SpeechLedgerController`（SFSpeechRecognizer+AVAudioEngine，权限申请齐全）、Info.plist 已含麦克风+语音识别权限描述。

---

## 功能 A：RAG 课件知识库

### 后端（v2-backend/coursepet-api/）

**1. 新文件 `app/agent/doc_parser.py`**
- `extract_text(filename, data) -> str`：按小写扩展名分派 —— `.pdf`→pypdf 逐页 extract_text；`.txt`→utf-8 失败再试 gbk；`.docx`→python-docx；`.pptx`→python-pptx 逐 shape text_frame；失败 raise ValueError。
- `chunk_text(text, size=500, overlap=80) -> list[str]`：先清洗（`\r\n`→`\n`、删 `\x00`（PG 不接受 NUL 字节）与零宽字符、合并连续空行）→ 滑窗，在 `[250, 500]` 区间内向后找最后一个 `。！？\n；` 切点（找不到硬切），下一起点 = 切点−overlap，末块 <30 字并入前块；文本上限 60,000 字、chunks 上限 40（标记 truncated）。
- 中文长度直接用 `len()`（码点数）。

**2. `app/models.py` CourseDoc 加两列**（`startup` 里照 parcels.tracking_no 先例追加 `ALTER TABLE course_docs ADD COLUMN IF NOT EXISTS source_file VARCHAR(200)` / `chunk_index INTEGER`）：
- `source_file: str | None`（NULL=聊天存的散条）
- `chunk_index: int | None`

**3. `app/main.py` 新端点 4 个**（用 `def` 同步风格，解析走 FastAPI 线程池；需 import `File, UploadFile, Query`；schemas.py 不动）：
- `POST /sync/docs/file`：`file: UploadFile = File(...)` + `name: str = Query("", max_length=120)`（中文显示名走 query，multipart header 只放 ASCII 文件名）；校验 ≤8MB + 扩展名白名单；返回 `{"ok", "file", "chunks", "truncated"}`
- `GET /sync/docs/files`：group_by(source_file) 聚合文件组 + 散条列表
- `DELETE /sync/docs/file?name=...`：删该用户此文件全部块
- `DELETE /sync/docs/{doc_id}`：删散条（越权 404）

**4. `app/agent/tools.py` `_search_course_materials` 微调**：`limit(3)`→`limit(6)` 后按 source_file 去重（每文件只留最近一块，最多 3 个文件，防单个 40 块 PDF 刷屏）；展示标签带出处 `【文件名·第n段】`；description 补一句"资料库支持整份课件文件"。

**5. `requirements.txt` 增**：`python-multipart`（UploadFile 硬依赖）、`pypdf`、`python-docx`、`python-pptx`（全纯 Python）。

### iOS（ios/CoursePet/）

**6. 新文件 `Agent/AgentDocParser.swift`**（端侧降级）：
- `extractText(from url) throws -> String`：PDF 用 PDFKit 逐页 `page.string`（总字符<20 且有页数 → throw scannedPDF"扫描版无法提取"）；TXT 直读；DOCX/PPTX throw unsupportedFormat。
- `chunk(_:size:overlap:) -> [(index, text)]`：与 Python 版对齐，按 Character 切。

**7. `Agent/AgentRemoteClient.swift`**：`ensureToken`、`trimmedBase` 去掉 `private`（token 缓存复用）。

**8. 新文件 `Agent/AgentLibraryClient.swift`**：`uploadDocFile`（手动拼 multipart body，boundary=coursepet+UUID，filename 只放 ASCII `upload_<ts>.<ext>`，中文显示名走 query；用 `URLSession.upload`；401 清缓存重登重发一次，对齐 chat() 模式）、`listDocFiles`、`deleteDocFile`、`deleteLooseDoc`。

**9. `Agent/AgentDocs.swift`**：`AgentDocStore` 加 `remove(id:)`（3 行）；端侧文件块 title 编码出处 `"\(文件名)·第n段"`。

**10. 新文件 `Agent/CourseLibraryView.swift`**：`presentedAsSheet` 参数区分呈现；onAppear 按 `AgentConfigStore.loadServerConfig().isConfigured` 分流（服务器拉列表 / 端侧 loadAll）；`fileImporter` 服务器模式 `[.pdf, .plainText] + UTType("org.openxmlformats.wordprocessingml.document") + UTType("org.openxmlformats.presentationml.presentation")`（compactMap 防 nil 崩），端侧仅 `[.pdf, .plainText]`；导入流程 startAccessingSecurityScopedResource → 上传或本机解析分块入库；文件组 swipeActions 删除；上传中 loading + 状态文案；footer 说明"重装 App 会清空端侧资料，服务器资料不受影响"。

**11. 两处入口**：AgentChatView toolbar 加书本图标（sheet）+ SettingsView「🤖 AI 管家」Section 加 NavigationLink（副标题"课件文件入库，AI 答题可引用"）。

---

## 功能 B：语音对话管家

**12. `Support/SpeechLedger.swift` 零改动**，直接复用 `SpeechLedgerController`。

**13. 新文件 `Agent/AgentSpeech.swift`**：`@MainActor final class AgentSpeech: ObservableObject`，单例 `shared`。
- `@Published speakingMessageID: String?`（驱动气泡按钮状态）
- `toggle(id, text)` / `stop()` / `speakIfNeeded(id, text, suppressed)`（suppressed=录音中 → 跳过）
- AVSpeechSynthesizer + zh-CN voice；speak 前 `setCategory(.playback, options:.duckOthers)`；delegate didFinish/didCancel 里 `setActive(false, .notifyOthersOnDeactivation)`（异步回调里做，不抢同步时序）；无需新权限。
- `isAutoSpeak`：UserDefaults `"agent.autoSpeak"`，默认关。

**14. `Agent/AgentChatView.swift` 三处**：
- `@StateObject speech = SpeechLedgerController()`；`onChange(of: speech.transcript)` 实时填输入框（保留已输入文字作前缀）；停止录音后聚焦输入框。
- inputBar 左侧加麦克风按钮（录音前先 `AgentSpeech.shared.stop()`；录音中 mic.fill 红色）；`speech.errorMessage` 显示在输入条上方。
- assistant 气泡尾部加朗读小按钮（`speaker.wave.2` ↔ `stop.circle.fill`，caption2 secondary）；现有 `onChange(of: displayMessages.count)` 里追加 `speakIfNeeded`（suppressed: speech.isRecording）。
- `onDisappear` 调 `speech.teardown()`。

**15. 设置页**：AI 管家二级页（SettingsView.swift ~L604）加 `Toggle("自动朗读 AI 回复")` 绑定 `AgentSpeech.shared.isAutoSpeak`。

---

## 关键决策

| 决策点 | 结论 |
|---|---|
| 录音后发送方式 | **手动发送**：中文长句识别易错 + Agent 有写操作（记账/作业/快递）发错难撤；停止后自动聚焦输入框便于修改 |
| 自动朗读默认 | **关**：图书馆/上课外放是负体验，设置页手动开 |
| 资料库入口 | 聊天页 toolbar + 设置页各一处，同一 View 复用 |
| 扫描版 PDF | 两端诚实降级提示"无法提取文字"，绝不静默入库空块 |

## 实现顺序与验证

1. **后端** doc_parser.py + models 迁移 + 4 端点 + tools 微调 + requirements → 本地 uvicorn 起服务，curl 全链路：中文 txt（600+ 字）`curl -F "file=@t.txt;filename=upload1.txt" ".../sync/docs/file?name=测试"` 期望 chunks≥2 → GET files → `/agent/chat` 问文中关键词验证引用出处 → 两个 DELETE。
2. **部署 VM**（`ssh -i C:\Users\zhr15\.ssh\coursepet_vm zhr@192.168.201.135`）：scp 新/改 py → `/opt/coursepet-env/bin/pip install -r requirements.txt` → `sudo systemctl restart coursepet-api` → curl `/health` + 复跑线上 curl。
3. **iOS 端侧解析**（AgentDocParser + AgentDocs.remove）+ **网络层**（RemoteClient 可见性 + AgentLibraryClient）→ Codemagic 编译验证。
4. **CourseLibraryView + 两入口** → Appetize 验证上传 txt/列表/删除/两种模式分流。
5. **语音**（AgentSpeech + AgentChatView + 设置开关）→ Codemagic 编译 + Appetize 验 UI；**STT/TTS 必须真机**（Appetize 无麦克风，AltStore 真机装）。
6. 全部完成后 commit + push（中文 commit message）。

## 风险点

- UTType 无 `.docx/.pptx` 预定义常量，须 `UTType("org.openxmlformats...")` 动态构造 + compactMap 兜底。
- multipart header 中文文件名会乱码 → ASCII filename + query 传显示名（已内置方案）。
- PDF/DOCX 抽出文本可能含 `\x00`，psycopg2 插入报错 → 清洗步骤强制删 NUL。
- AVAudioSession 录音(.record)与朗读(.playback)互斥 → 点麦克风先 stop 朗读、朗读结束在异步 delegate 里释放会话、录音中不自动朗读。
- 端侧 AgentDocStore 100 条上限会被大文件挤占 → 端侧按剩余容量截断并提示走服务器模式。
