//! Paired-end reads simulated from known genomes, for testing host removal and consensus against a known answer.
//! Fragments of INSERT bases start uniformly along a genome (records chosen in proportion to their length); read 1 is
//! the fragment's start, read 2 the reverse complement of its end; each base is substituted with probability ERR;
//! qualities are all 'I'. Optional SPIKE reads (e.g. human, for host removal) are drawn the same way from another
//! FASTA, skipping fragments with N. Read names say the origin: v000001 (genome) or h000001 (spike), so a test can
//! count what a filter kept. The order of pairs is shuffled by the seed; the same arguments give the same files.

use crate::fasta::{self, revcomp};
use std::io::{BufWriter, Write};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

fn fragments(
    recs: &[fasta::Record],
    pairs: usize,
    insert: usize,
    rng: &mut Rng,
) -> Result<Vec<Vec<u8>>, String> {
    let total: u64 = recs
        .iter()
        .filter(|r| r.seq.len() >= insert)
        .map(|r| (r.seq.len() - insert + 1) as u64)
        .sum();
    if total == 0 {
        return Err(format!("no sequence of {insert} bases or more"));
    }
    let mut out = Vec::with_capacity(pairs);
    let mut tries = 0usize;
    while out.len() < pairs {
        tries += 1;
        if tries > pairs * 100 + 1000 {
            return Err("too many fragments with N".into());
        }
        let mut x = rng.below(total);
        for r in recs.iter().filter(|r| r.seq.len() >= insert) {
            let span = (r.seq.len() - insert + 1) as u64;
            if x < span {
                let f = &r.seq[x as usize..x as usize + insert];
                if f.iter().all(|b| b"ACGT".contains(b)) {
                    out.push(f.to_vec());
                }
                break;
            }
            x -= span;
        }
    }
    Ok(out)
}

fn mutate(read: &[u8], err: f64, rng: &mut Rng) -> Vec<u8> {
    read.iter()
        .map(|&b| {
            if rng.unit() < err {
                let others: Vec<u8> = b"ACGT".iter().copied().filter(|&c| c != b).collect();
                others[rng.below(3) as usize]
            } else {
                b
            }
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    genome: &str,
    pairs: usize,
    len: usize,
    insert: usize,
    err: f64,
    seed: u64,
    out: &str,
    spike: Option<(&str, usize)>,
) -> Result<i32, String> {
    if len > insert {
        return Err("read length above the insert size".into());
    }
    let mut rng = Rng(seed);
    let mut frags: Vec<(char, Vec<u8>)> =
        fragments(&fasta::read(genome)?, pairs, insert, &mut rng)?
            .into_iter()
            .map(|f| ('v', f))
            .collect();
    if let Some((path, n)) = spike {
        frags.extend(
            fragments(&fasta::read(path)?, n, insert, &mut rng)?
                .into_iter()
                .map(|f| ('h', f)),
        );
    }
    for i in (1..frags.len()).rev() {
        let j = rng.below(i as u64 + 1) as usize;
        frags.swap(i, j);
    }
    let open = |suffix: &str| -> Result<BufWriter<std::fs::File>, String> {
        let p = format!("{out}.{suffix}");
        Ok(BufWriter::new(
            std::fs::File::create(&p).map_err(|e| format!("{p}: {e}"))?,
        ))
    };
    let (mut w1, mut w2) = (open("R1.fastq")?, open("R2.fastq")?);
    let qual = vec![b'I'; len];
    let mut counts = [0usize; 2];
    for (origin, f) in &frags {
        let k = if *origin == 'v' { 0 } else { 1 };
        counts[k] += 1;
        let name = format!("{}{:06}", origin, counts[k]);
        let r1 = mutate(&f[..len], err, &mut rng);
        let r2 = mutate(&revcomp(&f[f.len() - len..]), err, &mut rng);
        for (w, r, tag) in [(&mut w1, &r1, "/1"), (&mut w2, &r2, "/2")] {
            let io = |e: std::io::Error| e.to_string();
            w.write_all(format!("@{name}{tag}\n").as_bytes())
                .map_err(io)?;
            w.write_all(r).map_err(io)?;
            w.write_all(b"\n+\n").map_err(io)?;
            w.write_all(&qual).map_err(io)?;
            w.write_all(b"\n").map_err(io)?;
        }
    }
    w1.flush().map_err(|e| e.to_string())?;
    w2.flush().map_err(|e| e.to_string())?;
    println!(
        "{{\"genome_pairs\":{},\"spike_pairs\":{}}}",
        counts[0], counts[1]
    );
    Ok(0)
}
