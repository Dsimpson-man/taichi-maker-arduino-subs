#!/usr/bin/env python3
"""把 txt（[mm:ss] 文本 格式）整理成带来源信息的 Markdown 文稿。"""
import sys, re

txt_path, md_path, title, url, uploader, duration, pubdate, sub_source = sys.argv[1:9]

raw = open(txt_path, encoding="utf-8").read()
segs = re.findall(r"^\[(\d+:\d+)\] (.*)$", raw, re.M)


def clean(s):
    s = re.sub(r"。{2,}", "。", s)
    s = re.sub(r"，{2,}", "，", s)
    s = re.sub(r"？{2,}", "？", s)
    s = re.sub(r"！{2,}", "！", s)
    return s.strip()


body = [clean(t) for _, t in segs]
paras = ["".join(body[i:i + 2]) for i in range(0, len(body), 2)]
chars = len(re.sub(r"\s", "", "".join(body)))

lines = [
    f"# {title}", "",
    "| 项 | 内容 |", "|---|---|",
    f"| 来源 | YouTube · {uploader} |",
    f"| 视频链接 | {url} |",
    f"| 时长 | {duration} |",
    f"| 发布 | {pubdate} |",
    f"| 字幕来源 | {sub_source} |",
    "| 识别方式 | 本地 SenseVoice ONNX 模型（全程离线） |",
    f"| 全文 | 约 {chars} 字 |",
    "", "---", "",
]
for p in paras:
    if p:
        lines.append(p)
        lines.append("")

open(md_path, "w", encoding="utf-8").write("\n".join(lines).rstrip() + "\n")
print(f"生成 {md_path}（{len(paras)} 段，{chars} 字）")
