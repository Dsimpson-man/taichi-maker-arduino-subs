#!/usr/bin/env bash
# yt-sub — 从 YouTube / B站 等站点获取字幕，无字幕时走本地语音识别
#
# 用法:
#   ./yt-sub.sh <视频URL> [输出目录]
#
# 流程:
#   1. 优先抓取平台已有字幕（YouTube 自动字幕 / B站 ai-zh），零成本
#   2. 没有字幕 -> 下载音轨 -> 转 16kHz 单声道 -> 本地 SenseVoice 离线识别
#
# 依赖:
#   yt-dlp (pip3 install --user yt-dlp)
#   python3 + sherpa-onnx   (pip3 install --user sherpa-onnx)
#   SenseVoice 模型          (~/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx)
#   afconvert (macOS 自带)  或 ffmpeg

set -euo pipefail

URL="${1:?用法: $0 <视频URL> [输出目录]}"
OUT="${2:-$HOME/Documents/deepseek-harness/default-workspace/youtube-subs}"

# 代理：本机 Shadowrocket 的 HTTP/SOCKS5 端口，不需要时置空
PROXY="${YT_PROXY:-socks5h://127.0.0.1:1082}"
PLAYER_CLIENT="${YT_CLIENT:-android,tv,web_safari}"

mkdir -p "$OUT"
cd "$OUT"

YTDLP=(python3 -m yt_dlp)
if [ -n "$PROXY" ]; then
  YTDLP+=(--proxy "$PROXY")
fi
YTDLP+=(--extractor-args "youtube:player_client=$PLAYER_CLIENT"
        --retries 20 --fragment-retries 20 --socket-timeout 30)

echo "==> [1/4] 获取视频信息"
META=$("${YTDLP[@]}" --skip-download \
  --print "%(title)s|||%(uploader)s|||%(duration_string)s|||%(upload_date)s|||%(id)s" \
  "$URL" 2>/dev/null | tail -1)
TITLE="${META%%|||*}"; REST="${META#*|||}"
UPLOADER="${REST%%|||*}"; REST="${REST#*|||}"
DURATION="${REST%%|||}"; REST="${REST#*|||}"
UPLOAD_DATE="${REST%%|||}"; VID="${REST#*|||}"
echo "    标题: $TITLE"
echo "    作者: $UPLOADER | 时长: $DURATION | 发布: $UPLOAD_DATE"

SAFE=$(echo "$TITLE" | tr '/:*?"<>|' '________' | cut -c1-60)
BASE="$SAFE"
WORK="$OUT/.work-$VID"
mkdir -p "$WORK"

echo "==> [2/4] 尝试抓取平台字幕"
"${YTDLP[@]}" --skip-download --write-subs --write-auto-subs \
  --sub-langs "zh-Hans,zh-CN,zh,en.*" --sub-format "vtt/srt" \
  -o "$WORK/subs.%(ext)s" "$URL" >/dev/null 2>&1 || true

SUB_FILE=$(ls "$WORK"/*.vtt "$WORK"/*.srt 2>/dev/null | head -1 || true)
if [ -n "$SUB_FILE" ]; then
  echo "    找到平台字幕: $(basename "$SUB_FILE")"
  python3 "$(dirname "$0")/vtt2txt.py" "$SUB_FILE" "$OUT/$BASE" "$TITLE" "$URL" "$UPLOADER" "$DURATION" "$UPLOAD_DATE"
  echo "==> 完成（无需语音识别）: $OUT/$BASE.md"
  exit 0
fi
echo "    平台无字幕，转语音识别"

echo "==> [3/4] 下载音频"
"${YTDLP[@]}" -f "bestaudio/best" -o "$WORK/audio.%(ext)s" --newline "$URL" 2>&1 \
  | grep -E '100%|ERROR' || true
AUDIO=$(ls "$WORK"/audio.* 2>/dev/null | grep -v '\.part$' | head -1)
[ -n "$AUDIO" ] || { echo "下载失败"; exit 1; }

echo "==> [4/4] 本地 SenseVoice 识别"
afconvert -f WAVE -d LEI16@16000 -c 1 "$AUDIO" "$WORK/speech.wav"
python3 "$(dirname "$0")/asr.py" "$WORK/speech.wav" "$OUT/$BASE"
python3 "$(dirname "$0")/mkdoc.py" "$OUT/$BASE.txt" "$OUT/$BASE.md" "$TITLE" "$URL" "$UPLOADER" "$DURATION" "$UPLOAD_DATE" "无（语音识别）"

echo "==> 全部完成:"
echo "    文稿 $OUT/$BASE.md"
echo "    字幕 $OUT/$BASE.srt"
