<p align="center">
  <img src="assets/icon/app_icon.png" width="128" alt="沁音图标">
</p>

# 沁音（汽水音乐第三方游客态客户端）

非官方第三方 Flutter 客户端，**游客态浏览 + 播放**：无需登录、无自建后端，直连汽水音乐（Luna）游客接口（`beta-luna.douyin.com`），接口整理自官方 App/EXE 逆向文档。全局原生 Material 3 设计，种子色为汽水系清新黄绿，播放页按封面主色染色。

> 图标说明：当前图标为模板图标改色（黄绿）占位，正式图标待出图后替换。

## 功能

- **首页发现流**：推荐电台横滑、推荐歌单（discover + discover/mix，带加载更多）、「随便听听」；下拉刷新
- **新鲜模式播放页（移动端）**：整页一首歌——大封面、当前歌词行、收藏/评论/分享真实计数（seo stats）、细进度条、底部三键（发现/大暂停/我的）；**上下滑切歌**（纵向 PageView 承载队列，上滑下一首、下滑上一首，与按钮切歌、播完自动推进共用同一套队列推进逻辑）；点封面进全量歌词页（滚动+当前行高亮）；评论只读展示
- **桌面播放页（≥900）**：左封面（歌名/歌手/计数）+ 右歌词列（顶部制作信息：作曲/作词/编曲/制作），底部通栏播放条右端含 词/循环模式/队列/音量
- **本地队列（照官方模型）**：来源点播即建队列；LIST 列表循环 / SHUFFLE 随机（带历史回退）/ SINGLE 单曲循环三模式；歌单分页 cursor 续拉追加；下一首预取（seo 预解析，失败静默）
- **播放解析**：h5/seo_track 一发全齐（播放直链+歌词+评论+相关列表）；按设置音质 medium/higher/highest 选档、缺档就近回落、按 expire_at 缓存过期重拉、main_url 失败回落 backup_url
- **详情页**：歌单（分页续拉）/专辑/歌手（热门歌曲+热门专辑），沉浸头部、播放全部、正在播放高亮
- **我的**：本地收藏（歌曲/歌单/专辑）、自建歌单（建/删/加歌/移除）、历史播放、续播进度
- **下载**：流式下载当前音质直链落盘 `.m4a` 不转码；下载前强制重解析（链接 24h 过期）；文件名模板（默认 `{artist} - {title}`，非法字符清洗+同名追加序号）；多选删除；M4A 不写元数据标签（如实标注）
- **搜索**：输入联想（sug）+ 搜索历史（见下方游客限制）
- **设置**：默认音质、下载目录、文件名模板、主题（动态取色/深浅色/种子预设）、关于（运行时版本号）

## 游客限制（实测，如实说明）

- **无全文搜索**：游客搜索结果被服务端掏空，搜索页只做联想词 + 本地历史，点联想词给诚实提示，不假装出结果
- **音质仅三档 AAC**：medium ≈66k / higher ≈130k / highest ≈258k（逐曲下发，个别曲目无 highest）；无损/Hi-Res/空间音频游客从不下发
- **新鲜模式官方 Feed 不可用**（游客被挡）：以本地队列 + 上下滑 + 预取实现同等形态
- **无云功能**：无账号、无关注、无发评论（评论只读）、无云端同步；收藏/歌单/历史均为本地 SharedPreferences
- **受限曲目**：seo 无播放流时明确拒绝并提示，不提供试听拼接

## 接口与解析要点（抓真实样本实测）

- 封面拼装：`{urls[0]}{uri}~{template_prefix}-image.image`（列表小图用 `-15.webp` 变体），实测均可打开
- 歌词为 KRC 逐字格式：`[startMs,durMs]<off,dur,flag>字…`，解析时剥逐字标签留纯文本行；兼容普通 LRC
- POST `/luna/*` 用 App UA `Luna/19.1.0 Android` + JSON；GET 用 Web UA；无 Cookie、无签名头

## 构建与发布

- 版本线 0.1 起（pubspec `0.1.0+1`）；CI 由 tag 解析 `--build-name`（补齐三段）+ `--build-number=run_number`
- Android 固定签名：keystore 材料在仓库外，四个变量 `ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD / ANDROID_KEY_ALIAS` 只进 GitHub Secrets；未配置时 CI 临时自签
- `flutter analyze` + `flutter test`（fixture 为真实响应裁剪：discover/discover_mix/playlist/seo_track）
