<p align="center">
  <img src="assets/icon/app_icon.png" width="128" alt="沁音图标">
</p>

# 沁音（汽水音乐第三方游客态客户端）

非官方第三方 Flutter 客户端，**游客态浏览 + 播放**：无需登录、无自建后端，直连汽水音乐（Luna）游客接口（`beta-luna.douyin.com`）与车机开放平台通道（`open.douyin.com`），接口整理自官方 App/EXE 逆向文档。全局原生 Material 3 设计，种子色为汽水系清新黄绿，播放页按封面主色染色。

> 图标说明：正式 logo 为原创设计——黄绿渐变（汽水）底 + 白色八分音符（圆润气泡符头）配上升小气泡，呼应「沁」的水意与汽水感；由 `assets/icon/generate_icon.py` 以 PIL 超采样绘制生成，全平台图标同源。

## 功能

- **首页发现流**：推荐电台横滑、推荐歌单（discover + discover/mix，带加载更多）、「随便听听」；下拉刷新
- **推荐页**：页面本体即新鲜模式播放形态——官方推荐流本体（车机开放平台通道，游客未个性化版）直接建队列，大封面 + 实际音质芯片 + 一行歌词 + 只读互动计数 + 下一首露出条，**上下滑切歌**无限刷（与播放页共用同一套滑动分页与队列推进组件），播到队尾自动续拉；平台通道异常时自动回退组合源（相关歌曲 + 发现歌单 + 电台）；若有其他来源的歌正在播，进页不抢队列、先提示再由你点「开始刷推荐」接管
- **新鲜模式播放页（移动端）**：整页一首歌——大封面、当前歌词行、收藏/评论/分享真实计数（seo stats）、细进度条、底部三键（发现/大暂停/我的）；**上下滑切歌**（纵向 PageView 承载队列，上滑下一首、下滑上一首，与按钮切歌、播完自动推进共用同一套队列推进逻辑）；点封面进全量歌词页（滚动+当前行高亮）；评论只读展示
- **桌面播放页（≥900）**：左封面（歌名/歌手/计数）+ 右歌词列（顶部制作信息：作曲/作词/编曲/制作），底部通栏播放条右端含 词/循环模式/队列/音量
- **本地队列（照官方模型）**：来源点播即建队列；LIST 列表循环 / SHUFFLE 随机（带历史回退）/ SINGLE 单曲循环三模式；歌单分页 cursor 续拉追加；下一首预取（seo 预解析，失败静默）
- **播放解析**：h5/seo_track 一发全齐（播放直链+歌词+评论+相关列表）；按设置音质 medium/higher/highest 选档、缺档就近回落、按 expire_at 缓存过期重拉、main_url 失败回落 backup_url
- **无损播放与下载（spade 解密）**：设置音质选「无损」时，推荐流中带整曲版参数的曲目（约 1/3）可走平台内嵌的加密无损档（FLAC 835k–1.7M，CENC 加密）：整曲下载加密体后本地解密（spade 算法已逆向并与参考实现整曲对拍一致）成裸 FLAC 再播放/落盘；解密产物按歌曲缓存在临时目录（上限 512MB、最久未用先淘汰），重播免重复解密；无无损的曲目或解密失败（仅播放时）自动回落 AAC 最高可用档；播放页芯片显示的是实际在播档位，不按设置虚报
- **详情页**：歌单（分页续拉）/专辑/歌手（热门歌曲+热门专辑），沉浸头部、播放全部、正在播放高亮
- **我的**：本地收藏（歌曲/歌单/专辑）、自建歌单（建/删/加歌/移除）、历史播放、续播进度
- **下载**：流式下载当前音质直链落盘 `.m4a` 不转码；音质设为无损且曲目带无损档时，解密后落盘 `.flac`（与播放共用同一条解密链，下载管理里按 FLAC 标注）；下载前强制重解析（链接 24h 过期）；文件名模板（默认 `{artist} - {title}`，非法字符清洗+同名追加序号）；多选删除；M4A（MP4 ilst）与 FLAC（Vorbis Comment + 封面块）落盘后均写元数据标签（标题/歌手/专辑/发行日期/歌词〔seo 歌词压成行级 LRC 写入，无歌词则跳过〕/封面；从专辑页下载时另写音轨号〔曲序/总数〕，其他来源不写），下载管理按每条记录的实际结果标注「已写标签 / 未写标签 / 标签写入失败」（写失败保留原文件、不算下载失败）
- **搜索**：输入联想（sug）+ 搜索历史 + **全文搜索结果**（车机开放平台通道，游客可用）：歌曲（无限滚动分页、点播建队列并续拉）、歌手（跳歌手页）、歌单（跳歌单详情）三页签
- **设置**：默认音质、下载目录、文件名模板、主题（动态取色/深浅色/种子预设）、关于（运行时版本号）

## 游客限制（实测，如实说明）

