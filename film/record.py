"""The film's screen takes, recorded on genhub2.quanterall.com as the film accounts (film-admin, film-analyst,
film-researcher; ~/genhub2-film/users.txt). Run seed.py first, and make_film.py narrate: each take lasts at least as
long as its scene's narration.

    ~/demo-video-venv/bin/python record.py [scene ...]     -> ~/genhub2-film/raw/<scene>.webm

The takes depend on each other in the order below (upload makes the job that result shows, and so on); the job ids
are kept in ~/genhub2-film/state.json. What the takes write on the site is public data only: the test genomes of
the front page, reads simulated from one of them, and the simulated second laboratory's counts.
"""
import asyncio, json, os, subprocess, sys, time
from playwright.async_api import async_playwright
from filmsite import SITE, FILM, USERS, Api, code

APP = SITE + "/app/"
RAW = os.path.join(FILM, "raw")
NARR = os.path.join(FILM, "build", "narration")
IN = os.path.join(FILM, "inputs")
GENOMES = os.path.expanduser("~/genhub2-dev/deploy/genhub2.quanterall.com/www/test-genomes")
STATE_F = os.path.join(FILM, "state.json")
STATE = json.load(open(STATE_F)) if os.path.exists(STATE_F) else {}


def save():
    json.dump(STATE, open(STATE_F, "w"), indent=1)


def need(scene):
    """how long the take must last: its narration, the film's lead and tail, and a little more"""
    f = f"{NARR}/{scene}.mp3"
    d = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]))
    return d + 2.2


def wait_job(user, job, timeout=1800):
    a = Api(user)
    t0 = time.time()
    while time.time() - t0 < timeout:
        j = a.call("GET", f"/api/jobs/{job}")
        if j["state"] in ("done", "failed"):
            return j
        time.sleep(3)
    raise SystemExit(f"{job} not finished")


async def logged_in(b, user):
    """a browser state with user's session, logged in off camera"""
    f = os.path.join(FILM, f"state-{user}.json")
    c = await b.new_context(viewport={"width": 1920, "height": 1080})
    pg = await c.new_page()
    await pg.goto(APP); await pg.wait_for_selector("#l-user")
    await pg.fill("#l-user", user); await pg.fill("#l-pw", USERS[user][0]); await pg.fill("#l-code", code(user))
    await pg.click("#login-form button"); await pg.wait_for_selector("#who:not([hidden])")
    await c.storage_state(path=f); await c.close()
    return f


class Take:
    def __init__(self, b, name, state=None):
        self.b, self.name, self.state = b, name, state

    async def __aenter__(self):
        os.makedirs(RAW, exist_ok=True)
        self.c = await self.b.new_context(viewport={"width": 1920, "height": 1080}, storage_state=self.state, bypass_csp=True,
                                          record_video_dir=f"{RAW}/_rec", record_video_size={"width": 1920, "height": 1080})
        self.pg = await self.c.new_page()
        self.t0 = time.time()
        return self

    async def until(self, scene=None):
        """hold the picture until the scene's narration is over"""
        rest = need(scene or self.name) - (time.time() - self.t0)
        if rest > 0:
            await self.pg.wait_for_timeout(int(rest * 1000))

    async def __aexit__(self, *exc):
        pages = self.c.pages
        vids = [(p, p.video) for p in pages]
        await self.c.close()
        for i, (p, v) in enumerate(vids):
            name = self.name if i == 0 else self.extra.get(i, f"{self.name}_{i}")
            os.replace(await v.path(), f"{RAW}/{name}.webm")
        print(time.strftime("%H:%M:%S"), "recorded", self.name, flush=True)

    extra = {}


async def scroll_to(pg, sel, block="start"):
    await pg.locator(sel).first.evaluate(f"e => e.scrollIntoView({{block: '{block}', behavior: 'smooth'}})")
    await pg.wait_for_timeout(1200)


async def slow_scroll(pg, px, steps=30, pause=120):
    for _ in range(steps):
        await pg.mouse.wheel(0, px / steps); await pg.wait_for_timeout(pause)


