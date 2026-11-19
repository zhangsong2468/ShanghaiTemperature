# Regional map refresh — step 5

The installed map widget now uses `RegionalThermalStore`. Gallery placeholders alone use the explicitly labelled 2025 replay. Live failures never display gallery data, zero-filled temperatures or another source's formula.

## Sources and preparation

The app's existing switch selects a complete current/history definition: local shade formula for both, or Open-Meteo `apparent_temperature` for both. Local mode fetches 14 calendar days of air temperature, humidity and m/s wind for the fixed 100-point grid. Network mode fetches the provider's apparent-temperature field; it no longer constructs placeholder current weather samples merely to enter the comparison engine.

Network historical cache covers all hours around each historical calendar date, with a 31-day reference radius and three-day reuse margin, clipped to that historical year. The dynamic same-date window is still selected independently from radii 0/3/7/14/21. The wider cached range supports timing curves, not a fixed map interval. At most one historical year is downloaded per warm-up invocation, at least 65 seconds apart, under a 7500 conservative weighted-history-call UTC-day budget. Even the last download returns a preparing status and defers live data to a later refresh to avoid a quota burst. First-run network mode can therefore remain in preparation for multiple refreshes. Actual timing is controlled by WidgetKit. Local mode uses the bundled historical fields immediately and does not need network historical AT preparation.

## Cache and timeline

Source-specific `map-local.json` and `map-network.json` caches are written atomically. Same-hour data is reused. The next normal request is at the next Shanghai-local hour. Preparation retries request 2 minutes, rate limiting 30 minutes, other failures 15 minutes; these are system scheduling requests, not exact wake-up guarantees. Concurrent callers of the same source share an in-flight task.

Fallback data is clearly marked old cache. Data expires after 48 hours, future-dated records and wrong-source caches are rejected, and a source switch during an outstanding request cannot display the old source's result. Future timeline entries update the calendar date/solar-term heading while retaining the original data timestamp and marking stale values; they do not invent future temperatures. Seasonal messages are hidden on stale data. The raster is bounded to three cached images (about 2 MB) so future timeline views do not rebuild the same temperature field for every entry.

## Historical messages

Each reference year contributes equally. Regional means weight the fixed sample points equally, not population or exact administrative area. The basic anomaly compares today's regional apparent temperature with the average matching historical yearly means. A deterministic year-resampling interval for the baseline mean prevents labelling a value near that mean as clearly warmer/cooler. It is not a formal climate-trend significance test, does not account for every spatial/temporal dependency and does not correct reanalysis/live-model bias.

Early/late timing uses 14 consecutive days at the same local hour and compares them with matching-source historical regional curves, searching offsets -14..+14 days. It requires at least five complete reference years, the first and second halves of the recent series to have the same nonzero robust trend direction, agreement with the historical curve's direction, and a year-bootstrap shift interval excluding zero and search boundaries. Missing/flat/reversing/uncertain patterns show no timing message. Text says “近期回暖/降温...”, not formal meteorological season entry. These guards are product/statistical assumptions needing wider replay acceptance, not a claim that weather records reveal human activity habits.

## Verification state

Python checks cover resource/width invariants and a separate timing reference with stable, flat, missing and uncertain test sequences. Real 2025-11-19 replay shows no reliable timing message (null) and does not falsely claim an early winter. New Swift tests cover source/expiry checks, midnight projection, fresh disk-cache loading, 14-day weather parsing and timing guards. Swift tests, real API access, preference sharing, renderer performance and native WidgetKit execution still require the online build/device validation in step 6. App name and all five earlier widgets remain unchanged.
