//! Window usage for the quota lens: per-message rows inside an absolute interval.
//!
//! Returns the messages inside an absolute [from, until) window, one row each.
//! No bucketing: a quota window is a tiny slice of history, so the consumer
//! folds it however the UI wants without another round trip. Attribution is a
//! Swift-side declaration, so it is deliberately NOT applied here.

use serde::Serialize;
use serde_json::Value;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

pub(crate) type CacheKey = (i64, i64);
pub(crate) type CacheEntry = (Instant, u64, Value);

const MINUTE_MS: i64 = 60_000;
static SCAN_COUNT: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn cache_key(from_ms: i64, until_ms: i64) -> CacheKey {
    // Saturation keeps the extreme negative i64 input from overflowing while
    // preserving the minute floor for normal timestamps.
    (
        from_ms,
        until_ms.saturating_sub(until_ms.rem_euclid(MINUTE_MS)),
    )
}

pub(crate) fn scan_count() -> usize {
    SCAN_COUNT.load(Ordering::Relaxed)
}

pub(crate) fn cached(
    context: &crate::LocalSourceContext,
    from_ms: i64,
    until_ms: i64,
) -> Result<Value, String> {
    let key = cache_key(from_ms, until_ms);
    let cached = {
        let cache = crate::WINDOW_USAGE_CACHE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.get(&key).map(|(at, token, data)| {
            (
                at.elapsed() <= Duration::from_secs(crate::ONESHOT_MAX_AGE_SECS),
                *token,
                data.clone(),
            )
        })
    };
    let Some((fresh_enough, token, data)) = cached else {
        return compute(context, from_ms, until_ms, key);
    };
    if fresh_enough {
        return Ok(data);
    }

    // Probe with the cache lock released, matching graph_cached. An unchanged
    // source only refreshes the timestamp; it does not re-run the scan.
    if let Ok(probe_token) =
        tokscale_core::local_source_change_token(&context.parse_options(None, None))
    {
        if probe_token == token {
            let mut cache = crate::WINDOW_USAGE_CACHE
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(entry) = cache.get_mut(&key) {
                entry.0 = Instant::now();
            }
            return Ok(data);
        }
    }

    compute(context, from_ms, until_ms, key)
}

/// Held across a scan so overlapping callers share one, instead of each
/// starting its own.
///
/// `PopoverView`'s keyed window task and `pollAgentUsage` can both reach
/// `refreshWindowUsage`, and the Swift scan token only discards an overtaken
/// RESULT — it does not stop the duplicate work. Two 4-to-67 second scans then
/// run at once and contend for the same parser pool, which is the opposite of
/// what a cache in front of them is for.
///
/// A plain mutex rather than a per-key future: the second caller waits, then
/// re-checks the cache and finds what the first published. Scans are CPU-bound
/// and already serialise on the parser pool, so making them queue costs nothing
/// that running them concurrently was buying.
static COMPUTE: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn compute(
    context: &crate::LocalSourceContext,
    from_ms: i64,
    until_ms: i64,
    key: CacheKey,
) -> Result<Value, String> {
    let _serialised = COMPUTE.lock().unwrap_or_else(|p| p.into_inner());
    // Re-check under the lock. A caller that queued behind another's scan is
    // asking a question that scan may have just answered; running a second one
    // to produce the same bytes is the duplicate this lock exists to remove.
    {
        let cache = crate::WINDOW_USAGE_CACHE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some((at, _, data)) = cache.get(&key) {
            if at.elapsed() <= Duration::from_secs(crate::ONESHOT_MAX_AGE_SECS) {
                return Ok(data.clone());
            }
        }
    }
    let generation = crate::root_generation();
    let token =
        tokscale_core::local_source_change_token(&context.parse_options(None, None)).unwrap_or(0);
    let data = run(context, from_ms, until_ms)?;
    // The caller still gets this payload when `publish` refuses it: it answers
    // a question asked before the roots changed, and the next call recomputes.
    publish(key, generation, (Instant::now(), token, data.clone()));
    Ok(data)
}

