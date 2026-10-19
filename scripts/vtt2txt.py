#!/usr/bin/env python3
"""把平台字幕（VTT/SRT）转成 txt + md。"""
import sys, re

sub_path, out_prefix, title, url, uploader, duration, pubdate = sys.argv[1:8]
raw = open(sub_path, encoding="utf-8", errors="ignore").read()

# 解析 VTT/SRT 的时间轴块
blocks = re.split(r"\n\s*\n", raw.replace("\r\n", "\n"))
entries = []
ts_re = re.compile(r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[.,](\d{3})")
for b in blocks:
    m = ts_re.search(b)
    if not m:
        continue
    h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
    start = h * 3600 + mi * 60 + s
    lines = [l.strip() for l in b.split("\n") if l.strip()]
    # 去掉序号行与时间轴行
    text = " ".join(l for l in lines if not ts_re.search(l) and not l.strip().isdigit())
    text = re.sub(r"<[^>]+>", "", text).strip()
    if text:
        entries.append((start, text))

if not entries:
    print("字幕为空或无有效文本", file=sys.stderr)
    sys.exit(2)

with open(out_prefix + ".txt", "w", encoding="utf-8") as f:
    for t, s in entries:
        f.write(f"[{t//60:02d}:{t%60:02d}] {s}\n")

import subprocess, os
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run([sys.executable, os.path.join(here, "mkdoc.py"),
                out_prefix + ".txt", out_prefix + ".md",
                title, url, uploader, duration, pubdate,
                "平台字幕（" + os.path.basename(sub_path) + "）"], check=False)
print(f"生成 {out_prefix}.txt")