async def open_job(pg, job):
    """the job's analysis: its row clicked when the page is open (a new #hash alone does not reload it)"""
    if pg.url.startswith(APP):
        await pg.evaluate("window.scrollTo({top: 0, behavior: 'smooth'})"); await pg.wait_for_timeout(800)
        await pg.locator(f"#jobs tr[data-id='{job}']").click()
    else:
        await pg.goto(APP + "#" + job)
    await pg.wait_for_selector("#detail:not([hidden])")
    await pg.wait_for_function(f"document.querySelector('#d-title').textContent.startsWith('{job}')", timeout=30000)
    await pg.wait_for_timeout(1500)


async def upload(pg, path, region=None, date=None):
    await pg.check("input[name=kind][value=genome]")
    await pg.set_input_files("#g1", path); await pg.wait_for_timeout(800)
    if region:
        await pg.click("details.meta summary"); await pg.wait_for_timeout(500)
        await pg.locator("#u-region").press_sequentially(region, delay=90)
        await pg.fill("#u-date", date); await pg.wait_for_timeout(600)
    await pg.click("#go")
    await pg.wait_for_function("document.querySelector('#msg').textContent.startsWith('Started')", timeout=60000)
    return (await pg.text_content("#msg")).split()[1].rstrip(".")


# ── the takes ──────────────────────────────────────────────────────────────────────────────────────────────────────

async def front(b, s):
    async with Take(b, "front") as t:
        await t.pg.goto(SITE + "/"); await t.pg.wait_for_timeout(2500)
        await slow_scroll(t.pg, 1300, 40, 150); await t.pg.wait_for_timeout(1500)
        await scroll_to(t.pg, "#results"); await t.pg.wait_for_timeout(3500)
        await scroll_to(t.pg, "#try"); await t.until()


async def login(b, s):
    async with Take(b, "login") as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#l-user"); await pg.wait_for_timeout(1500)
        await pg.locator("#l-user").press_sequentially("film-analyst", delay=90)
        await pg.locator("#l-pw").press_sequentially(USERS["film-analyst"][0], delay=60)
        await pg.wait_for_timeout(700)
        await pg.locator("#l-code").press_sequentially(code("film-analyst"), delay=160)
        await pg.wait_for_timeout(800)
        await pg.click("#login-form button"); await pg.wait_for_selector("#who:not([hidden])")
        await pg.wait_for_timeout(2000); await t.until()


async def upload_take(b, s):
    async with Take(b, "upload", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1500)
        job = await upload(pg, f"{GENOMES}/NC_045512.2-A23403G.fasta", "BG-22", "2026-11-19")
        STATE["d614g"] = job; save()
        await pg.locator(f"#jobs tr[data-id='{job}']").click()
        await pg.wait_for_selector("#detail:not([hidden])")
        await scroll_to(pg, "#detail"); await t.until()
    wait_job("film-analyst", STATE["d614g"])


async def result(b, s):
    async with Take(b, "result", s["film-analyst"]) as t:
        pg = t.pg
        await open_job(pg, STATE["d614g"]); await scroll_to(pg, "#detail"); await pg.wait_for_timeout(4000)
        await scroll_to(pg, "#d-lineage-wrap", "center"); await pg.wait_for_timeout(5000)
        await scroll_to(pg, "#d-place-wrap", "center"); await pg.wait_for_timeout(4500)
        await scroll_to(pg, "#d-mut", "center")
        await pg.locator("#d-mut summary").first.click(); await pg.wait_for_timeout(3500)
        await scroll_to(pg, "#d-know", "center"); await pg.wait_for_timeout(4500)
        await pg.locator("#d-prov").first.evaluate("e => e.closest('details') && (e.closest('details').open = true)")
        await scroll_to(pg, "#d-prov", "center"); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#d-exports", "center"); await t.until()


