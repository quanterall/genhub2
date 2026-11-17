//! MinHash sketches and nearest-reference search (FS 5.1), after Mash (Ondov et al. 2016,
//! doi:10.1186/s13059-016-0997-x): a genome's sketch is the S smallest hashes of its canonical K-mers; the Jaccard
//! index of two genomes is estimated from their sketches, and the Mash distance D = -ln(2j/(1+j))/K estimates the
//! per-base divergence, so 1 - D estimates the average nucleotide identity.
//!
//! The sketch file holds every reference's sketch and an index, all (hash, reference) pairs sorted, so a query finds
//! the references sharing any of its hashes by binary search, without loading anything else. Classification of a
//! query: the candidates are the references sharing hashes with it; each candidate's Jaccard index is computed
//! exactly from the two bottom-S sketches (the S smallest hashes of their union, Mash's estimator); the TOP nearest
//! are reported, ordered by distance, then shared hashes, then reference order (deterministic).

use crate::fasta::{self, code};
use crate::json_str;
use std::io::{BufWriter, Read, Write};

const MAGIC: &[u8; 8] = b"GH2SKT01";

pub struct Sketch {
    pub id: String,
    pub length: u64,
    /// ascending, distinct
    pub hashes: Vec<u64>,
}

#[inline]
fn mix(mut x: u64) -> u64 {
    // splitmix64's finaliser: a fixed bijection, so equal K-mers hash equally on every platform
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d049bb133111eb);
    x ^ (x >> 31)
}

/// The S smallest distinct hashes of the canonical K-mers (K <= 32) of seq; K-mers with other bases than A, C, G, T
/// are skipped.
pub fn sketch(seq: &[u8], k: usize, s: usize) -> Vec<u64> {
    assert!((1..=32).contains(&k));
    let mask: u64 = if k == 32 {
        u64::MAX
    } else {
        (1u64 << (2 * k)) - 1
    };
    let shift = 2 * (k as u64 - 1);
    let (mut fwd, mut rev, mut valid) = (0u64, 0u64, 0usize);
    let mut all: Vec<u64> = Vec::with_capacity(seq.len());
    for &b in seq {
        match code(b) {
            Some(c) => {
                fwd = ((fwd << 2) | c) & mask;
                rev = (rev >> 2) | ((3 - c) << shift);
                valid += 1;
                if valid >= k {
                    all.push(mix(fwd.min(rev)));
                }
            }
            None => valid = 0,
        }
    }
    bottom(all, s)
}

fn bottom(mut v: Vec<u64>, s: usize) -> Vec<u64> {
    if v.len() / 4 > s {
        let (lo, _, _) = v.select_nth_unstable(s * 4);
        let mut lo = lo.to_vec();
        lo.sort_unstable();
        lo.dedup();
        if lo.len() >= s {
            lo.truncate(s);
            return lo;
        }
    }
    v.sort_unstable();
    v.dedup();
    v.truncate(s);
    v
}

/// Mash's Jaccard estimate from two bottom-S sketches: among the S smallest hashes of their union, the fraction in
/// both. Returns (shared among those, the number of those).
pub fn jaccard(a: &[u64], b: &[u64], s: usize) -> (usize, usize) {
    let (mut i, mut j, mut n, mut shared) = (0, 0, 0, 0);
    while n < s && i < a.len() && j < b.len() {
        if a[i] == b[j] {
            shared += 1;
            i += 1;
            j += 1;
        } else if a[i] < b[j] {
            i += 1;
        } else {
            j += 1;
        }
        n += 1;
    }
    while n < s && i < a.len() {
        i += 1;
        n += 1;
    }
    while n < s && j < b.len() {
        j += 1;
        n += 1;
    }
    (shared, n)
}

pub fn distance(j: f64, k: usize) -> f64 {
    if j <= 0.0 {
        1.0
    } else {
        (-(2.0 * j / (1.0 + j)).ln() / k as f64).min(1.0)
    }
}

pub fn sketch_cmd(k: usize, s: usize, db: &str, out: &str) -> Result<i32, String> {
    let recs = fasta::read(db)?;
    let sketches = par_map(&recs, |r| Sketch {
        id: r.id.clone(),
        length: r.seq.len() as u64,
        hashes: sketch(&r.seq, k, s),
    });
    let mut index: Vec<(u64, u32)> = Vec::new();
    for (i, sk) in sketches.iter().enumerate() {
        index.extend(sk.hashes.iter().map(|&h| (h, i as u32)));
    }
    index.sort_unstable();
    let mut w = BufWriter::new(std::fs::File::create(out).map_err(|e| format!("{out}: {e}"))?);
    let io = |e: std::io::Error| format!("{out}: {e}");
    w.write_all(MAGIC).map_err(io)?;
    for v in [
        k as u64,
        s as u64,
        sketches.len() as u64,
        index.len() as u64,
    ] {
        w.write_all(&v.to_le_bytes()).map_err(io)?;
    }
    for sk in &sketches {
        w.write_all(&(sk.id.len() as u64).to_le_bytes())
            .map_err(io)?;
        w.write_all(sk.id.as_bytes()).map_err(io)?;
        w.write_all(&sk.length.to_le_bytes()).map_err(io)?;
        w.write_all(&(sk.hashes.len() as u64).to_le_bytes())
            .map_err(io)?;
        for h in &sk.hashes {
            w.write_all(&h.to_le_bytes()).map_err(io)?;
        }
    }
    for (h, i) in &index {
        w.write_all(&h.to_le_bytes()).map_err(io)?;
        w.write_all(&i.to_le_bytes()).map_err(io)?;
    }
    w.flush().map_err(io)?;
    println!(
        "{{\"references\":{},\"k\":{},\"s\":{},\"index\":{}}}",
        sketches.len(),
        k,
        s,
        index.len()
    );
    Ok(0)
}

