//! A learned classifier for the phase E test (plan section 3.1): multinomial naive Bayes on canonical k-mer counts,
//! the approach of the RDP classifier (Wang et al. 2007, doi:10.1128/AEM.00062-07), trained on the reference genomes
//! with their species from the bundle's taxonomy. It is measured against GenHub2's classical classification
//! (acceptance/gh_model_check.erl), and adopted only if it beats it on held-out genomes.
//!
//!   gh2k nb REFS.fasta TAXONOMY.tsv QUERY.fasta K
//!
//! Training: each species' k-mer counts, summed over its genomes (k-mers of A/C/G/T only, canonical: a k-mer and its
//! reverse complement are one); P(k-mer | species) = (count + 0.5) / (total + 0.5 * 4^k). A query's score for a
//! species is the sum over its k-mers of count * log P; the call is the highest. Output, one JSON line a query:
//! {"query", "species", "score", "second", "margin"} (margin: the best score minus the second, in nats).

use crate::fasta::{self, code};
use crate::json_str;
use crate::minhash::par_map;
use std::collections::HashMap;

pub fn run(refs: &str, taxonomy: &str, query: &str, k: usize) -> Result<i32, String> {
    if !(4..=8).contains(&k) {
        eprintln!("gh2k nb: K from 4 to 8");
        return Ok(2);
    }
    let tax = std::fs::read_to_string(taxonomy).map_err(|e| format!("{taxonomy}: {e}"))?;
    let species_of: HashMap<&str, &str> = tax
        .lines()
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() >= 3 && !f[2].is_empty()).then(|| (f[0], f[2]))
        })
        .collect();
    let mut names: Vec<&str> = species_of.values().copied().collect();
    names.sort_unstable();
    names.dedup();
    let index: HashMap<&str, usize> = names.iter().enumerate().map(|(i, n)| (*n, i)).collect();
    let dim = 1usize << (2 * k);
    let mut counts = vec![0f64; names.len() * dim];
    for r in fasta::read(refs)? {
        if let Some(s) = species_of.get(r.id.as_str()).and_then(|n| index.get(n)) {
            let row = &mut counts[s * dim..(s + 1) * dim];
            for (km, c) in kmers(&r.seq, k) {
                row[km] += c as f64;
            }
        }
    }
    // log P(k-mer | species), as f32 to keep the table small (species x 4^k)
    let logp: Vec<f32> = par_map(&(0..names.len()).collect::<Vec<_>>(), |&s| {
        let row = &counts[s * dim..(s + 1) * dim];
        let total: f64 = row.iter().sum::<f64>() + 0.5 * dim as f64;
        row.iter()
            .map(|&c| ((c + 0.5) / total).ln() as f32)
            .collect::<Vec<f32>>()
    })
    .concat();
    drop(counts);
    let queries = fasta::read(query)?;
    let lines = par_map(&queries, |q| {
        let qk: Vec<(usize, u32)> = kmers(&q.seq, k).into_iter().collect();
        let (mut best, mut second) = ((f64::NEG_INFINITY, 0usize), (f64::NEG_INFINITY, 0usize));
        for s in 0..names.len() {
            let row = &logp[s * dim..(s + 1) * dim];
            let score: f64 = qk.iter().map(|&(km, c)| c as f64 * row[km] as f64).sum();
            if score > best.0 {
                second = best;
                best = (score, s);
            } else if score > second.0 {
                second = (score, s);
            }
        }
        if qk.is_empty() || names.is_empty() {
            format!("{{\"query\":{},\"species\":\"\"}}", json_str(&q.id))
        } else {
            format!(
                "{{\"query\":{},\"species\":{},\"score\":{:.3},\"second\":{},\"margin\":{:.3}}}",
                json_str(&q.id),
                json_str(names[best.1]),
                best.0,
                json_str(names[second.1]),
                best.0 - second.0
            )
        }
    });
    for l in lines {
        println!("{l}");
    }
    Ok(0)
}

/// the canonical k-mers of a sequence and their counts (k-mers with a base other than A/C/G/T are skipped)
fn kmers(seq: &[u8], k: usize) -> HashMap<usize, u32> {
    let mask = (1u64 << (2 * k)) - 1;
    let shift = 2 * (k - 1);
    let mut m = HashMap::new();
    let (mut fwd, mut rev, mut len) = (0u64, 0u64, 0usize);
    for &b in seq {
        match code(b) {
            Some(x) => {
                fwd = ((fwd << 2) | x) & mask;
                rev = (rev >> 2) | ((3 - x) << shift);
                len += 1;
                if len >= k {
                    *m.entry(fwd.min(rev) as usize).or_insert(0) += 1;
                }
            }
            None => len = 0,
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kmer_and_its_reverse_complement_count_as_one() {
        let a = kmers(b"ACGTTG", 4);
        let b = kmers(&fasta::revcomp(b"ACGTTG"), 4);
        assert_eq!(a, b);
        assert_eq!(a.values().sum::<u32>(), 3);
        assert!(kmers(b"ACGNTTG", 4).is_empty());
    }
}
