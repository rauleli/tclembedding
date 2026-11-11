use std::hint::black_box;
use std::time::Instant;
use tokenizers::Tokenizer;

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: clone_probe tokenizer.json clone|direct".into());
    }
    let mut tokenizer = Tokenizer::from_file(&args[1])?;
    tokenizer.with_padding(None);
    tokenizer.with_truncation(None)?;
    let expected = vec![0, 739, 143, 2];
    assert_eq!(tokenizer.encode("hola", true)?.get_ids(), expected);
    let mut samples = Vec::new();
    for _ in 0..10 {
        let now = Instant::now();
        let ids = if args[2] == "clone" {
            let clone = tokenizer.clone();
            clone.encode(black_box("hola"), true)?.get_ids().to_vec()
        } else if args[2] == "direct" {
            tokenizer
                .encode(black_box("hola"), true)?
                .get_ids()
                .to_vec()
        } else {
            return Err("unknown mode".into());
        };
        assert_eq!(ids, expected);
        samples.push(now.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(|a, b| a.total_cmp(b));
    println!(
        "mode={} iterations={} min_ms={:.6} median_ms={:.6} max_ms={:.6}",
        args[2],
        samples.len(),
        samples[0],
        (samples[4] + samples[5]) / 2.0,
        samples[9]
    );
    Ok(())
}
