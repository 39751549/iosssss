# -*- coding: utf-8 -*-
"""SVGA（逐帧整图型）→ animated WebP

这批素材的结构（已逐个验证）：
  - 每帧恰好 1 个 sprite 显示 1 张整幅 264x264 PNG（导出工具把动画逐帧烘焙好了）
  - SpriteEntity.f2 是按帧号排列的数组，空条目 = 该帧不显示
  - params: f1/f2 画布 264x264，f3 fps，f4 总帧数
输出限制 ≤48 帧（对齐 iOS avatar 解码档位 maxFrames=48），30fps 的抽 1/2 帧。
"""
import zlib, struct, io, os, sys
from PIL import Image

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "头像框")
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public", "frames")


def rv(b, i):
    v = s = 0
    while True:
        x = b[i]; i += 1
        v |= (x & 0x7f) << s
        if not x & 0x80: return v, i
        s += 7


def fields(b):
    i = 0; out = []
    while i < len(b):
        try: key, i = rv(b, i)
        except IndexError: break
        fno, wt = key >> 3, key & 7
        try:
            if wt == 0: v, i = rv(b, i); out.append((fno, "v", v))
            elif wt == 1:
                if i + 8 > len(b): break
                v = struct.unpack("<Q", b[i:i+8])[0]; i += 8; out.append((fno, "f64", v))
            elif wt == 5:
                if i + 4 > len(b): break
                v = struct.unpack("<f", b[i:i+4])[0]; i += 4; out.append((fno, "f32", round(v, 3)))
            elif wt == 2:
                ln, i = rv(b, i); out.append((fno, "b", b[i:i+ln])); i += ln
            else: break
        except (IndexError, struct.error): break
    return out


def svga_to_webp(src, dst, max_frames=48, quality=75, scale=200):
    raw = zlib.decompress(open(src, "rb").read())
    top = fields(raw)
    params = {fn: v for fn, t, v in fields([v for fn, t, v in top if fn == 2][0])}
    W, H, fps = int(params[1]), int(params[2]), int(params[3])
    imgs = [v for fn, t, v in top if fn == 3]
    # 光效类动画（12-15fps）抽帧会明显卡顿，只在 30fps 素材上抽半帧到 15fps
    fps_cap = 15

    key2png = {}
    for s in imgs:
        f = fields(s)
        key2png[[v for fn, t, v in f if fn == 1][0].decode()] = [v for fn, t, v in f if fn == 2][0]

    total = int(params[4])
    step = max(1, -(-total // max_frames), -(fps // -fps_cap) if fps > fps_cap else 1)
    out_fps = fps // step
    out_size = (scale, scale)

    # 预解析：frame -> [png bytes]（每个 sprite 只解析一次，展开成按帧查表）
    per_frame = [[] for _ in range(total)]
    for s in [v for fn, t, v in top if fn == 4]:
        sp = fields(s)
        key = [v for fn, t, v in sp if fn == 1][0].decode()
        png = key2png.get(key)
        if not png:
            continue
        fidx = -1
        for fn, t, v in sp:
            if fn == 2:
                fidx += 1
                if t == "b" and len(v) > 0:
                    per_frame[fidx].append(png)

    # 预解码：相邻帧复用同一张图（30fps 素材每图占 2 帧），按 bytes 引用缓存 RGBA
    rgba_cache = {}
    frames_rgba = []
    for fi in range(0, total, step):
        canvas = Image.new("RGBA", out_size, (0, 0, 0, 0))
        for png in per_frame[fi]:
            im = rgba_cache.get(png)
            if im is None:
                im = Image.open(io.BytesIO(png)).convert("RGBA")
                if im.size != out_size:
                    im = im.resize(out_size, Image.LANCZOS)
                rgba_cache[png] = im
            canvas.alpha_composite(im)
        frames_rgba.append(canvas)
    rgba_cache.clear()

    durations = [round(1000 / out_fps)] * len(frames_rgba)
    frames_rgba[0].save(dst, save_all=True, append_images=frames_rgba[1:],
                        duration=durations, loop=0, quality=quality, method=4)
    kb = os.path.getsize(dst) // 1024
    print(f"{os.path.basename(src)} -> {os.path.basename(dst)}: {len(frames_rgba)}帧 {out_fps}fps {W}x{H} {kb}KB", flush=True)


JOBS = [
    ("wespy_game_1641885995.svga", "frame-anim-dream.webp"),
    ("wespy_game_1652672764.svga", "frame-anim-hearts.webp"),
    ("wespy_game_1658720321.svga", "frame-anim-feather.webp"),
    ("wespy_game_1660031702.svga", "frame-anim-wings.webp"),
    ("wespy_game_1667549673.svga", "frame-anim-balloon.webp"),
]

if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for src, dst in JOBS:
        if only and only not in src:
            continue
        svga_to_webp(os.path.join(SRC, src), os.path.join(DST, dst))
    print("DONE")