async def paste(b, s):
    seq = "".join(l.strip() for l in open(f"{GENOMES}/PQ737359.fasta") if not l.startswith(">")).replace("T", "U")
    async with Take(b, "paste", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1200)
        await pg.check("input[name=kind][value=manual]"); await pg.wait_for_timeout(700)
        await pg.check("input[name=moltype][value=rna]"); await pg.wait_for_timeout(700)
        await pg.fill("#m-name", ""); await pg.locator("#m-name").press_sequentially("PQ737359-as-RNA", delay=70)
        await pg.locator("#m-seq").press_sequentially(seq[:90], delay=25)
        await pg.fill("#m-seq", seq); await pg.wait_for_timeout(800)
        await pg.click("#go")
        await pg.wait_for_function("document.querySelector('#msg').textContent.startsWith('Started')", timeout=60000)
        STATE["rsva"] = (await pg.text_content("#msg")).split()[1].rstrip("."); save()
        await t.until()
    wait_job("film-analyst", STATE["rsva"])


async def reads(b, s):
    async with Take(b, "reads", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1200)
        await pg.check("input[name=kind][value=reads]"); await pg.wait_for_timeout(700)
        await pg.set_input_files("#r1", f"{IN}/BA2-sample_R1.fastq"); await pg.wait_for_timeout(600)
        await pg.set_input_files("#r2", f"{IN}/BA2-sample_R2.fastq"); await pg.wait_for_timeout(600)
        await pg.click("details.meta summary"); await pg.wait_for_timeout(400)
        await pg.locator("#u-region").press_sequentially("BG-22", delay=90); await pg.fill("#u-date", "2026-11-19")
        await pg.click("#go")
        await pg.wait_for_function("document.querySelector('#msg').textContent.startsWith('Started')", timeout=120000)
        STATE["reads"] = (await pg.text_content("#msg")).split()[1].rstrip("."); save()
        await pg.locator(f"#jobs tr[data-id='{STATE['reads']}']").click()
        await pg.wait_for_selector("#detail:not([hidden])"); await scroll_to(pg, "#detail"); await t.until()
    wait_job("film-analyst", STATE["reads"])


async def reads_result(b, s):
    async with Take(b, "reads_result", s["film-analyst"]) as t:
        pg = t.pg
        await open_job(pg, STATE["reads"]); await scroll_to(pg, "#d-steps", "center"); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#d-cons-wrap", "center"); await pg.wait_for_timeout(4000)
        await scroll_to(pg, "#d-lineage-wrap", "center"); await t.until()


async def rsv(b, s):
    async with Take(b, "rsv", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1000)
        job = await upload(pg, f"{GENOMES}/LC817403.fasta")
        STATE["rsvb"] = job; save()
        await open_job(pg, STATE["rsva"]); await scroll_to(pg, "#d-class", "center"); await pg.wait_for_timeout(3500)
        await scroll_to(pg, "#d-lineage-wrap", "center"); await pg.wait_for_timeout(5000)
        wait_job("film-analyst", job)
        await open_job(pg, job); await scroll_to(pg, "#d-lineage-wrap", "center"); await t.until()