/// Cache a freshly scanned window unless the root registry moved while the scan
/// was running.
///
/// Same lock discipline as `publish_graph`: the generation is re-read inside
/// the lock `invalidate_scan_caches` clears under, so a replace cannot land
/// between the check and the insert. A window scan runs for tens of seconds on
/// a large store, which makes that interleaving ordinary rather than exotic
/// here — and the entry it would leave behind is served without a token probe
/// for `ONESHOT_MAX_AGE_SECS`.
///
/// The insert clears first: one entry, not a history. The key carries
/// `until_ms` floored to the minute and the consumer polls every 60s with
/// `until = now`, so each poll mints a key that will never be asked for again —
/// and this map is a process-lifetime static with no eviction anywhere on the
/// production path. Every minute the Quota lens stayed open therefore left a
/// whole window's messages resident for the life of the app.
///
/// Measured on the shipping build: ~39 MB per minute with the lens open, and
/// none of it returned when it closed — 507 MB before opening, 1451 MB after
/// ten minutes and a close. Clearing keeps the hit that matters (a second call
/// inside the same minute still finds this entry) and drops the ones that
/// cannot be hit again by construction.
///
/// Returns whether the entry was published, which is what the tests assert on.
pub(crate) fn publish(key: CacheKey, generation: u64, entry: CacheEntry) -> bool {
    let mut cache = crate::WINDOW_USAGE_CACHE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if crate::root_generation() != generation {
        return false;
    }
    cache.clear();
    cache.insert(key, entry);
    true
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Message {
    timestamp: i64,
    client: String,
    provider_id: String,
    model_id: String,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
    cost: f64,
    is_turn_start: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct WindowData {
    messages: Vec<Message>,
    undated_count: u32,
    processing_time_ms: u32,
}

pub(crate) fn run(
    context: &crate::LocalSourceContext,
    from_ms: i64,
    until_ms: i64,
) -> Result<Value, String> {
    let options = context.report_options(None, None);

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("build runtime: {}", e))?;
    SCAN_COUNT.fetch_add(1, Ordering::Relaxed);
    let usage = runtime.block_on(tokscale_core::get_window_usage(options, from_ms, until_ms))?;

    let data = WindowData {
        messages: usage
            .messages
            .into_iter()
            .map(|m| Message {
                timestamp: m.timestamp,
                client: m.client,
                provider_id: m.provider_id,
                model_id: m.model_id,
                input: m.input,
                output: m.output,
                cache_read: m.cache_read,
                cache_write: m.cache_write,
                reasoning: m.reasoning,
                cost: m.cost,
                is_turn_start: m.is_turn_start,
            })
            .collect(),
        undated_count: usage.undated_count,
        processing_time_ms: usage.processing_time_ms,
    };
    serde_json::to_value(data).map_err(|e| format!("serialize window usage: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::{LazyLock, Mutex};

    static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    #[test]
    fn quantised_window_calls_scan_once() {
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let from_ms = 1_700_000_000_000;
        let until_a = 1_700_000_060_001;
        let until_b = 1_700_000_060_999;
        let key = cache_key(from_ms, until_a);
        crate::WINDOW_USAGE_CACHE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&key);
        let before = scan_count();
        let context = crate::LocalSourceContext::for_home(PathBuf::from("/private/tmp"));

        cached(&context, from_ms, until_a).expect("first window scan");
        cached(&context, from_ms, until_b).expect("quantised cache hit");

        assert_eq!(cache_key(from_ms, until_a), cache_key(from_ms, until_b));
        assert_eq!(scan_count(), before + 1);
        // If until_ms is no longer quantised, these two calls use different
        // keys and this assertion catches the accidental 0%-hit-rate change.
    }

    #[test]
    fn cache_keeps_only_the_newest_window() {
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let context = crate::LocalSourceContext::for_home(PathBuf::from("/private/tmp"));
        let from_ms = 1_700_000_000_000;
        crate::WINDOW_USAGE_CACHE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clear();

        // Three different minutes: exactly what a poll every 60s produces, and
        // what used to leave three whole scans resident for ever.
        for minute in 0..3 {
            cached(&context, from_ms, from_ms + 60_000 * (minute + 1))
                .expect("window scan");
        }
        let cache = crate::WINDOW_USAGE_CACHE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert_eq!(
            cache.len(),
            1,
            "the map is a process-lifetime static with no eviction, so anything \
             it keeps beyond the newest entry is kept until the app exits"
        );
    }

    #[test]
    fn different_minute_uses_different_key() {
        assert_ne!(
            cache_key(1_700_000_000_000, 1_700_000_060_001),
            cache_key(1_700_000_000_000, 1_700_000_120_001)
        );
    }
}
