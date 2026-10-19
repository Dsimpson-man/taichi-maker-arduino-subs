#!/usr/bin/env bash
# yt-sub — 从 YouTube / B站 / 小红书 等站点获取字幕，无字幕时走本地语音识别
#
# 用法:
#   ./yt-sub.sh <视频URL> [输出目录]
#
# 流程:
#   1. 优先抓取平台已有字幕（YouTube 自动字幕 / B站 ai-zh），零成本
#   2. 没有字幕 -> 只下载音轨（拿不到独立音轨才退到最小视频流）
#      -> 抽 16kHz 单声道 -> 本地 SenseVoice 离线识别 -> 删中间文件
#
# 依赖:
#   yt-dlp (pip3 install --user yt-dlp)
#   python3 + sherpa-onnx   (pip3 install --user sherpa-onnx)
#   ffmpeg                  (优先用系统 ffmpeg，否则用 imageio-ffmpeg 自带的)
#   SenseVoice 模型          (~/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx)
#
# 环境变量:
#   YT_PROXY   代理地址，默认 socks5h://127.0.0.1:1082，置空则直连
#   YT_CLIENT  YouTube player client，默认 android,tv,web_safari
#   KEEP_WORK  设 1 则保留下载的原始音频（默认识别完即删）

set -euo pipefail

URL="${1:?用法: $0 <视频URL> [输出目录]}"
OUT="${2:-$(pwd)}"

PROXY="${YT_PROXY-socks5h://127.0.0.1:1082}"
PLAYER_CLIENT="${YT_CLIENT:-android,tv,web_safari}"
KEEP_WORK="${KEEP_WORK:-0}"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)

# ---- ffmpeg 定位：系统优先，其次 imageio-ffmpeg 自带二进制 ----
FFMPEG="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG" ]; then
  for py in python3 \
            "$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3"; do
    [ -x "$py" ] || command -v "$py" >/dev/null 2>&1 || continue
    p=$("$py" -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)
    if [ -n "$p" ] && [ -x "$p" ]; then FFMPEG="$p"; break; fi
  done
fi
[ -n "$FFMPEG" ] || { echo "错误：找不到 ffmpeg。请 pip3 install --user imageio-ffmpeg 或安装系统 ffmpeg"; exit 1; }

# ---- 组装 yt-dlp 参数 ----
YTDLP=(python3 -m yt_dlp)
if [ -n "$PROXY" ]; then
  YTDLP+=(--proxy "$PROXY")
fi
YTDLP+=(--extractor-args "youtube:player_client=$PLAYER_CLIENT"
        --retries 20 --fragment-retries 20 --socket-timeout 30)

# 小红书短链先展开
if [[ "$URL" == *"xhslink.com"* ]]; then
  echo "==> 展开小红书短链"
  URL=$(curl -sIL --max-time 20 -A "Mozilla/5.0" "$URL" 2>/dev/null \
        | grep -iE '^location:' | tail -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
  [ -n "$URL" ] || { echo "短链展开失败"; exit 1; }
  echo "    -> $URL"
fi

echo "==> [1/4] 获取视频信息"
# 用 Python 解析元信息，避免中文/emoji 标题在 bash 里被按字节截断
META=$(python3 "$HERE/meta.py" "$URL" "$PROXY" "$PLAYER_CLIENT" 2>/dev/null | tail -1)
[ -n "$META" ] || { echo "获取信息失败，检查链接、登录态或代理"; exit 1; }
TITLE=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["title"])' <<<"$META")
UPLOADER=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["uploader"])' <<<"$META")
DURATION=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["duration"])' <<<"$META")
UPLOAD_DATE=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_date"])' <<<"$META")
VID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$META")
echo "    标题: $TITLE"
echo "    作者: $UPLOADER | 时长: $DURATION | 发布: $UPLOAD_DATE"

