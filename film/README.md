# GenHub2's film

`genhub2-film.mp4`: every function of GenHub2 in 10 min 45 s, 1920×1080, recorded on genhub2.quanterall.com on
20 November 2026. It is published on the site at `/film/` with English subtitles (`genhub2-film.vtt`). The film
itself is kept outside the repository, in the site's data directory (`media/`).

It is made the way TechUPGRADE's films are:
- **The voice:** Microsoft's neural voice through `edge-tts` (`en-US-AndrewNeural`, −4 %). The narration's text is
  sent to Microsoft's service to be spoken.
- **Title cards:** HTML pages (`cards/`, in GenHub2's colours and type) recorded in a browser.
- **Screen takes:** recorded by Playwright driving the real site.
- **Assembly:** ffmpeg joins the scenes; each scene lasts as long as its narration.

| file | what |
|---|---|
| [`scenes.json`](scenes.json) | the scenario: per scene its narration and its picture |
| [`cards/`](cards/) | the title cards |
| [`seed.py`](seed.py) | off camera: the 60 dated genomes, and the simulated second laboratory's counts |
| [`record.py`](record.py) | the screen takes, as the film accounts |
| [`make_film.py`](make_film.py) | the narration, the cards and the film |
| [`filmsite.py`](filmsite.py) | the site's address, the accounts, one-time codes and API calls |

## What was set up for the film

- **Accounts:** `film-admin`, `film-analyst` and `film-researcher`, made with `scripts/genhub2-admin.sh`. Their
  passwords and authenticator secrets are in `~/genhub2-film/users.txt`, outside the repository.
- **Genomes:** public ones only.
  - The front page's four test genomes.
  - Sixty SARS-CoV-2 genomes from GenBank.
  - The mpox reference NC_063383.1.
  - Read pairs simulated by `gh2k simulate` from ON544943.1, with reads of human chromosome 1 (NC_000001.11,
    150.0–150.2 Mb) mixed in.
- **Assigned for the film, and said so on screen:**
  - the regions and collection dates of the sixty genomes;
  - the second laboratory's counts, as `simulated-lab-2`.
- **One thing hidden:** in the administration take, accounts other than the film's are blurred, so the site owner's
  own account is not shown.
- **Nothing else is staged.** Every result on screen is the site's own.

## Making it again

```sh
P=~/demo-video-venv/bin/python     # edge-tts and playwright
$P make_film.py narrate             # the narration first: each take lasts as long as its scene's
$P seed.py                          # off camera
$P record.py                        # all takes, or the names of some
$P make_film.py                     # -> ~/genhub2-film/genhub2-film.mp4 and .vtt
```

Inputs and takes go to `~/genhub2-film`: `inputs/`, `raw/`, `build/`.
