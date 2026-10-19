#!/usr/bin/env python3
"""用本地 SenseVoice 模型对音频做语音识别，输出带时间戳的字幕。

用法: python3 asr.py <音频文件> [输出前缀]
输出: <前缀>.txt（分段文稿） / <前缀>.srt（字幕）
"""
import sys, os, wave, subprocess, json, math
import sherpa_onnx

MODEL_DIR = os.path.expanduser(
    "~/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx")
MODEL = os.path.join(MODEL_DIR, "model.int8.onnx")
TOKENS = os.path.join(MODEL_DIR, "tokens.txt")

SAMPLE_RATE = 16000


def to_wav16k(src, dst):
    """FFmpeg 不可用时，尝试直接用 sherpa 的读取能力；这里优先调用系统 afconvert。"""
    cmds = [
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, dst],
    ]
    for c in cmds:
        try:
            r = subprocess.run(c, capture_output=True, text=True)
            if r.returncode == 0 and os.path.exists(dst):
                return True
        except FileNotFoundError:
            continue
    return False


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1, "需要单声道"
        assert w.getframerate() == SAMPLE_RATE, f"需要 {SAMPLE_RATE}Hz"
        n = w.getnframes()
        raw = w.readframes(n)
    import array
    a = array.array("h", raw)
    return [s / 32768.0 for s in a]


def build_recognizer():
    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=MODEL,
        tokens=TOKENS,
        num_threads=4,
        use_itn=True,
        language="auto",
        debug=False,
    )


def fmt_ts(sec):
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else "output"

    wav = prefix + ".wav"
    if not src.lower().endswith(".wav"):
        print(f"[1/3] 转码 {src} -> {wav} (16kHz 单声道)")
        if not to_wav16k(src, wav):
            print("转码失败：需要 afconvert（macOS 自带）或 ffmpeg")
            sys.exit(1)
    else:
        wav = src

    print(f"[2/3] 读取音频 {wav}")
    samples = read_wav(wav)
    dur = len(samples) / SAMPLE_RATE
    print(f"      时长 {dur:.1f}s")

    print("[3/3] 加载 SenseVoice 模型并识别")
    rec = build_recognizer()

    # 按 30 秒切块，避免长音频内存与边界问题
    CHUNK = 30.0
    segs = []
    total = int(math.ceil(dur / CHUNK))
    for i in range(total):
        start = i * CHUNK
        end = min(dur, start + CHUNK)
        piece = samples[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)]
        if len(piece) < SAMPLE_RATE * 0.3:
            continue
        stream = rec.create_stream()
        stream.accept_waveform(SAMPLE_RATE, piece)
        rec.decode_stream(stream)
        text = (stream.result.text or "").strip()
        segs.append((start, end, text))
        pct = (i + 1) / total * 100
        print(f"\r      进度 {pct:5.1f}%  ({i+1}/{total})", end="", flush=True)
    print()

    txt_path = prefix + ".txt"
    srt_path = prefix + ".srt"
    with open(txt_path, "w", encoding="utf-8") as f:
        for s, e, t in segs:
            if t:
                f.write(f"[{int(s//60):02d}:{int(s%60):02d}] {t}\n")
    with open(srt_path, "w", encoding="utf-8") as f:
        idx = 1
        for s, e, t in segs:
            if not t:
                continue
            f.write(f"{idx}\n{fmt_ts(s)} --> {fmt_ts(e)}\n{t}\n\n")
            idx += 1
    print(f"完成：{txt_path} / {srt_path}")


if __name__ == "__main__":
    main()