- **搜索的通道差异**：App 本体搜索（beta-luna）游客结果被服务端掏空，所以搜索页走车机开放平台通道（同推荐流一条路）；歌曲/歌手实测有真实结果，**歌单搜索游客态上游当前恒回空**（接口通、err_no=0 但结果组为空），歌单页签会如实显示无结果
- **音质上限**：seo 通道仅三档 AAC（medium ≈66k / higher ≈130k / highest ≈258k，逐曲下发，个别曲目无 highest）；无损 FLAC 只存在于推荐流条目的加密档（约 1/3 曲目，需本地解密，见功能一节），不是全曲库可用；Hi-Res/空间音频游客从不下发
- **推荐流为游客未个性化版**：App 本体 feed（feed/song-tab）游客被设备门挡；推荐页改走车机开放平台通道取同一条官方流，官方自述「登录后推荐更准」——游客版内容真实但不带个人画像
- **无云功能**：无账号、无关注、无发评论（评论只读）、无云端同步；收藏/歌单/历史均为本地 SharedPreferences
- **播放直链 24 小时过期**：签名链接由服务端签发、有效期约 24h；播放按 `expire_at` 缓存自动重拉，下载前强制重解析，本地已下载文件不受影响
- **iOS 包未签名**：Release 的 IPA 为未签名包，不能直接安装，需自行签名（如 AltStore / SideStore / 企业签等）后使用
- **受限曲目**：seo 无播放流时明确拒绝并提示，不提供试听拼接

## 接口与解析要点（抓真实样本实测）

- 封面拼装：`{urls[0]}{uri}~{template_prefix}-image.image`（列表小图用 `-15.webp` 变体），实测均可打开
- 歌词为 KRC 逐字格式：`[startMs,durMs]<off,dur,flag>字…`，解析时剥逐字标签留纯文本行；兼容普通 LRC
- POST `/luna/*` 用 App UA `Luna/19.1.0 Android` + JSON；GET 用 Web UA；无 Cookie、无签名头
- 平台搜索走同一车机通道：POST `open.douyin.com/api/luna/v1/platform/search/`（公共参数 + `search_id` 会话内固定、cursor 按上游 `next_cursor` 推进）；客户端令牌端点（open.qishui.com `client/token/get/`）的 `client_token` 在响应**顶层**，尽力取、取不到不阻塞，err_no 28001008（令牌过期）时刷新重试一次；歌单详情不走平台（平台 detail 对 App 侧歌单 id 回 28001035 记录不存在），仍用 App 侧 `/luna/playlist/detail`
- 官方推荐流走车机开放平台：GET `open.douyin.com/api/luna/v1/platform/feed/song-tab/`，UA `LunaOpenSDK/1.0.10` + 车机 SDK 公共参数 + 自造 device_id（首启随机生成、持久化复用），offset cursor 分页；其内嵌的 GetPlayInfo 直链（A 路）只下发 medium 一档，但整曲版条目另内嵌完整 video_model（B 路），四档齐全且无损档为 spade CENC 加密 FLAC——无损播放/下载即走 B 路 + 本地解密，AAC 播放仍走 seo 三档
- spade 解密：spade_a 经字节变换得 AES-128 key，解析 MP4 的 senc 逐样本 IV 做 AES-CTR 解密，含 dfLa 则重组为裸 FLAC；Dart 实现已与第三方 JS 参考实现用真实曲目整曲对拍（SHA-256 逐字节一致）

## 下载与安装

到 [Releases](https://github.com/fansa91/qinyin/releases) 下载对应平台的包（`<版本>` 为三段版本号，v0.1 发布即 `0.1.0`）：

| 平台 | 资产 | 说明 |
|---|---|---|
| Android | `qinyin-<版本>-android-arm64-v8a.apk`（主流机型选这个）/ `qinyin-<版本>-android-armeabi-v7a.apk` / `qinyin-<版本>-android-x86_64.apk` | 分架构 APK，直接安装 |
| iOS | `qinyin-<版本>-ios-unsigned.ipa` | **未签名**，需自行签名后安装（见游客限制一节） |
| macOS | `qinyin-<版本>-macos.dmg` | 桌面资产版本号沿用 tag 原文（如 `qinyin-0.1-macos.dmg`） |
| Windows | `qinyin-<版本>-windows-x64.zip` | 解压即用；版本号同上（如 `qinyin-0.1-windows-x64.zip`） |

## 构建与发布

- 版本线 0.1 起（pubspec `0.1.0+1`）；推 `v*` tag 触发 CI：由 tag 解析 `--build-name`（补齐三段，如 `v0.1` → `0.1.0`）+ `--build-number=run_number`，四端构建后自动发 Release；移动端资产名用三段 `BUILD_NAME`，桌面资产用 tag 原文
- Android 固定签名：keystore 材料在仓库外，四个变量 `ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD / ANDROID_KEY_ALIAS` 只进 GitHub Secrets（值不入库）；未配置时 CI 每次临时自签，签名不一致将无法覆盖升级、需卸载重装
- `flutter analyze` + `flutter test`（fixture 为真实响应裁剪并脱敏（签名参数已替换）：discover/discover_mix/playlist/seo_track/platform_feed）
