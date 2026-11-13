# Phase A acceptance: results

GenHub2 on one node (an NVIDIA DGX Spark, 10 of its 20 cores), with PQCF's local executor, 13 November 2026.
Results file: [`results/phase-a-dgx-spark-2026-11-13T2017Z.json`](results/phase-a-dgx-spark-2026-11-13T2017Z.json).
How it is run: [`run.sh`](run.sh) and [`gh_acceptance.erl`](gh_acceptance.erl). The genomes it used are listed in
[`held-out.tsv`](held-out.tsv) and [`sars-cov-2.tsv`](sars-cov-2.tsv).

**All 17 checks hold.**

## Reference database

All 19,607 complete viral genomes in NCBI RefSeq, from NCBI Datasets, each labelled with its species, genus and
family from NCBI Taxonomy. They are sketched with MinHash (K = 21, 1,000 hashes a genome; Mash, Ondov et al. 2016,
[doi:10.1186/s13059-016-0997-x](https://doi.org/10.1186/s13059-016-0997-x)).

## 1. The SARS-CoV-2 example (FS section 13)

| input | result | time |
| --- | --- | --- |
| NC_045512.2 (Wuhan-Hu-1) uploaded as a genome | *Betacoronavirus pandemicum*; 0 mutations against itself; lineage B, clade 19A | 1.4 s end to end |
| reads: 20,000 pairs simulated from the GenBank genome PX916490.1 (BQ.1.1; its record names Bulgaria), plus 20,000 human pairs (GRCh38 chr1:150-160 Mb) | all 20,000 human pairs removed and all 20,000 viral pairs kept; consensus at 200x depth covers 99.2% of the genome and equals the source at every called base; *Betacoronavirus pandemicum*; lineage BQ.1.1 | 49 s, of which 47 s is loading the 8.7 GB human index to remove human reads |

Each step is a PQCF task, and its result is stored in Mnesia with its provenance record: the task's hash, the code's
checksum, the node and the times.

## 2. Held-out genomes from NCBI Virus

- **The set:** 600 GenBank genomes requested, 20 each from 30 viruses that matter to Bulgarian labs, including
  Crimean-Congo haemorrhagic fever, West Nile, tick-borne encephalitis and Dobrava-Belgrade viruses. None is a
  RefSeq record.
- **Left out:** 3 genomes identical to a RefSeq genome, and 4 that NCBI Datasets did not return. 593 were
  classified.
- **The call:** the species of the nearest RefSeq genome by Mash distance.

| | species | genus | family |
| --- | --- | --- | --- |
| all 593 | 564 (95.1%) | 572 of 573 (99.8%) | 591 (99.7%) |
| high confidence (identity >= 0.95): 275 | 274 (99.6%) | 100% | 100% |
| medium (0.85-0.95): 185 | 182 (98.4%) | 100% | 100% |
| low (< 0.85): 132 | 108 (81.8%) | 100% | 131 (99.2%) |
| unclassified (no shared hashes): 1 | 0 | 0 | 0 |

The 29 species misses:
- **18 are hepatitis E naming:** NCBI files these GenBank genomes under the species node "Hepatitis E virus", while
  the RefSeq genome carries the current ICTV species name, *Paslahepevirus balayani*. GenHub2 named the right virus,
  but the labels differ. The table counts them as misses.
- **5 tick-borne encephalitis genomes** were nearest to Spanish goat encephalitis virus (identity 0.80-0.85).
- **4 rotavirus A segments** were nearest to rotaviruses of other species, all at low confidence.
- **1 rabies genome** was nearest to another lyssavirus.
- **1 human metapneumovirus genome** shared no hashes with any reference.

These are the limits of nucleotide MinHash for divergent genomes. In the plan, that is where a protein-level or
learned classifier would have to show it does better on held-out data before it is adopted.

Classifying the 593 genomes took 0.55 s.

## 3. 1,000 SARS-CoV-2 genomes: our mutations against Nextclade's

The genomes: the 138 complete SARS-CoV-2 genomes whose GenBank records name Bulgaria (Entrez `Bulgaria[All Fields]`),
and 862 published in June of 2020-2024 (197 Pango lineages). Mutations against Wuhan-Hu-1 come from minimap2 (Li 2018,
[doi:10.1093/bioinformatics/bty191](https://doi.org/10.1093/bioinformatics/bty191)). They are compared with
Nextclade's (Aksamentov et al. 2021, [doi:10.21105/joss.03773](https://doi.org/10.21105/joss.03773)), genome by
genome.

- **885 of 1,000 genomes have identical substitutions.** Of the 843 genomes Nextclade rates "good", 745 are
  identical.
- **The 104 differing substitutions in the good genomes all lie at known aligner differences:**
  - **96 at the genome ends.** minimap2 clips mismatches at the ends of an alignment, while Nextclade aligns to the
    end.
  - **8 within 10 bases of an indel**, where the two aligners place the same change differently (for example around
    the 9-base deletion at 28362-28370).
  - None lies elsewhere.
- **Time:** 1.5 s for our mutations, 5.1 s for Nextclade.

## 4. The specification's targets (FS 3.5), measured

| target | measured | |
| --- | --- | --- |
| a 10 MB upload processed in under 5 s | 4.5 s for 327 genomes (9.99 MB): validate 0.17 s, classify 0.50 s, mutations 1.04 s, lineage 2.80 s | met |
| 1,000 sequences classified in under 60 s | 0.69 s (10 PQCF tasks of 100 genomes) | met |
| trees of 1,000 sequences in under 5 minutes | neighbour-joining (Saitou and Nei 1987, [doi:10.1093/oxfordjournals.molbev.a040454](https://doi.org/10.1093/oxfordjournals.molbev.a040454)) of the 1,000 genomes and the reference: 4.0 s | met |
| (no target) maximum likelihood | FastTree 2 (Price et al. 2010, [doi:10.1371/journal.pone.0009490](https://doi.org/10.1371/journal.pone.0009490)), 10 threads: 703 s | measured |

Separate timing runs of FastTreeMP on the same alignment:
- default options: 690 s;
- `-nosupport`: 550 s;
- `-nosupport -fastest`: 488 s.

A maximum-likelihood tree of 1,000 complete SARS-CoV-2 genomes therefore takes 8-12 minutes on 10 cores. Speeding
that up is work for later phases: the trees could be spread over the federation, or a new genome could be placed in
an existing tree.

**Reproducibility:** both trees came out byte for byte the same in two runs (Newick SHA-256 `b06e5e9f...` for
neighbour-joining, `4c441ab1...` for FastTree).

## 5. The gateway, MQTT, exports and monitoring (FS 3.1, 4.2-4.4, 5.4)

[`gh_gateway_check.erl`](gh_gateway_check.erl), run by [`run_gateway.sh`](run_gateway.sh) against EMQX 5.8.9, on a site
with no earlier jobs. Results: [`results/gateway-dgx-spark-2026-11-13T2243Z.json`](results/gateway-dgx-spark-2026-11-13T2243Z.json).
**All 13 checks hold.**

- **The page:** the page and its script are served.
- **A job through the API:** NC_045512.2 is uploaded and analysed. It comes back as *Betacoronavirus pandemicum*;
  the job is listed, and the uploaded file is served back unchanged.
- **MQTT:** an outside subscriber to `genhub/#` received the job on the specification's topics:
  `genhub/sequences/new`, `genhub/tasks/status`, `genhub/results/classification` (which names the species),
  `genhub/results/mutations`, `genhub/results/knowledge` and `genhub/alerts`.
- **WebSocket:** the browser's WebSocket received the same topics.
- **A job requested on MQTT:** a message on `genhub/sequences/new`, published as a sequencer's integration would,
  started a job, and it finished.
- **Exports:** the CSV names the species, the PDF is a PDF, and the JSON is the job.
- **A tree job of both genomes:** it finished, its SVG is drawn, and its leaves are the reference and the two
  genomes, each named after its job.
- **Monitoring:** two SARS-CoV-2 analyses, with lineage B first seen in the first job.
- **Alerts:** the first species and the first lineage raised one alert each, for the first job only.
- **Refused:**
  - a job for a file that is not in the store: 400;
  - an unknown kind of job: 400;
  - an upload over 100 MB: 413;
  - an unknown job: 404;
  - a tree of one sequence: 400.

The page was also looked at in Chromium, at 1280 px and at a phone's 390 px (no horizontal scrolling); the PDF
report and the tree drawings were looked at too.
