"""Off camera, before the recording: what the film's scenes need on the site and cannot show being made.
  - 60 public SARS-CoV-2 genomes from GenBank (Bulgarian submissions in phase A's set), uploaded as one file through
    the API with a region and a collection date per genome. The regions and dates are assigned for the film, spread
    over the eight weeks before it, so that the trends have weeks to show. They are not the samples' own.
  - A simulated second laboratory's aggregate (site simulated-lab-2, format genhub2-aggregates/1), written to
    ~/genhub2-film/inputs/simulated-lab-2.json for the exchange scene, to be imported on camera. Its counts are made
    up for the film: the lineages this site saw in the same weeks, and in the last week one it has not seen (JN.1).
    ~/demo-video-venv/bin/python seed.py
"""
import datetime, json, os, re, sys, time
from filmsite import Api, FILM

IN = os.path.join(FILM, "inputs")
REGIONS = ["BG-22", "BG-02", "BG-03", "BG-16"]


def main():
    a = Api("film-analyst")
    fasta = open(os.path.join(IN, "bg60.fa"), "rb").read()
    names = re.findall(rb"^>(\S+)", fasta, re.M)
    today = datetime.date(2026, 11, 20)
    seqs = {}
    for i, n in enumerate(names):
        week = i * 8 // len(names)                        # 0..7: the eight weeks before the film
        d = today - datetime.timedelta(days=7 * (7 - week) + (i % 5))
        seqs[n.decode()] = {"region": REGIONS[i % len(REGIONS)], "collection_date": d.isoformat()}
    up = a.call("POST", "/api/uploads", raw=fasta, ctype="application/octet-stream")
    job = a.call("POST", "/api/jobs", {"kind": "genome", "inputs": [up["hash"]], "metadata": {"sequences": seqs}})
    print("job", job["id"], len(seqs), "genomes")
    while True:
        j = a.call("GET", f"/api/jobs/{job['id']}")
        if j["state"] in ("done", "failed"):
            print(j["state"]); break
        time.sleep(3)


def other_lab():
    """counts only, as a site exports them: no sequences, no sample names"""
    weeks = [f"2026-W{w}" for w in range(40, 48)]
    lin, tot = [], []
    for i, w in enumerate(weeks):
        n = {"XBB.1.5": 3 + i % 3, "XBB.1.16.2": 2 + i % 2}
        if w == weeks[-1]:
            n["JN.1"] = 6                                  # the lineage new to the merged counts
        for l, c in n.items():
            lin.append({"week": w, "region": "BG-04", "lineage": l, "n": c})
        tot.append({"week": w, "region": "BG-04", "n": sum(n.values())})
    agg = {"format": "genhub2-aggregates/1", "site": "simulated-lab-2", "generated": int(time.time() * 1000),
           "lineages": lin, "mutations": [], "totals": tot, "lineage_mutations": []}
    f = os.path.join(IN, "simulated-lab-2.json")
    json.dump(agg, open(f, "w"), indent=1)
    print("wrote", f)


if __name__ == "__main__":
    if sys.argv[1:] == ["other_lab"]:
        other_lab()
    else:
        main(); other_lab()
