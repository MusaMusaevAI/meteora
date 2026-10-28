#!/usr/bin/env python3
"""Generates synthetic test recordings that mimic Yandex Telemost output
(WebM, VP8 video, Opus stereo 48 kHz in 10 ms packets, periodic keyframes).

Requires: ffmpeg (with libvpx, libopus, flite), Pillow, an Inter or DejaVu font.
Usage: python3 scripts/make_fixtures.py <out-dir> [--long]
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/inter/Inter-SemiBold.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]
FONT_REG = [
    "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def font(paths, size):
    for p in paths:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def slide(w, h, title, lines, accent=(29, 92, 69)):
    img = Image.new("RGB", (w, h), (250, 249, 245))
    d = ImageDraw.Draw(img)
    s = w / 1280
    d.rectangle([0, 0, w, int(14 * s)], fill=accent)
    d.text((int(80 * s), int(90 * s)), title, font=font(FONT_CANDIDATES, int(58 * s)), fill=(20, 20, 19))
    y = int(220 * s)
    for ln in lines:
        d.text((int(90 * s), y), ln, font=font(FONT_REG, int(34 * s)), fill=(60, 60, 58))
        y += int(62 * s)
    return img


def webcam(w, h, k):
    img = Image.new("RGB", (w, h), (38, 40, 44))
    d = ImageDraw.Draw(img)
    cx, cy = w // 2 + int(30 * ((k % 7) - 3)), h // 2 + int(10 * ((k % 5) - 2))
    r = h // 5
    d.ellipse([cx - r, cy - r - r // 2, cx + r, cy + r - r // 2], fill=(196, 160, 132))
    d.rectangle([cx - int(r * 1.6), cy + r // 2, cx + int(r * 1.6), h], fill=(52, 70, 96))
    return img


SLIDES = [
    ("Итоги квартала: ПДС", ["Новых договоров: 12 480", "Первые взносы: 64%", "Автоплатёж подключили: 3 115", "Средний взнос: 4 200 руб."]),
    ("Воронка конверсии", ["Заявка → договор: 41%", "Договор → первый взнос: 58%", "Повторный взнос через 90 дней: 33%"]),
    ("Быстрый слайд", ["Показан всего две секунды"]),
    ("Next steps / Следующие шаги", ["1. Обновить лендинг до 15 ноября", "2. A/B-тест письма", "3. Отчёт для правления"]),
    ("Сравнение каналов", ["Мобильное приложение — 52%", "Сайт — 31%", "Офисы — 17%"]),
    ("Риски и ограничения", ["Сезонность в декабре", "Нагрузка на колл-центр", "Сроки разработки"]),
]


def render_timeline(tmp, w, h, fps, timeline):
    """timeline: list of (kind, payload, seconds). Writes numbered PNG frames
    via an ffmpeg concat list (one image per segment; webcam animated)."""
    lst = os.path.join(tmp, "list.txt")
    n = 0
    with open(lst, "w") as f:
        for kind, payload, secs in timeline:
            if kind == "slide":
                p = os.path.join(tmp, f"s{n:04d}.png"); n += 1
                slide(w, h, *SLIDES[payload]).save(p)
                f.write(f"file '{p}'\nduration {secs}\n")
            else:  # webcam: a new pose every 0.5 s
                steps = int(secs * 2)
                for k in range(steps):
                    p = os.path.join(tmp, f"s{n:04d}.png"); n += 1
                    webcam(w, h, k).save(p)
                    f.write(f"file '{p}'\nduration 0.5\n")
        f.write(f"file '{p}'\n")
    return lst


def make_audio(tmp, total, speech_segments, channels=2):
    """Speech (flite) at given (start, text) positions, silence elsewhere."""
    parts = []
    for i, (start, text) in enumerate(speech_segments):
        wav = os.path.join(tmp, f"sp{i}.wav")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"flite=text='{text}':voice=slt",
                        "-ar", "48000", "-ac", "1", wav], check=True)
        parts.append((start, wav))
    inputs = []
    filters = []
    for i, (start, wav) in enumerate(parts):
        inputs += ["-i", wav]
        filters.append(f"[{i}:a]adelay={int(start * 1000)}|{int(start * 1000)},apad[a{i}]")
    mix = "".join(f"[a{i}]" for i in range(len(parts)))
    filters.append(f"{mix}amix=inputs={len(parts)}:normalize=0,atrim=0:{total},volume=0.35")
    out = os.path.join(tmp, "audio.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(filters),
                    "-ar", "48000", "-ac", str(channels), out], check=True)
    return out


def encode(out, lst, audio, w, h, fps, gop, extra=None, vcodec="libvpx", acodec="libopus", aframe="10"):
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst]
    if audio:
        cmd += ["-i", audio]
    cmd += ["-vf", f"fps={fps},scale={w}:{h},format=yuv420p", "-c:v", vcodec, "-b:v", "300k",
            "-g", str(gop), "-keyint_min", str(gop), "-deadline", "realtime", "-cpu-used", "8"]
    if audio:
        cmd += ["-c:a", acodec]
        if acodec == "libopus":
            cmd += ["-b:a", "32k", "-frame_duration", aframe]
    cmd += ["-shortest"] + (extra or []) + [out]
    subprocess.run(cmd, check=True)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    long = "--long" in sys.argv
    with tempfile.TemporaryDirectory() as tmp:
        # Short: 40 s, 1280x800, keyframe every 5 s.
        tl = [("slide", 0, 9.5), ("slide", 1, 11.5), ("slide", 2, 2.0), ("webcam", None, 7.0), ("slide", 3, 10.0)]
        lst = render_timeline(tmp, 1280, 800, 20, tl)
        speech = [(1.0, "Good morning everyone. Let us review the quarter."), (12.0, "Conversion improved this month."),
                  (31.0, "Next steps are listed on the slide.")]
        audio = make_audio(tmp, 40, speech)
        encode(os.path.join(out, "slides.webm"), lst, audio, 1280, 800, 20, 100)
        # Same, written like a live MediaRecorder stream (unknown sizes).
        encode(os.path.join(out, "live.webm"), lst, audio, 640, 400, 20, 100, extra=["-live", "1", "-cluster_time_limit", "2000"])
        # VP9 + Opus 20 ms.
        encode(os.path.join(out, "vp9.webm"), lst, audio, 640, 400, 20, 100, vcodec="libvpx-vp9", aframe="20")
        # Audio only, mono, 20 ms packets.
        mono = make_audio(tmp, 12, [(0.5, "This recording has only sound.")], channels=1)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mono, "-c:a", "libopus", "-b:a", "24k",
                        "-frame_duration", "20", os.path.join(out, "audio-only.webm")], check=True)
        # Vorbis audio (unsupported for export, must fail gracefully).
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mono, "-c:a", "libvorbis",
                        os.path.join(out, "vorbis.webm")], check=True)

        if long:
            # 10 minutes, 1920x1200, keyframe every 17 s — like a real Telemost recording.
            tl, t, i = [], 0.0, 0
            pattern = [("slide", 0, 75), ("webcam", None, 40), ("slide", 1, 95), ("slide", 3, 60), ("slide", 4, 3),
                       ("slide", 5, 120), ("webcam", None, 30), ("slide", 0, 80), ("slide", 4, 97)]
            for item in pattern:
                tl.append(item); t += item[2]
            lst = render_timeline(tmp, 1920, 1200, 20, tl)
            speech = [(s, "We are discussing the pension savings program and the next campaign.") for s in range(5, int(t) - 10, 37)]
            audio = make_audio(tmp, t, speech)
            encode(os.path.join(out, "long-1920.webm"), lst, audio, 1920, 1200, 20, 340)


if __name__ == "__main__":
    main()
