//! gh2k: GenHub2's sequence kernels, run by the Erlang services as a supervised external program (FS 4.2).
//! Every command is deterministic: the same input (and seed) gives the same output, byte for byte.
//!
//!   gh2k validate IN OUT                     check a FASTA/FASTQ file, write it normalised (FS 3.1, task validate)
//!   gh2k sketch K S DB.fasta OUT.sketch      MinHash sketches of the reference genomes, with an index
//!   gh2k classify DB.sketch QUERY.fasta TOP [OUT]  the nearest references of every query sequence (task classify),
//!                                            to OUT or stdout
//!   gh2k screen DB.sketch TOP R1.fastq [R2.fastq]  the nearest references of a read set (task screen)
//!   gh2k nj ALIGNED.fasta                    a neighbour-joining tree of aligned genomes, in Newick (task tree)
//!   gh2k dist ALIGNED.fasta I0 I1 J0 J1 OUT  a tile of the distance matrix (task distance_block; phylo.rs)
//!   gh2k njtiles ALIGNED.fasta TILE...       neighbour-joining on the matrix put together from tiles
//!   gh2k boot ALIGNED.fasta SEED [OUT]       one bootstrap replicate's tree (task bootstrap), to OUT or stdout
//!   gh2k boots ALIGNED.fasta FIRST COUNT OUT COUNT replicates with seeds FIRST.., one tree a line (a batch)
//!   gh2k support TREE REPLICATES...          the tree with each branch's bootstrap support
//!   gh2k nb REFS.fasta TAXONOMY.tsv QUERY.fasta K   naive Bayes on k-mers: the phase E test's learned model (nb.rs)
//!   gh2k simulate GENOME.fa PAIRS LEN INSERT ERR SEED OUT [SPIKE.fa SPIKE_PAIRS]   paired reads for tests
//!
//! Exit status: 0 done; 2 the input is invalid (validate: the report says why); 1 a usage or I/O error.

mod fasta;
mod minhash;
mod nb;
mod nj;
mod phylo;
mod simulate;
mod validate;

use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let a: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let r = match a.as_slice() {
        ["validate", input, output] => validate::run(input, output),
        ["sketch", k, s, db, out] => minhash::sketch_cmd(num(k), num(s), db, out),
        ["classify", db, query, top] => minhash::classify_cmd(db, query, num(top), None),
        ["classify", db, query, top, out] => minhash::classify_cmd(db, query, num(top), Some(out)),
        ["screen", db, top, fastqs @ ..] if !fastqs.is_empty() => {
            minhash::screen_cmd(db, fastqs, num(top))
        }
        ["nj", aligned] => nj::run(aligned),
        ["dist", aligned, i0, i1, j0, j1, out] => {
            phylo::dist(aligned, num(i0), num(i1), num(j0), num(j1), out)
        }
        ["njtiles", aligned, tiles @ ..] if !tiles.is_empty() => phylo::njtiles(aligned, tiles),
        ["boot", aligned, seed] => phylo::boot(aligned, num(seed) as u64, None),
        ["boot", aligned, seed, out] => phylo::boot(aligned, num(seed) as u64, Some(out)),
        ["boots", aligned, first, count, out] => {
            phylo::boots(aligned, num(first) as u64, num(count) as u64, out)
        }
        ["support", tree, reps @ ..] if !reps.is_empty() => phylo::support(tree, reps),
        ["nb", refs, taxonomy, query, k] => nb::run(refs, taxonomy, query, num(k)),
        ["simulate", genome, pairs, len, insert, err, seed, out] => simulate::run(
            genome,
            num(pairs),
            num(len),
            num(insert),
            fnum(err),
            num(seed) as u64,
            out,
            None,
        ),
        ["simulate", genome, pairs, len, insert, err, seed, out, spike, spike_pairs] => {
            simulate::run(
                genome,
                num(pairs),
                num(len),
                num(insert),
                fnum(err),
                num(seed) as u64,
                out,
                Some((spike, num(spike_pairs))),
            )
        }
        _ => {
            eprintln!(
                "usage: gh2k validate|sketch|classify|screen|nj|dist|njtiles|boot|boots|support|nb|simulate ... (see the source's header)"
            );
            exit(1)
        }
    };
    match r {
        Ok(code) => exit(code),
        Err(e) => {
            eprintln!("gh2k: {e}");
            exit(1)
        }
    }
}

fn num(s: &str) -> usize {
    s.parse().unwrap_or_else(|_| {
        eprintln!("gh2k: not a number: {s}");
        exit(1)
    })
}

fn fnum(s: &str) -> f64 {
    s.parse().unwrap_or_else(|_| {
        eprintln!("gh2k: not a number: {s}");
        exit(1)
    })
}

/// A JSON string literal.
pub fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}