pub struct Db {
    pub k: usize,
    pub s: usize,
    pub refs: Vec<Sketch>,
    pub index_hash: Vec<u64>,
    pub index_ref: Vec<u32>,
}

pub fn load(path: &str) -> Result<Db, String> {
    let mut f =
        std::io::BufReader::new(std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?);
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)
        .map_err(|e| format!("{path}: {e}"))?;
    if buf.len() < 40 || &buf[..8] != MAGIC {
        return Err(format!("{path}: not a gh2k sketch file"));
    }
    let mut p = 8;
    let u64at = |p: &mut usize| -> Result<u64, String> {
        let v = buf
            .get(*p..*p + 8)
            .ok_or_else(|| format!("{path}: truncated"))?;
        *p += 8;
        Ok(u64::from_le_bytes(v.try_into().unwrap()))
    };
    let (k, s, n, m) = (
        u64at(&mut p)? as usize,
        u64at(&mut p)? as usize,
        u64at(&mut p)? as usize,
        u64at(&mut p)? as usize,
    );
    let mut refs = Vec::with_capacity(n);
    for _ in 0..n {
        let l = u64at(&mut p)? as usize;
        let id = String::from_utf8_lossy(buf.get(p..p + l).ok_or("truncated")?).into_owned();
        p += l;
        let length = u64at(&mut p)?;
        let c = u64at(&mut p)? as usize;
        let mut hashes = Vec::with_capacity(c);
        for _ in 0..c {
            hashes.push(u64at(&mut p)?);
        }
        refs.push(Sketch { id, length, hashes });
    }
    let (mut index_hash, mut index_ref) = (Vec::with_capacity(m), Vec::with_capacity(m));
    for _ in 0..m {
        index_hash.push(u64at(&mut p)?);
        let v = buf.get(p..p + 4).ok_or("truncated")?;
        index_ref.push(u32::from_le_bytes(v.try_into().unwrap()));
        p += 4;
    }
    Ok(Db {
        k,
        s,
        refs,
        index_hash,
        index_ref,
    })
}

pub struct Hit {
    pub r: usize,
    pub shared: usize,
    pub of: usize,
    pub distance: f64,
}

pub fn nearest(db: &Db, q: &[u64], top: usize) -> Vec<Hit> {
    let mut cand: Vec<u32> = Vec::new();
    for h in q {
        let lo = db.index_hash.partition_point(|x| x < h);
        let mut i = lo;
        while i < db.index_hash.len() && db.index_hash[i] == *h {
            cand.push(db.index_ref[i]);
            i += 1;
        }
    }
    cand.sort_unstable();
    cand.dedup();
    let mut hits: Vec<Hit> = cand
        .into_iter()
        .map(|r| {
            let r = r as usize;
            let (shared, of) = jaccard(q, &db.refs[r].hashes, db.s);
            let j = if of > 0 {
                shared as f64 / of as f64
            } else {
                0.0
            };
            Hit {
                r,
                shared,
                of,
                distance: distance(j, db.k),
            }
        })
        .filter(|h| h.shared > 0)
        .collect();
    hits.sort_by(|a, b| {
        a.distance
            .total_cmp(&b.distance)
            .then(b.shared.cmp(&a.shared))
            .then(a.r.cmp(&b.r))
    });
    hits.truncate(top);
    hits
}

pub fn classify_cmd(db: &str, query: &str, top: usize, to: Option<&str>) -> Result<i32, String> {
    let db = load(db)?;
    let qs = fasta::read(query)?;
    let lines = par_map(&qs, |q| {
        let sk = sketch(&q.seq, db.k, db.s);
        let hits = nearest(&db, &sk, top);
        let hs: Vec<String> = hits
            .iter()
            .map(|h| {
                format!(
                    "{{\"ref\":{},\"shared\":{},\"of\":{},\"distance\":{:.6},\"ani\":{:.6}}}",
                    json_str(&db.refs[h.r].id),
                    h.shared,
                    h.of,
                    h.distance,
                    1.0 - h.distance
                )
            })
            .collect();
        format!(
            "{{\"query\":{},\"length\":{},\"hashes\":{},\"hits\":[{}]}}",
            json_str(&q.id),
            q.seq.len(),
            sk.len(),
            hs.join(",")
        )
    });
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    match to {
        Some(f) => std::fs::write(f, text).map_err(|e| format!("{f}: {e}"))?,
        None => std::io::stdout()
            .lock()
            .write_all(text.as_bytes())
            .map_err(|e| e.to_string())?,
    }
    Ok(0)
}

