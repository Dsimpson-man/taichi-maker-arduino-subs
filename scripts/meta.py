#!/usr/bin/env python3
"""从 yt-dlp 取视频元信息，输出为 JSON 供 shell 解析（避免中文/emoji 下的字节截断问题）。

用法: python3 meta.py <URL> [proxy] [player_client]
输出: JSON，字段 title/uploader/duration/upload_date/id
"""
import json
import subprocess
import sys

url = sys.argv[1]
proxy = sys.argv[2] if len(sys.argv) > 2 else ""
client = sys.argv[3] if len(sys.argv) > 3 else ""

cmd = [sys.executable, "-m", "yt_dlp", "--skip-download",
       "--dump-single-json", "--no-warnings"]
if proxy:
    cmd += ["--proxy", proxy]
if client:
    cmd += ["--extractor-args", f"youtube:player_client={client}"]
cmd += [url]

data = {}
for _ in range(3):  # yt-dlp 的 "page needs to be reloaded" 是偶发的，重试几次
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
        parsed = json.loads(out.stdout) if out.stdout.strip() else None
        if isinstance(parsed, dict) and parsed.get("title"):
            data = parsed
            break
    except Exception:
        pass


def val(k):
    v = data.get(k)
    return "" if v in (None, "", "NA") else str(v)


# upload_date 是 YYYYMMDD，格式化成 YYYY-MM-DD
ud = val("upload_date")
if len(ud) == 8 and ud.isdigit():
    ud = f"{ud[:4]}-{ud[4:6]}-{ud[6:]}"

dur = data.get("duration")
if isinstance(dur, (int, float)) and dur > 0:
    m, s = divmod(int(dur), 60)
    h, m = divmod(m, 60)
    duration = f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
else:
    duration = val("duration_string") or "未知"

print(json.dumps({
    "ok": bool(data),
    "title": val("title") or "未命名",
    "uploader": val("uploader") or val("channel") or val("uploader_id") or "未知",
    "duration": duration,
    "upload_date": ud or "未知",
    "id": val("id") or "unknown",
    "url": val("webpage_url") or url,
}, ensure_ascii=False))
