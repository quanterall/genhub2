# The reference data of the published acceptance run

What GenHub2 classifies against, where it comes from, and how to tell whether your copy is the one of the published
run ([RESULTS.md](RESULTS.md), 14 November 2026). Each reference set is built once per site by `gh_refdb`
([src/gh_refdb.erl](../src/gh_refdb.erl)), kept in the site's store under its SHA-256, and named in
`data/bundles/<name>`. A bundle is a map from its files to their hashes.

## RefSeq viral genomes (`refseq_viral`)

- **Source:** NCBI Datasets, every complete viral genome in RefSeq: taxon 10239, `refseq_only`, `complete_only`
  (`gh_ncbi:genome_download_url/2`).
- **Snapshot:** downloaded on 13 November 2026, 20:43 EET. NCBI Datasets has no way to ask for an earlier snapshot:
  it serves RefSeq as it is on the day. So the published run's genomes are listed here:
  [refseq-viral-accessions.txt](refseq-viral-accessions.txt), 19,607 accessions, sorted (`LC_ALL=C sort`).
- **Checksums:**

  | file | SHA-256 | size |
  | --- | --- | --- |
  | the sorted accession list | `8e7bc69d461350d3e469c444e5ad77b8ef22c998dd3590add59525fdb2cf4d77` | 19,607 lines |
  | `ncbi_dataset.zip`, as downloaded | `0aca8104d7c9d082c32d6386dad1e03f3acc532eff6263f5471e664424c510bf` | 208 MB |
  | `refs.fasta` | `fbe331a269e37e790fc4f31b732dba2b4c2f44e292969fa4edfdfe6f4eace386` | 566 MB |
  | `refs.sketch` | `cc67cfabe840cc5a3448fef1fd96d3e98c8111a5f61c214ce20731d8962e40a1` | 372 MB |
  | `taxonomy.tsv` | `90d926c1486e1acc7574e7bdbe7da4031b5fcfff58d76e7465143f15a85514f6` | 1.8 MB |
  | the bundle (`data/bundles/refseq_viral`) | `29e42c18e59a4409bad717596cc00839fed889a0d2944a65d0caab7bf45bbd32` | |

  To compare a later download with this one, compare the accession lists: a revised sequence gets a new version
  (`.2` for `.1`), so the list changes with the genomes.
- **Taxonomy:** each genome's species, genus and family from NCBI Taxonomy, from the dataset's own reports
  (`gh_refdb:taxonomy_tsv/2`).
