// ISO8601 UTC timestamp with milliseconds (JS Date.toISOString() shape). Used
// for audit.jsonl lines — census greps them across both servers. The conformance
// suite scrubs the `ts` value, so only the shape matters there.
use std::time::{SystemTime, UNIX_EPOCH};

pub fn iso_now() -> String {
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let total_ms = dur.as_millis() as i64;
    let ms = (total_ms % 1000) as i64;
    let mut secs = total_ms / 1000;
    let time_of_day = secs.rem_euclid(86400);
    let days = (secs - time_of_day) / 86400;
    let hour = time_of_day / 3600;
    let min = (time_of_day % 3600) / 60;
    let sec = time_of_day % 60;
    secs = days; // days since epoch
    let (y, m, d) = civil_from_days(secs);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y, m, d, hour, min, sec, ms
    )
}

// Howard Hinnant's civil_from_days (inverse of days_from_civil).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}
