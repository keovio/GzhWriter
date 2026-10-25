# 公众号写稿助手（GzhWriter）

一个 Mac 上的公众号写作工具：**AI 起草、真人审定、手动发布**。

> 设计上遵守《微信公众平台运营规范》3.27「非真人自动化创作行为」：选题、观点、大纲、改稿都由作者确认；
> 软件不登录、不操作公众号后台，不定时代发。排好版后一键复制，粘到公众号编辑器里自己发。

## 五步流程

1. **选题池**：自己记选题，或给个方向让 AI 列 10 个角度，挑中的「开写」
2. **大纲**：写下你的观点（必填），AI 围绕它出大纲，你改顺序、改字、增删
3. **正文**：逐节起草，任意一节可重写 / 扩写 / 精简 / 更口语，或直接说怎么改；AI 改动可撤销
4. **审稿**：标题、可读性、实用性、合规、人味五维打分，逐条建议点「采纳」才改；列出需要核实的事实；给 3 个备选标题
5. **排版**：4 套模板、6 种强调色、字号可调，手机宽度实时预览，「复制富文本」粘到公众号编辑器

## 模型

统一走 OpenAI 兼容接口，内置 DeepSeek、智谱 GLM、Kimi、通义千问、豆包预设，也可填任意 Base URL（中转站）。
「选题与大纲」「写正文」「审稿」可以分别指定模型，按顺序尝试，失败自动换下一个。

API Key 只存在 macOS 钥匙串；稿件存在 `~/Library/Application Support/GzhWriter/data.json`（每次保存留一份 `data.bak.json`）。

## 安装

在 [Releases](../../releases) 下载最新的 `GzhWriter.zip`，解压后把 `GzhWriter.app` 拖进「应用程序」。
首次打开若提示无法验证开发者，在终端运行：

```bash
xattr -cr /Applications/GzhWriter.app
```

## 自己编译

需要 Xcode 或 Command Line Tools（macOS 13+）：

```bash
./build.sh            # 生成 build/GzhWriter.app
./build.sh --install  # 编译并安装到「应用程序」
```

推送到 `main` 后 GitHub Actions 会自动编译通用版（Apple 芯片 + Intel）并发布 Release。