- **MinHash** ([native/gh2k/src/minhash.rs](../native/gh2k/src/minhash.rs), after Mash, Ondov et al. 2016,
  [doi:10.1186/s13059-016-0997-x](https://doi.org/10.1186/s13059-016-0997-x)): K = 21, S = 1,000 (Mash's defaults);
  canonical K-mers (a K-mer and its reverse complement hash alike), K-mers with other letters than A, C, G, T skipped;
  64-bit hashes by splitmix64's finaliser, the same on every platform; the S smallest distinct hashes of each genome.
  The sketch file holds every sketch and an index of (hash, reference) pairs. `gh2k sketch` is deterministic: the
  same FASTA gives the same file, byte for byte.

## RefSeq viral proteins (`refseq_viral_proteins`)

- **Source:** the same NCBI Datasets query, with `include_sequence=PROTEIN`, downloaded on 14 November 2026.
- **Contents:** 721,957 proteins; 1,462 of them translated by GenHub2 (standard code) from coding sequences that NCBI
  ships without a protein record (for example the rabies and Zaire ebolavirus genomes), listed in `translated.txt`.
  Each protein carries its genome's taxonomy (`taxonomy.tsv`).
- **Database:** `diamond makedb` (DIAMOND, the version pinned in [docker/Dockerfile](../docker/Dockerfile)).
- **Checksums:** `proteins.dmnd` `c72baff326b3b2a47458a5b2707923d651d41dc89005574a193a8d18d8aa2be7` (237 MB),
  `taxonomy.tsv` `99be8f803b279b2d50c18484f8c4d8588ce9ab5b8c0555d4101b63a1a5e0d0c1`, `translated.txt`
  `26cfe25a8d12208e7da8e096cde80855c909379a5f31f1bfbf9cf7335addaa2b`.

## The other reference sets

| bundle | what | its hash in the published run |
| --- | --- | --- |
| `host` | GRCh38's no-alt analysis set, minimap2 index (`-x sr`), 8.7 GB ([REPRODUCE.md](REPRODUCE.md), step 2: NCBI's MD5 checked) | `9a2eee446c59c423...` |
| `nextclade-sars-cov-2-2026-10-28--15-04-26Z` | Nextclade's SARS-CoV-2 dataset at that tag | `39b70eee8919fba4...` |
| `kraken-k2_viral_20241228` | Kraken 2's viral database of 28 December 2024 (methods check only) | `680790dcacd7360d...` |
| `primers-artic-v4.1` | the ARTIC v4.1 primer scheme (methods check only) | `9462de26eb82a273...` |
| `hostile` | Hostile's human index (methods check only) | `54dcd088293aa8f2...` |

These are fixed by their names: the tag, the date or the version is part of what is downloaded.

## Rebuilding, and checking your copy

The bundles are built on first use: the acceptance run ([REPRODUCE.md](REPRODUCE.md), step 4) builds `refseq_viral`
(the download, then the sketches: about 8 minutes on 10 cores, downloads included) and `refseq_viral_proteins` (the
download and `diamond makedb`). To build them again, delete `data/bundles/refseq_viral` (or `_proteins`); the
store keeps the old files under their hashes.

Then compare your genomes with the published run's:

```sh
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" genhub2-dev sh acceptance/check_reference.sh
```

It prints the number of genomes and the accession list's checksum for both, and `the same reference genomes`, or
how many were added and removed since (exit 1). On 16 November 2026 NCBI Datasets still listed 19,607 complete RefSeq
viral genomes. With genomes added, the held-out results can change where a new RefSeq genome is nearer than the old
nearest one.

## Updating a site's reference data from NCBI

A site keeps the RefSeq snapshot it built first until its operator updates it, with the site stopped
(`scripts/genhub2-admin.sh`, `gh_refdb:check_update/0` and `apply_update/0`):

```sh
sh scripts/genhub2-admin.sh data/mnesia check_references   # NCBI's current RefSeq viral genomes against the site's
sh scripts/genhub2-admin.sh data/mnesia apply_references   # the checked bundle becomes the site's
```

- **`check_references`** downloads NCBI's current RefSeq viral genomes, not from the cache. It then decides:
  - **unchanged:** the download is byte for byte the site's;
  - **unchanged in content:** a new download whose references, taxonomy and sequences are all the site's. NCBI's
    archive changes with its metadata. Nothing is staged, so results keep naming the same bundle.
  - **changed:** the new bundle is built beside the site's (`bundles/refseq_viral.next`), with a report
    (`refseq_viral.next.json`) of the accessions added and removed, and those whose taxonomy or sequence changed.
- **`apply_references`** makes the checked bundle the site's and keeps the one before (`refseq_viral.previous`). It
  rebuilds the protein database from NCBI's current protein download, keeping the previous one too. The report
  becomes `refseq_viral.applied.json`.
- **Both are in the audit log.** Results made before an update keep the hashes of the bundles they used in their
  provenance, and the old bundles stay in the store, so they can still be traced and reproduced.

**Tried on 18 November 2026,** in a copy of this site's data:
- NCBI's download differed from the 13 November snapshot's, but in nothing else: the same 19,607 references, no
  taxonomy or sequence changed. The check now reports this as unchanged in content.
- Applied by hand on that copy (before that rule existed), the update switched the bundles, rebuilt the proteins and
  kept both previous bundles.
