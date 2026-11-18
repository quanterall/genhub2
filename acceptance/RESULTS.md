# Phase A acceptance: results

GenHub2 on one node (an NVIDIA DGX Spark, 10 of its 20 cores), with PQCF's local executor, 14 November 2026.
Results file: [`results/phase-a-dgx-spark-2026-11-14T0031Z.json`](results/phase-a-dgx-spark-2026-11-14T0031Z.json).
How it is run: [`run.sh`](run.sh) and [`gh_acceptance.erl`](gh_acceptance.erl). The genomes it used are listed in
[`held-out.tsv`](held-out.tsv) and [`sars-cov-2.tsv`](sars-cov-2.tsv).

**All 20 checks hold.**

## Reference database

All 19,607 complete viral genomes in NCBI RefSeq, from NCBI Datasets, each labelled with its species, genus and
family from NCBI Taxonomy. They are sketched with MinHash (K = 21, 1,000 hashes a genome; Mash, Ondov et al. 2016,
[doi:10.1186/s13059-016-0997-x](https://doi.org/10.1186/s13059-016-0997-x)).
The snapshot (13 November 2026), its accession list, checksums and how to check a rebuilt copy:
[REFERENCE-DATA.md](REFERENCE-DATA.md).

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

These are the limits of nucleotide MinHash for divergent genomes. A protein-level classifier was added for them
(section 2b).

Classifying the 593 genomes took 0.55 s.

## 2b. Classification by proteins, for MinHash's weak calls

Every held-out genome was also classified by its proteins: DIAMOND blastx (Buchfink et al. 2021,
[doi:10.1038/s41592-021-01101-x](https://doi.org/10.1038/s41592-021-01101-x)) against all 720,495 proteins of the
complete RefSeq viral genomes. Each region of the genome votes for its best hit's species by bit score.
- **The protein database:** for genes without a protein record (among them the rabies and Zaire ebolavirus RefSeq
  genomes), NCBI's protein file holds the coding sequence; those 1,462 records are translated (standard code).
- **The combination:** GenHub2 uses the protein call where MinHash's is low or missing, and MinHash's elsewhere.

| species right | MinHash alone | proteins alone | combined |
| --- | --- | --- | --- |
| all 593 | 564 (95.1%) | 547 (92.2%) | **572 (96.5%)** |
| MinHash high confidence: 275 | 274 | 255 | 274 |
| MinHash medium: 185 | 182 | 183 | 182 |
| MinHash low: 132 | 108 | 108 | **115** |
| MinHash unclassified: 1 | 0 | 1 | **1** |

- **Family:** right for all 593 when combined, up from 591.
- **Proteins alone are worse at high confidence:** closely related species share near-identical proteins, which is
  why the protein call only replaces MinHash's weak calls.
- **Time:** the protein search of all 593 genomes took 34 s.

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
with no earlier jobs.
- **18 November 2026, with accounts, placement, aggregates, sharing, metrics, Beacon and alert settings:** **all 42
  checks hold** ([`results/gateway-dgx-spark-2026-11-18T0244Z.json`](results/gateway-dgx-spark-2026-11-18T0244Z.json); the check of
  encryption at rest in `warn` mode: this test machine's disk is not encrypted).
  - The 13 below now run as an analyst who logged in through the API.
  - 8 more cover accounts and the audit log (at the end of this section).
  - 1 covers placement: the site's SARS-CoV-2 tree is built from phase A's 1,000 public genomes, and the genome
    job places its genome in it (step `place`, UShER). Wuhan-Hu-1 lands in lineage B with parsimony 0, with 7
    equally good placements among identical genomes.
  - The first run found that UShER does not place a genome named like a sample already in the tree (here the
    reference itself). GenHub2 now gives each genome a name of its own for UShER, and maps the results back.
  - 5 cover the aggregated counts of phase D at the site: the genome job is uploaded with a region and collection
    date ([RESULTS-PHASE-D.md](RESULTS-PHASE-D.md), "At a site").
  - 7 cover sharing (below).
  - 5 cover Beacon (below).
  - 2 cover alert thresholds and notifications: only an admin changes them, values are checked, and changes are
    audited. Each new lineage of the merged counts is published once on `genhub/alerts`, as it appears: B when the
    genome job with metadata is first counted, then Z.9 with the other site's import.
  - 1 covers the metrics for Prometheus (`/metrics`): refused without the scrape token or with a wrong one, served
    with it, with counts only (no user, job or genome names).
- **14 November 2026, before accounts:** all 13
  ([`results/gateway-dgx-spark-2026-11-14T0102Z.json`](results/gateway-dgx-spark-2026-11-14T0102Z.json)).

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

**Accounts and the audit log** (FS 3.1, 3.4), the 8 checks added on 17 November:
- **Without a session:** the page is served; the API and the WebSocket answer 401.
- **Refused logins and requests:** a wrong one-time code, 401; a changing request without the header
  `x-genhub2: 1`, 403.
- **Roles:**
  - an analyst cannot see the users or the audit log (403);
  - a researcher sees the site's counts, and nothing else: jobs, uploads and the WebSocket answer 403.
- **Sessions:** logout ends the session.
- **Administration:** an admin creates a user, who logs in with the one-time secret shown once; disabling the user
  ends their session.
- **The audit log** holds every kind of record the check expects:
  - the logins, also the refused one;
  - the upload, the job submissions (the one started on MQTT too, as `mqtt`);
  - the export and the file download;
  - the alerts (as `system`);
  - the researcher's refused request;
  - the user's creation and disabling, the logout.

  Its chain of 42 records is whole.

**Sharing** (FS 3.3, 3.4; phase C, the part inside a lab), the 7 checks added on 17 November:
- **Approval:** an admin approves a dataset of the two genome jobs, with consent DUO:0000042 (general research use,
  [GA4GH DUO](https://www.ga4gh.org/product/data-use-ontology-duo/)). An analyst cannot; an unknown DUO code and a
  tree job are refused.
- **Through GA4GH DRS** ([GA4GH](https://www.ga4gh.org/product/data-repository-service-drs/)), as a researcher:
  - the dataset is a bundle of two files, `genomes.fasta` and `results.json`;
  - each file's DRS id and checksum are its SHA-256, and each download matches them.
- **Anonymised:**
  - the genomes are renamed after the dataset (`<dataset>-1`, `-2`), with no job id and no sample name, not even
    the reference's own;
  - the results give the week of collection (2026-W46) and the region, not the date.
- **Only what is approved:** a file outside approved datasets (the uploaded genome itself) is not served (404).
  Once the dataset is withdrawn, it and its files are gone (404).
- **Audit:** the dataset's creation and withdrawal, and every DRS object read and download, are in the audit log.

**Beacon** ([GA4GH Beacon v2](https://www.ga4gh.org/product/beacon/)), the 5 checks added on 18 November:
- **The test data:** a copy of the reference with one substitution, A23403G (spike D614G), analysed and shared with
  the first genome job as a new dataset.
- **As a researcher:**
  - A23403G is found (`start=23402`, 0-based as in Beacon v2), and a substitution no genome has is not;
  - the filter `lineage:B` finds the dataset;
  - the dataset withdrawn in the sharing part is never searched;
  - asked for counts, the researcher still gets yes or no only.
- **As an analyst:** the count, 1.
- **Refused (400):** no query, a bad start, a bad base, an unknown filter.
- **Listings and audit:** the approved datasets (with their DUO consent) and the lineages as filtering terms are
  listed, and every query is in the audit log.

**The page** was looked at in Chromium:
- 14 November: at 1280 px and at a phone's 390 px (no horizontal scrolling); the PDF report and the tree drawings too.
- 17 November, with accounts: the login form, an admin's page and a researcher's page, at 1280 px and 390 px. This
  found and fixed two things:
  - the analyses showed under the login form, because the layout overrode `hidden`;
  - the tree-method list was 7 px wider than a phone's screen.

  Logging out brings the login form back, and the page is exactly 390 px wide on a phone.
- 18 November, the spec's remaining page functions (FS 3.1):
  - **Manual entry:** a sequence typed as RNA (3,000 bases of Wuhan-Hu-1, with U) was validated as RNA, classified
    as SARS-CoV-2, and stored with its region and collection date. A "DNA" sequence with a U is refused in the page.
  - **Trends:** the trends table counted it by week and lineage, and the merged alerts listed its lineage as new.
  - **Settings:** an admin saved new alert thresholds; an analyst does not see the form. At 1280 and 390 px, with no
    horizontal scrolling.

## 6. The added methods, each against what it adds to

[`gh_methods_check.erl`](gh_methods_check.erl), run by [`run_methods.sh`](run_methods.sh), on phase A's data, 14 November
2026. Results: [`results/methods-dgx-spark-2026-11-14T0044Z.json`](results/methods-dgx-spark-2026-11-14T0044Z.json).
**All 9 checks hold.**

### Maximum-likelihood trees: VeryFastTree

VeryFastTree (Piñeiro et al. 2020, [doi:10.1093/gigascience/giaa055](https://doi.org/10.1093/gigascience/giaa055)) is
FastTree's algorithm, parallel.

| tree of the 1,000 SARS-CoV-2 genomes and the reference | time (10 cores) |
| --- | --- |
| neighbour-joining (gh2k) | 3.5 s |
| FastTree 2.1.11, 10 threads | 698 s |
| **VeryFastTree 4.0.5, 10 threads** | **250 s**, within the 5-minute target |

Does VeryFastTree's tree agree with FastTree's? It writes no branch of 1e-4 substitutions per site or shorter, so it
orders near-identical genomes arbitrarily and always has 991 splits. FastTree has far fewer once its zero-length
branches are collapsed. So the measure is how many of FastTree's splits each other tree contains:

| FastTree's branches shorter than | FastTree's splits | found in VeryFastTree's tree | found in neighbour-joining's |
| --- | --- | --- | --- |
| 1e-05 | 431 | 415 (96%) | 370 (86%) |
| 5e-05 | 251 | 249 (99%) | 211 (84%) |
| 0.0001 | 162 | 162 (100%) | 123 (76%) |

The Robinson-Foulds distance between the two whole trees ([doi:10.1016/0025-5564(81)90043-2](https://doi.org/10.1016/0025-5564(81)90043-2)),
592 (normalised 0.42), is almost all VeryFastTree's extra resolution of
identical genomes.

### Placement in an existing tree: UShER

UShER (Turakhia et al. 2021, [doi:10.1038/s41588-021-00862-7](https://doi.org/10.1038/s41588-021-00862-7)):
- **The tree:** a mutation-annotated tree built from 900 of the 1,000 SARS-CoV-2 genomes (a
  neighbour-joining tree, 3.2 s; building the mutation-annotated tree, 2.0 s),
  labelled with their Nextclade lineages.
- **The placement:** the other 100 genomes, every tenth, placed into it.
- **Results:**
  - all 100 were placed, in 0.8 s for all of them;
  - **69 got exactly their Nextclade lineage**;
  - 84 got their lineage or a parent or child of it (BA.5 for BA.5.2.1).

UShER labels a clade at its root by the samples it was given. 900 genomes spread over five years are thin for the
fine lineages; a site's own growing tree is what it is for.

### Lineages beyond SARS-CoV-2: Nextclade's datasets

The bundle holds 22 datasets:
- SARS-CoV-2;
- influenza HA: H1N1pdm, H3N2, B/Victoria, B, B/Yamagata;
- RSV A and B, mpox, Ebola, measles, hMPV, rubella, mumps, West Nile;
- dengue 1-4, from the community collection.

`nextclade sort --all-matches` sends each held-out genome to the best-scoring dataset the bundle holds.
- **Result:** 178 of the 593 genomes reached a dataset, and every one got a clade. **None reached another
  virus's dataset.**
- **Reached a dataset, by virus:**
  - SARS-CoV-2 18 of 18, mpox 20 of 20, RSV 20 of 20, dengue
    20 of 20;
  - Ebola 19 of 19, West Nile 19 of 19, hMPV 19 of 20;
  - measles 18 of 20, mumps 17 of 20, rubella 6 of 20, influenza B
    2 of 20.
- **Influenza:** the held-out influenza records are mostly segments other than HA, which these datasets do not
  cover. Influenza A reached none.
- **The other 18 viruses** have no dataset here.
- The first run of this check, before `--all-matches`, reached only 121 genomes. Sort's best match was often a dataset
  the bundle does not hold (e.g. `sars-cov-2/BA.2.86`).

### Host removal: Hostile against GRCh38

Hostile (Constantinides et al. 2023, [doi:10.1093/bioinformatics/btad728](https://doi.org/10.1093/bioinformatics/btad728))
uses the T2T human genome with HLA alleles, masked where it resembles RefSeq viruses and phages. The sample: 10,000
read pairs each of SARS-CoV-2, Epstein-Barr virus (NC_007605.1) and human (GRCh38 chr1:150-160 Mb).

| pairs kept | SARS-CoV-2 | EBV | human | time |
| --- | --- | --- | --- | --- |
| minimap2 against GRCh38's analysis set | 10,000 | 0 | 0 | 20 s |
| **Hostile** | 10,000 | **9,951** | 2 | 12 s |

GRCh38's analysis set contains the EBV genome, so removing reads that match it removes a human virus with them.
Hostile is now GenHub2's default.

### Amplicon primers: iVar

iVar (Grubaugh et al. 2019, [doi:10.1186/s13059-018-1618-7](https://doi.org/10.1186/s13059-018-1618-7)). The test:
- **The amplicons:** ARTIC V4.1 amplicons (98; 90 without missing bases) simulated over the
  BQ.1.1 genome PX916490.1, with every read's primer bases taken from the primer, as in PCR.
- **The genome against the primers:** it differs from the primers at 9
  sites.
- **Untrimmed:** reads carrying a primer base disagree there with the overlapping amplicon's reads, and the
  consensus leaves **9 bases N** where the genome has a base.
- **Trimmed** (`ivar trim -e`): 0 N and 0 wrong
  bases, the genome exactly.

### Mixed samples: Kraken 2 + Bracken

Kraken 2 (Wood et al. 2019, [doi:10.1186/s13059-019-1891-0](https://doi.org/10.1186/s13059-019-1891-0)) and Bracken
(Lu et al. 2017, [doi:10.7717/peerj-cs.104](https://doi.org/10.7717/peerj-cs.104)), with the prebuilt viral database
k2_viral_20241228. The sample:
- 6,000 read pairs of SARS-CoV-2, 3,000 of influenza A and 1,000 of RSV;
- 2,000 human read pairs.

| species | in the mixture | Bracken |
| --- | --- | --- |
| Betacoronavirus pandemicum | 60% | 59.6% |
| Alphainfluenzavirus influenzae | 30% | 29.8% |
| Orthopneumovirus hominis | 10% | 9.9% |

There was one false species: BeAn 58058 virus 0.7%,
almost certainly from some of the human reads. Classifying the 12,000 pairs took 0.9 s.