async def many(b, s):
    async with Take(b, "many", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(2500)
        await open_job(pg, STATE["seed"]); await scroll_to(pg, "#d-class", "start"); await pg.wait_for_timeout(3000)
        await slow_scroll(pg, 1400, 40, 150); await scroll_to(pg, "#d-lineage-wrap", "start")
        await slow_scroll(pg, 900, 30, 150); await t.until()


async def tree(b, s):
    async with Take(b, "tree", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1500)
        for j in (STATE["seed"], STATE["d614g"], STATE["reads"]):
            await pg.check(f"[data-tick='{j}']"); await pg.wait_for_timeout(500)
        await pg.select_option("#t-method", "nj"); await pg.fill("#t-boot", "100"); await pg.wait_for_timeout(700)
        await pg.click("#t-go")
        await pg.wait_for_function("document.querySelector('#t-msg').textContent.startsWith('Started')", timeout=60000)
        STATE["tree"] = (await pg.text_content("#t-msg")).split()[1].rstrip(":"); save()
        await pg.wait_for_selector("#d-tree svg", timeout=600000); await scroll_to(pg, "#d-tree-wrap")
        await pg.wait_for_timeout(3500)
        await pg.locator("#tz-find").press_sequentially("A23403G", delay=110); await pg.wait_for_timeout(1500)
        hit = pg.locator("#d-tree text.leaf.hit").first
        await scroll_to(pg, "#d-tree", "center")
        for _ in range(2):                                  # the wheel zooms at the pointer: onto the genome found
            box = await hit.bounding_box()
            await pg.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
            await pg.mouse.wheel(0, -120); await pg.wait_for_timeout(450)
        await pg.wait_for_timeout(2500)
        tb = await pg.locator("#d-tree svg").bounding_box()
        await pg.mouse.move(tb["x"] + tb["width"] * .6, tb["y"] + tb["height"] * .5)
        await pg.mouse.down(); await pg.mouse.move(tb["x"] + tb["width"] * .6, tb["y"] + tb["height"] * .5 - 160, steps=30)
        await pg.mouse.up(); await pg.wait_for_timeout(1800)
        await pg.mouse.move(tb["x"] + tb["width"] * .6, tb["y"] + tb["height"] * .5 - 160)
        await pg.mouse.down(); await pg.mouse.move(tb["x"] + tb["width"] * .6, tb["y"] + tb["height"] * .5, steps=30)
        await pg.mouse.up(); await pg.wait_for_timeout(1500)
        await t.until()
        await hit.click(); await pg.wait_for_timeout(2500)


async def structure(b, s):
    t = Take(b, "structure", s["film-analyst"])
    t.extra = {1: "structure_view"}
    async with t:
        pg = t.pg
        await open_job(pg, STATE["d614g"]); await scroll_to(pg, "#d-lineage-wrap", "center"); await pg.wait_for_timeout(2500)
        STATE["structure_at"] = round(max(0.0, time.time() - t.t0 - 2.0), 2); save()
        async with t.c.expect_page() as pop:
            await pg.click("[data-view]")
        view = await pop.value
        await view.wait_for_load_state("networkidle", timeout=60000)
        await t.until("structure")
        await view.bring_to_front()
        t0 = time.time()
        await view.wait_for_timeout(6000)
        await view.mouse.wheel(0, 600); await view.wait_for_timeout(5000)
        await view.mouse.wheel(0, 900); await view.wait_for_timeout(5000)
        rest = need("structure_view") + need("structure") - (time.time() - t.t0)
        await view.wait_for_timeout(int(max(rest, 3) * 1000))


async def rsvb_note(b, s):
    async with Take(b, "rsvb_note", s["film-analyst"]) as t:
        await open_job(t.pg, STATE["rsvb"]); await scroll_to(t.pg, "#d-lineage-wrap", "center"); await t.until()


async def monitor(b, s):
    async with Take(b, "monitor", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1500)
        await scroll_to(pg, "#monitor", "start"); await pg.wait_for_timeout(4000)
        await pg.evaluate("window.scrollTo({top: 0, behavior: 'smooth'})"); await pg.wait_for_timeout(800)
        STATE["mpox"] = await upload(pg, f"{IN}/NC_063383.fasta"); save()
        await scroll_to(pg, "#alerts", "center")
        await pg.wait_for_function("document.querySelectorAll('#alerts li').length > 1 || "
                                   "!/None since/.test(document.querySelector('#alerts').textContent)", timeout=300000)
        await t.until()


async def trends(b, s):
    async with Take(b, "trends", s["film-admin"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1500)
        await scroll_to(pg, "#trends"); await pg.wait_for_timeout(5000)
        await pg.select_option("#t-region", index=1); await pg.wait_for_timeout(3000)
        await pg.select_option("#t-region", index=0); await pg.wait_for_timeout(2000)
        await scroll_to(pg, "#t-alerts", "center"); await pg.wait_for_timeout(3500)
        await scroll_to(pg, "#t-settings", "center"); await t.until()


async def exchange(b, s):
    async with Take(b, "exchange", s["film-admin"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1000)
        await scroll_to(pg, "#t-import", "center"); await pg.wait_for_timeout(3000)
        await pg.set_input_files("#t-import", f"{IN}/simulated-lab-2.json"); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#t-sites", "center"); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#t-alerts", "center"); await t.until()


async def share(b, s):
    async with Take(b, "share", s["film-admin"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1200)
        for j in (STATE["seed"], STATE["d614g"]):
            await pg.check(f"[data-tick='{j}']"); await pg.wait_for_timeout(500)
        await scroll_to(pg, "#datasets"); await pg.wait_for_timeout(1500)
        await pg.locator("#ds-title").press_sequentially("SARS-CoV-2, autumn 2026 (public genomes)", delay=55)
        await pg.locator("#ds-desc").press_sequentially("For the GenHub2 film: public GenBank genomes.", delay=45)
        await pg.select_option("#ds-consent", ["DUO:0000006", "DUO:0000019"]); await pg.wait_for_timeout(1500)
        await pg.click("#ds-go"); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#ds-list", "center"); await t.until()


async def beacon(b, s):
    async with Take(b, "beacon", s["film-researcher"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(2000)
        await scroll_to(pg, "#beacon"); await pg.wait_for_timeout(1500)
        await pg.locator("#b-mut").press_sequentially("A23403G", delay=110); await pg.wait_for_timeout(600)
        await pg.locator("#b-form button").click(); await pg.wait_for_timeout(4000)
        await pg.fill("#b-mut", ""); await pg.locator("#b-lin").press_sequentially("XBB.1.5", delay=110)
        await pg.locator("#b-form button").click(); await pg.wait_for_timeout(3000)
        await scroll_to(pg, "#datasets", "start"); await t.until()


async def account(b, s):
    async with Take(b, "account", s["film-analyst"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1200)
        await scroll_to(pg, "#account", "center"); await pg.wait_for_timeout(3000)
        await pg.locator("#me-old").click(); await t.until()


async def admin(b, s):
    async with Take(b, "admin", s["film-admin"]) as t:
        pg = t.pg
        await pg.goto(APP); await pg.wait_for_selector("#who:not([hidden])"); await pg.wait_for_timeout(1200)
        # privacy: accounts other than the film's are blurred (the site owner's own account is not for the film)
        await pg.add_style_tag(content="#a-users tbody tr.other { filter: blur(6px); }")
        await pg.evaluate("""() => { const mark = () => document.querySelectorAll('#a-users tbody tr').forEach(r => {
            if (!r.textContent.trim().startsWith('film-')) r.classList.add('other'); });
          mark(); new MutationObserver(mark).observe(document.querySelector('#a-users'), {childList: true, subtree: true}); }""")
        await scroll_to(pg, "#admin"); await pg.wait_for_timeout(3500)
        await pg.locator("#a-name").press_sequentially("new-analyst", delay=90); await pg.wait_for_timeout(2500)
        await pg.fill("#a-name", "")
        await scroll_to(pg, "#a-verify", "start"); await pg.wait_for_timeout(2000)
        await slow_scroll(pg, 700, 30, 160); await t.until()


TAKES = {"front": front, "login": login, "upload": upload_take, "result": result, "paste": paste, "reads": reads,
         "reads_result": reads_result, "rsv": rsv, "many": many, "tree": tree, "structure": structure,
         "rsvb_note": rsvb_note, "monitor": monitor, "trends": trends, "exchange": exchange, "share": share,
         "beacon": beacon, "account": account, "admin": admin}


async def main():
    names = sys.argv[1:] or list(TAKES)
    async with async_playwright() as p:
        b = await p.chromium.launch()
        s = {u: await logged_in(b, u) for u in ("film-admin", "film-analyst", "film-researcher")}
        for n in names:
            await TAKES[n](b, s)
        await b.close()

asyncio.run(main())
