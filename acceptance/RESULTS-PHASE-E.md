# A learned model against GenHub2's classical classification (phase E)

Plan sections 3.1 and 5, FS 5.3: a learned model is adopted only if it beats the established methods on held-out data,
in a published test. This is the first such test. Its verdict: **not adopted.**

Results file: [`results/model-dgx-spark-2026-11-18T0317Z.json`](results/model-dgx-spark-2026-11-18T0317Z.json),
18 November 2026. How it is run: [`run_model.sh`](run_model.sh) and [`gh_model_check.erl`](gh_model_check.erl), after
phase A's run ([REPRODUCE.md](REPRODUCE.md)), which builds the reference bundles and fetches the genomes.

## The test

- **The model:** multinomial naive Bayes on canonical 6-mers (`gh2k nb`), the approach of the RDP classifier (Wang et
  al. 2007, [doi:10.1128/AEM.00062-07](https://doi.org/10.1128/AEM.00062-07)).
  - **Training:** all 19,607 complete RefSeq viral genomes, pooled into their 14,859 species.
  - **Fixed before the test:** K = 6 and the pseudocount of 0.5. Nothing was tuned on the held-out genomes, and no
    other K was tried afterwards.
- **The held-out genomes:** phase A's 593 GenBank genomes of 30 viruses, none of them a RefSeq genome.
- **The comparison:** every method's call for every genome, scored against NCBI's taxonomy as phase A scored it:
  - MinHash (`gh_classify`);
  - proteins (DIAMOND blastx, `gh_protein`);
  - **classical**, GenHub2 today: the protein call where MinHash's is low or missing, MinHash's elsewhere;
  - the model alone;
  - MinHash with the model for its weak calls.
- **The rule, set before the test:** adopt the model if MinHash with the model gets more species right than
  classical, and no fewer genera or families.

## Results

| right | species (593) | genus (573) | family (593) |
| --- | --- | --- | --- |
| MinHash | 564 | 572 | 591 |
| proteins | 547 | 566 | 586 |
| **classical (GenHub2 today)** | **572** | **573** | **593** |
| the model alone | 416 | 428 | 460 |
| MinHash, with the model for its weak calls | 502 | 506 | 527 |

The three classical rows equal phase A's published numbers.

**Species right, by MinHash's confidence:**

| MinHash's confidence | genomes | MinHash | classical | the model |
| --- | --- | --- | --- | --- |
| high | 275 | 274 | 274 | 274 |
| medium | 185 | 182 | 182 | 96 |
| low | 132 | 108 | 115 | 46 |
| unclassified | 1 | 0 | 1 | 0 |

**Where a model was meant to help,** on MinHash's weak calls, it does worst:
- 46 of 132 species right, against 115 for the classical combination;
- on the 87 weak calls where the model and the classical combination disagree, the model is right on none, the
  classical combination on 70.

**Time:** the model classified the 593 genomes in 24 s; MinHash takes 0.5 s, and proteins 34 s.

## What it shows

- **Not adopted.** The model loses at every rank and every confidence level except high, where all methods agree.
- **Why:** a genome's whole-genome 6-mer composition says little about its species once its sequence has diverged.
  Shared k-mers (MinHash) and protein similarity (DIAMOND) carry the signal that divergent viruses keep. This is the
  same lesson as PQCF's genome research: plain k-mer methods beat the graph methods there, and here a composition
  model does not beat sequence similarity.
- **What a next model would need:** to beat 115 of 132 on MinHash's weak calls, without losing elsewhere. Protein
  language models or alignment-aware models are candidates; each goes through this test, unchanged, before it is
  used.
- `gh2k nb` stays in the code as the test's model, outside the analysis pipeline.

## Reproducing

```sh
sh acceptance/run.sh --reduced        # once: the reference bundles and genomes
sh acceptance/run_model.sh            # about a minute on 10 cores
```

Every count above must be the same; only the times differ. Tested in the development worktree on 18 November 2026.
