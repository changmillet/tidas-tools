//! Portable issue-volume probe; no private package or external services.
use std::fs;
use std::io::{BufRead, BufReader};
use std::time::Instant;

use serde_json::json;
use tidas_runtime::{CancellationToken, MemoryBudget};
use tidas_validation::{ValidationRequest, validate_tidas_package};

#[test]
#[ignore = "explicit release-mode resource probe; run with --ignored --nocapture"]
fn generated_issue_volume_is_complete_bounded_and_repeatable() {
    const DOCUMENTS: usize = 64;
    const EXCHANGES: usize = 256;
    const BUDGET: u64 = 64 * 1024 * 1024;
    let directory = tempfile::tempdir().unwrap();
    let input = directory.path().join("input");
    fs::create_dir_all(input.join("processes")).unwrap();
    let document = serde_json::to_vec(&json!({"processDataSet": {
        "exchanges": {"exchange": (0..EXCHANGES).map(|id| json!({
            "@dataSetInternalID": id.to_string(), "exchangeDirection": "Invalid"
        })).collect::<Vec<_>>()}
    }}))
    .unwrap();
    for index in 0..DOCUMENTS {
        fs::write(input.join(format!("processes/{index:04}.json")), &document).unwrap();
    }
    let mut previous = None;
    for round in 0..2 {
        let spool = directory.path().join(format!("issues-{round}.jsonl"));
        let start = Instant::now();
        let output = validate_tidas_package(&ValidationRequest {
            input_dir: input.clone(),
            issue_spool: Some(spool.clone()),
            cancellation: CancellationToken::default(),
            memory_budget: MemoryBudget::new(BUDGET),
            queue_capacity: 8,
            progress: None,
        })
        .unwrap();
        let elapsed = start.elapsed();
        let summary = output.summary;
        assert!(!summary.ok);
        assert_eq!(summary.document_count, DOCUMENTS as u64);
        assert!(summary.issue_count >= (DOCUMENTS * EXCHANGES) as u64);
        assert_eq!(summary.issue_count, summary.error_count);
        assert!(summary.peak_accounted_memory_bytes <= BUDGET);
        let receipt = summary.issue_spool.unwrap();
        assert_eq!(receipt.event_count, summary.issue_count);
        let mut lines = 0;
        for line in BufReader::new(fs::File::open(&spool).unwrap()).lines() {
            let line = line.unwrap();
            assert!(line.len() < 1024 * 1024);
            let _: serde_json::Value = serde_json::from_str(&line).unwrap();
            lines += 1;
        }
        assert_eq!(lines, summary.issue_count);
        let identity = (summary.issue_count, receipt.sha256.clone());
        if let Some(previous) = &previous {
            assert_eq!(previous, &identity);
        }
        previous = Some(identity);
        println!(
            "round={round} documents={DOCUMENTS} exchanges_per_document={EXCHANGES} input_bytes={} issues={} wall_seconds={:.3} peak_accounted_bytes={} spool_sha256={}",
            document.len() * DOCUMENTS,
            summary.issue_count,
            elapsed.as_secs_f64(),
            summary.peak_accounted_memory_bytes,
            receipt.sha256
        );
    }
}