# 文件名：去 emoji 与非法字符，按字符（非字节）截断
BASE=$(python3 - "$TITLE" <<'PY'
import re, sys
t = sys.argv[1]
t = re.sub(r'[\\/:*?"<>|\x00-\x1f]', '_', t)
# 去掉 emoji 与变体选择符
t = ''.join(c for c in t if not (0x1F000 <= ord(c) <= 0x1FAFF or ord(c) in (0xFE0F, 0x200D)))
t = re.sub(r'\s+', ' ', t).strip(' ._')
print((t or 'untitled')[:60])
PY
)
WORK="$OUT/.work-$VID"
mkdir -p "$WORK"
cleanup() {
  if [ "$KEEP_WORK" != "1" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

echo "==> [2/4] 尝试抓取平台字幕"
"${YTDLP[@]}" --skip-download --write-subs --write-auto-subs \
  --sub-langs "zh-Hans,zh-CN,zh,en.*" --sub-format "vtt/srt" \
  -o "$WORK/subs.%(ext)s" "$URL" >/dev/null 2>&1 || true

SUB_FILE=$(ls "$WORK"/*.vtt "$WORK"/*.srt 2>/dev/null | head -1 || true)
if [ -n "$SUB_FILE" ]; then
  echo "    找到平台字幕: $(basename "$SUB_FILE")（无需语音识别）"
  python3 "$HERE/vtt2txt.py" "$SUB_FILE" "$OUT/$BASE" "$TITLE" "$URL" \
     "${UPLOADER:-未知}" "$DURATION" "${UPLOAD_DATE:-未知}"
  echo "==> 完成: $OUT/$BASE.md"
  exit 0
fi
echo "    平台无字幕，转语音识别"

# 判定平台：只有 YouTube 需要 client 轮换（PO Token / 403 问题）
IS_YOUTUBE=0
case "$URL" in
  *youtube.com*|*youtu.be*) IS_YOUTUBE=1 ;;
esac

echo "==> [3/4] 下载音频"
DL_OK=0
MEDIA=""

if [ "$IS_YOUTUBE" = "1" ]; then
  # YouTube：逐个 client 探测纯音频流；找到就用，找不到再退到含音频的最小流
  AUDIO_FMT=""
  for CL in android_vr ios mweb web_safari tv android; do
    OUTP=$(python3 -m yt_dlp --skip-download --proxy "${PROXY:-}" \
      --extractor-args "youtube:player_client=$CL" --print "%(format_id)s" \
      -f "bestaudio[acodec!=none][vcodec=none]" "$URL" 2>/dev/null | tail -1 || true)
    if [[ "$OUTP" =~ ^[0-9]+$ ]]; then AUDIO_FMT="$OUTP"; PLAYER_CLIENT="$CL"; break; fi
  done

  if [ -n "$AUDIO_FMT" ]; then
    echo "    独立音轨可用（format ${AUDIO_FMT}，client=${PLAYER_CLIENT}），只下音频"
    CAND=(-f "$AUDIO_FMT")
  else
    echo "    无独立音轨，退到含音频的最小流"
    CAND=(-f "bestaudio[acodec!=none]/best[acodec!=none]/best")
  fi

  for CL in "$PLAYER_CLIENT" android_vr ios mweb web_safari tv android; do
    echo "    尝试 client=${CL}"
    "${YTDLP[@]}" --extractor-args "youtube:player_client=$CL" "${CAND[@]}" \
      -o "$WORK/media.%(ext)s" --newline "$URL" 2>&1 \
      | grep -E '100%|ERROR' | tail -2 || true
    MEDIA=$(ls "$WORK"/media.* 2>/dev/null | grep -v '\.part$' | head -1 || true)
    [ -n "$MEDIA" ] && { DL_OK=1; break; }
    rm -f "$WORK"/media.*
  done
else
  # 其他平台（B站/小红书等）：用通用选择，先纯音频，再最小含音频流
  echo "    尝试：优先纯音频流，否则最小含音频流"
  "${YTDLP[@]}" -f "bestaudio[acodec!=none][vcodec=none]/bestaudio/best[acodec!=none]/best" \
    -o "$WORK/media.%(ext)s" --newline "$URL" 2>&1 \
    | grep -E '100%|ERROR' | tail -2 || true
  MEDIA=$(ls "$WORK"/media.* 2>/dev/null | grep -v '\.part$' | head -1 || true)
  [ -n "$MEDIA" ] && DL_OK=1
fi

if [ "$DL_OK" != "1" ]; then
  echo "下载失败：未取到媒体流。常见原因："
  echo "  - 链接需要登录态（小红书图文笔记无音频、部分视频需 cookie）"
  echo "  - YouTube 当前节点被限（HTTP 403），换代理节点后重试"
  exit 1
fi
SIZE_MB=$(python3 -c 'import os,sys;print(round(os.path.getsize(sys.argv[1])/1048576,1))' "$MEDIA")
echo "    已下载: ${SIZE_MB} MB"

echo "==> [4/4] 本地 SenseVoice 识别"
"$FFMPEG" -y -loglevel error -i "$MEDIA" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$WORK/speech.wav"
[ "$KEEP_WORK" = "1" ] || rm -f "$MEDIA"
python3 "$HERE/asr.py" "$WORK/speech.wav" "$OUT/$BASE"
python3 "$HERE/mkdoc.py" "$OUT/$BASE.txt" "$OUT/$BASE.md" "$TITLE" "$URL" \
   "${UPLOADER:-未知}" "$DURATION" "${UPLOAD_DATE:-未知}" "无（本地语音识别）"

echo "==> 全部完成:"
echo "    文稿 $OUT/$BASE.md"
echo "    字幕 $OUT/$BASE.srt"
echo "    文本 $OUT/$BASE.txt"
