"""GenHub2's film: every function of the system, recorded on genhub2.quanterall.com.

    ~/demo-video-venv/bin/python make_film.py narrate    the narration only (record.py paces each take by it)
    ~/demo-video-venv/bin/python make_film.py            the film -> ~/genhub2-film/genhub2-film.mp4

The voice and the method are TechUPGRADE's films': edge-tts, en-US-AndrewNeural at -4 %; title cards are HTML pages
(cards/) recorded in a browser so they animate; screen takes come from record.py (~/genhub2-film/raw/<scene>.webm).
scenes.json: per scene its narration and its picture, `card:<name>` or `raw:<file>`. A scene lasts its narration
plus LEAD and TAIL; a take longer than that is cut, a shorter one holds its last frame.
"""
import asyncio, json, os, subprocess, sys

import edge_tts
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
FILM = os.path.expanduser("~/genhub2-film")
RAW, WORK = os.path.join(FILM, "raw"), os.path.join(FILM, "build")
OUT = os.path.join(FILM, "genhub2-film.mp4")
VOICE, RATE, LEAD, TAIL = "en-US-AndrewNeural", "-4%", 0.6, 1.2
SCENES = json.load(open(os.path.join(HERE, "scenes.json")))


def run(*a): subprocess.run(a, check=True)


def duration(f):
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                          "-of", "csv=p=0", f]))


async def narrate():
    """one mp3 per scene, spoken again only when its text changed"""
    os.makedirs(f"{WORK}/narration", exist_ok=True)
    out = {}
    for s in SCENES:
        f = f"{WORK}/narration/{s['name']}.mp3"
        said = f + ".txt"
        if os.path.exists(f) and (not os.path.exists(said) or open(said).read() != s["text"]):
            os.remove(f)
        for attempt in range(5):
            if os.path.exists(f):
                break
            try:
                await edge_tts.Communicate(s["text"], VOICE, rate=RATE).save(f + ".part")
                duration(f + ".part"); os.replace(f + ".part", f)
            except Exception as e:
                print(f"  narration {s['name']}: {e.__class__.__name__}, retrying"); await asyncio.sleep(5 * (attempt + 1))
        open(said, "w").write(s["text"])
        out[s["name"]] = duration(f)
    return out


async def cards(lengths):
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for s in SCENES:
            src = s["src"][0]
            if not src.startswith("card:"):
                continue
            f = f"{WORK}/card_{s['name']}.webm"
            html = os.path.join(HERE, "cards", src[5:] + ".html")
            if os.path.exists(f) and os.path.getmtime(f) > max(os.path.getmtime(html),
                                                               os.path.getmtime(os.path.join(HERE, "cards", "style.css"))):
                continue
            ctx = await b.new_context(viewport={"width": 1920, "height": 1080}, record_video_dir=f"{WORK}/_rec",
                                      record_video_size={"width": 1920, "height": 1080})
            pg = await ctx.new_page()
            await pg.goto("file://" + html)
            await pg.wait_for_timeout(int((lengths[s["name"]] + LEAD + TAIL + 1.0) * 1000))
            v = pg.video; await ctx.close(); os.replace(await v.path(), f)
        await b.close()


def segment(i, s, speech):
    src = s["src"][0]
    d = round(speech + LEAD + TAIL, 2)
    f = f"{WORK}/card_{s['name']}.webm" if src.startswith("card:") else os.path.join(RAW, src[4:])
    if not os.path.exists(f):
        raise SystemExit(f"no picture for {s['name']}: {f}")
    a = s.get("a", 0.0)
    if isinstance(a, str) and a.startswith("state:"):       # a moment record.py noted, e.g. just before a click
        a = json.load(open(os.path.join(FILM, "state.json")))[a[6:]]
    avail = duration(f) - a
    used = min(avail, d)
    seg = f"{WORK}/seg{i:02d}_{s['name']}.mp4"
    vf = (f"trim=start={a}:end={a + used},setpts=PTS-STARTPTS,scale=1920:1080:flags=lanczos,fps=30,"
          f"tpad=stop_mode=clone:stop_duration={d},trim=duration={d},format=yuv420p,"
          f"fade=t=in:st=0:d=0.4,fade=t=out:st={d - 0.4}:d=0.4")
    run("ffmpeg", "-loglevel", "error", "-y", "-i", f, "-i", f"{WORK}/narration/{s['name']}.mp3",
        "-filter_complex", f"[0:v]{vf}[v];[1:a]adelay={int(LEAD * 1000)}|{int(LEAD * 1000)},apad,atrim=duration={d}[a]",
        "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2", seg)
    print(f"  {s['name']:15s} {d:5.1f}s  {src:24s} take {avail:5.1f}s, last frame held {max(0.0, d - avail):4.1f}s")
    return seg


def subtitles(lengths):
    """English subtitles (WebVTT) beside the film: each scene's narration in sentences, timed in proportion to their
    length within the time the voice speaks"""
    import re
    def ts(t): return f"{int(t // 3600):02d}:{int(t % 3600 // 60):02d}:{t % 60:06.3f}"
    cues, t0 = ["WEBVTT", ""], 0.0
    for s in SCENES:
        d = round(lengths[s["name"]] + LEAD + TAIL, 2)
        parts = [p for p in re.split(r"(?<=[.?!])\s+", s["text"]) if p]
        total, at = sum(len(p) for p in parts), t0 + LEAD
        for p in parts:
            span = lengths[s["name"]] * len(p) / total
            cues += [ts(at) + " --> " + ts(at + span), p, ""]
            at += span
        t0 += d
    open(OUT.replace(".mp4", ".vtt"), "w").write("\n".join(cues))


async def main():
    os.makedirs(WORK, exist_ok=True)
    lengths = await narrate()
    total = sum(lengths.values()) + len(SCENES) * (LEAD + TAIL)
    print(f"narration {sum(lengths.values()):.0f} s; the film will run {total / 60:.1f} min")
    if sys.argv[1:] == ["narrate"]:
        return
    await cards(lengths)
    segs = [segment(i, s, lengths[s["name"]]) for i, s in enumerate(SCENES)]
    open(f"{WORK}/list.txt", "w").writelines(f"file '{x}'\n" for x in segs)
    subtitles(lengths)
    run("ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", f"{WORK}/list.txt",
        "-c", "copy", "-movflags", "+faststart", OUT)
    print(OUT, round(duration(OUT), 1), "s")

asyncio.run(main())
