# scripts — 字幕抓取与本地语音识别工具

这是本项目整理字幕时实际使用的通用工具链。核心思路：**平台有字幕就直接抓，接口返回异常内容或没有字幕时，就下载音频在本地做语音识别**——音频取自哪一集，转写结果就必然对应哪一集，从根本上绕开 B站 AI 字幕接口的串台问题。

支持 B站、YouTube 以及 yt-dlp 支持的其他 1000+ 站点。

## 一键使用

```bash
# 在仓库根目录执行
python3 -m yt_dlp --version >/dev/null || pip3 install --user yt-dlp
pip3 install --user sherpa-onnx          # 仅首次

# 抓一集（优先平台字幕，没有则本地识别）
./scripts/yt-sub.sh "https://www.bilibili.com/video/BV1L7411c7jw?p=3"

# 指定输出目录
./scripts/yt-sub.sh "<URL>" ./附加-物联网ESP8266/
```

输出三个文件：

| 文件 | 内容 |
|---|---|
| `<标题>.md` | 带来源信息的 Markdown 文稿 |
| `<标题>.txt` | 带 `[mm:ss]` 时间戳的分段原文 |
| `<标题>.srt` | 标准字幕文件 |

## 工作流程

```
视频 URL
   │
   ├─[1] 抓平台字幕（B站 ai-zh / YouTube 自动字幕）
   │       │
   │       └─有──> VTT/SRT 转文本 ──> 文稿          （几秒完成）
   │
   └─[2] 无字幕，或接口返回错误内容
           ├─ yt-dlp 下载音轨
           ├─ afconvert 转 16kHz 单声道 WAV
           └─ SenseVoice ONNX 本地识别 ──> 文稿 + SRT
```

**第 2 步全程离线**，音视频不会上传到任何服务器。30 分钟音频在 M 系列芯片上约 2 分钟转写完成。

## 为什么用 SenseVoice 替代 faster-whisper

上一版（MQTT 篇补 10 集时）用的是 `faster-whisper-small`，模型 483 MB 需要从 HuggingFace 下载。这一版改用 **SenseVoice**：

| 对比项 | faster-whisper small | SenseVoice（本版） |
|---|---|---|
| 模型大小 | 483 MB | 228 MB（int8 量化） |
| 中文效果 | 中规中矩 | 更好，专为中文优化 |
| 下载来源 | HuggingFace / hf-mirror | 已随 DSH 本地就位，无需额外下载 |
| 运行方式 | CTranslate2 | sherpa-onnx |

模型路径：`~/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx`（DSH 的语音输入功能也在用同一份模型）。

## 环境依赖

| 组件 | 安装方式 | 说明 |
|---|---|---|
| `yt-dlp` | `pip3 install --user yt-dlp` | 下载音频、抓字幕 |
| `sherpa-onnx` | `pip3 install --user sherpa-onnx` | 推理引擎 |
| SenseVoice 模型 | 已有 | 若缺失可从 [ModelScope](https://modelscope.cn/models/iic/SenseVoiceSmall) 获取 ONNX 版本 |
| `afconvert` | macOS 自带 | 音频转码，Linux 用 `ffmpeg` 替代 |

> ⚠️ **需要装在系统 Python 3.9**：DSH 自带的 Python 运行时对第三方原生扩展有签名校验，装 `sherpa-onnx` 会报 `different Team IDs`。用 `/usr/bin/python3` 即可。

## 代理

YouTube 需要代理，脚本默认用 `socks5h://127.0.0.1:1082`（Shadowrocket）。

```bash
# 自定义代理
YT_PROXY="http://127.0.0.1:7890" ./scripts/yt-sub.sh "<URL>"

# 直连（B站国内一般直连即可，建议这样跑 B站）
YT_PROXY="" ./scripts/yt-sub.sh "https://www.bilibili.com/video/BVxxxx"
```

直连 YouTube 会在下载到 10–30% 时出现 HTTP 403 中断，因为 CDN 限速严重；走代理后速度可稳定在 200 KB/s 以上。

## 文件说明

| 文件 | 作用 |
|---|---|
| `yt-sub.sh` | 主入口，串起整个流程 |
| `asr.py` | SenseVoice 识别：音频 → txt + srt，按 30 秒分块 |
| `vtt2txt.py` | 平台字幕（VTT/SRT）→ txt + md |
| `mkdoc.py` | 把 txt 整理成带来源表的 Markdown 文稿 |

## 识别质量

SenseVoice 对中文口播内容识别质量良好，技术术语准确率高于 B站 AI 字幕。常见小问题：

- **语气词保留较多**：模板会在转写中保留「啊」「呢」，通顺化时统一清理；
- **同音字误识别**：如「比牌」应为「比拼」、「具其表现」应为「具体表现」，需人工校对；
- **数字与英文混读**：`promote`、`title` 等英文词通常能保留，`3%` 可能转成「3点几」。

整理成正式文稿时，仍需按本仓库的交付标准做**通顺化处理与技术术语校正**，不能直接使用原始输出。

## 实测记录

| 视频 | 平台 | 时长 | 平台字幕 | 识别耗时 | 结果 |
|---|---|---|---|---|---|
| 巫师《原始积累的5条建议》 | YouTube | 29:24 | 无（连自动字幕都没有） | 约 2 分钟 | 9,030 字，术语准确 |

---

*工具代码由 AI 编写，MIT 许可。使用时请遵守各平台的robots 协议与版权规定，仅用于个人学习整理。*