/// the distinct values occurring at least twice in a sorted slice
fn solid(v: &[u64]) -> Vec<u64> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < v.len() {
        let mut j = i + 1;
        while j < v.len() && v[j] == v[i] {
            j += 1;
        }
        if j - i >= 2 {
            out.push(v[i]);
        }
        i = j;
    }
    out
}

/// The nearest references of a read set (one or two FASTQ files), as one query named "reads": its sketch is the
/// S smallest hashes among the canonical K-mers seen at least twice, so most sequencing errors (K-mers seen once)
/// stay out (Mash's -m 2).
pub fn screen_cmd(db: &str, fastqs: &[&str], top: usize) -> Result<i32, String> {
    let db = load(db)?;
    let mut data = Vec::new();
    for f in fastqs {
        data.push(std::fs::read(f).map_err(|e| format!("{f}: {e}"))?);
    }
    let reads: Vec<&[u8]> = data
        .iter()
        .flat_map(|d| d.split(|&b| b == b'\n').skip(1).step_by(4))
        .map(|l| l.strip_suffix(b"\r").unwrap_or(l))
        .collect();
    let bases: usize = reads.iter().map(|r| r.len()).sum();
    let chunks: Vec<&[&[u8]]> = reads.chunks(reads.len().div_ceil(16).max(1)).collect();
    let parts = par_map(&chunks, |c| {
        c.iter()
            .flat_map(|r| sketch(r, db.k, usize::MAX))
            .collect::<Vec<u64>>()
    });
    drop(chunks);
    let mut all: Vec<u64> = parts.into_iter().flatten().collect();
    all.sort_unstable();
    let mut sk = solid(&all);
    drop(all);
    sk.truncate(db.s);
    let hits = nearest(&db, &sk, top);
    println!(
        "{{\"query\":\"reads\",\"reads\":{},\"bases\":{},\"hashes\":{},\"hits\":[{}]}}",
        reads.len(),
        bases,
        sk.len(),
        hits.iter()
            .map(|h| hit_json(&db, h))
            .collect::<Vec<_>>()
            .join(",")
    );
    Ok(0)
}

fn hit_json(db: &Db, h: &Hit) -> String {
    format!(
        "{{\"ref\":{},\"shared\":{},\"of\":{},\"distance\":{:.6},\"ani\":{:.6}}}",
        json_str(&db.refs[h.r].id),
        h.shared,
        h.of,
        h.distance,
        1.0 - h.distance
    )
}

/// Threads for the parallel loops: GH2K_THREADS if set (a task given one of PQCF's slots uses one), otherwise the
/// machine's.
pub fn threads() -> usize {
    std::env::var("GH2K_THREADS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n: &usize| n > 0)
        .unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1)
        })
}

/// f over xs on threads() threads, results in xs' order.
pub fn par_map<T: Sync, U: Send, F: Fn(&T) -> U + Sync>(xs: &[T], f: F) -> Vec<U> {
    let threads = threads().min(xs.len().max(1));
    let chunk = xs.len().div_ceil(threads).max(1);
    std::thread::scope(|sc| {
        let hs: Vec<_> = xs
            .chunks(chunk)
            .map(|c| sc.spawn(|| c.iter().map(&f).collect::<Vec<U>>()))
            .collect();
        hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rng_seq(n: usize, seed: u64) -> Vec<u8> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x = x.wrapping_add(0x9e3779b97f4a7c15);
                b"ACGT"[(mix(x) >> 62) as usize]
            })
            .collect()
    }

    #[test]
    fn canonical_and_identity() {
        let s = rng_seq(5000, 1);
        let a = sketch(&s, 21, 500);
        assert_eq!(a, sketch(&fasta::revcomp(&s), 21, 500));
        assert_eq!(a.len(), 500);
        assert_eq!(jaccard(&a, &a, 500), (500, 500));
        assert_eq!(distance(1.0, 21), 0.0);
        assert_eq!(distance(0.0, 21), 1.0);
    }

    #[test]
    fn distance_tracks_divergence() {
        let s = rng_seq(30000, 2);
        let mut m = s.clone();
        for i in (0..m.len()).step_by(100) {
            m[i] = if m[i] == b'A' { b'C' } else { b'A' };
        }
        let (a, b) = (sketch(&s, 21, 1000), sketch(&m, 21, 1000));
        let (sh, of) = jaccard(&a, &b, 1000);
        let d = distance(sh as f64 / of as f64, 21);
        assert!((d - 0.01).abs() < 0.004, "{d}");
    }
}
