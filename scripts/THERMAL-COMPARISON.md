# Thermal comparison — map step 2

`ShadeApparentTemperature` calculates shade apparent temperature from air temperature (°C), relative humidity (%) and 10m wind speed (m/s), using `AT=T+0.33e−0.70v−4`, `e=RH/100×6.105×exp(17.27T/(237.7+T))`. Source: ECMWF thermofeel / Steadman-BOM form, https://github.com/ecmwf/thermofeel/blob/main/thermofeel/thermofeel.py . This is a weather-based shade estimate, not inferred human activity behaviour. No historical anomaly is added to the calculated current apparent temperature.

`ThermalComparisonEngine` accepts a complete, unique set of current grid samples for one Shanghai-local hour. The network loader, retries, live cache and widget rendering are later steps. Missing coordinates, wrong locations, mismatched hours and invalid values fail instead of being silently replaced.

Every comparison reads the complete bundled history by indexed offsets, retrieving matching local hours around the same month/day in each earlier year. The target year and later years are always excluded (including historical replay). February 29 uses both February 28 and March 1 in non-leap years. Date windows are clipped to their reference year to avoid leakage between held-out years.

Candidate day radii `[0,3,7,14,21]` are a search domain, not temperature-band widths or precomputed weekly thresholds. Each invocation selects a radius by historical leave-one-year-out mean absolute error, across all grid points equally. Smaller radii win exact ties. The calculation requires at least three earlier years. This selection checks how well nearby-day averages estimate a held-out historical year's same-date/hour weather; it does not establish a forecast's accuracy or infer people's schedules.

Within each point, observations are averaged within each reference year, then yearly means are equally averaged. The returned result retains the per-year apparent-temperature distributions, selected window, year list, historical percentile and current-minus-historical anomaly. These are inputs for the dynamic-band step. Regional anomaly is an equal-sample spatial mean, not a population or exact-area weighted statistic. It is not automatically statistically significant and must not be presented as a change in formal climate seasons.

The step does not implement solar-term timestamps, activity weights, dynamic map bands or early/late-season messages. It also does not correct systematic bias between ERA5 reanalysis and a live forecast model; input model consistency must be examined during replay and live-source integration.

Run `python3 scripts/check-thermal-history.py --history Widgets/Resources/WeatherHistory --at 2026-11-19T15:00` for the independent Python reference calculation. This checks real historical retrieval and prints a reference only; it does not fetch or fabricate today's weather and does not substitute for Swift tests. Swift tests cover formula units, window selection, equal-year historical comparisons, target-year exclusion, leap days, New Year, and input mismatch rejection.

## App switch revision

The main window now has “本地计算地图体感”, off by default. Off selects Open-Meteo `apparent_temperature` for both current and historical values. On selects the local shade formula for both. Network errors do not silently change source. This setting does not affect existing chart widgets.

Only `com.songa.ShanghaiTemperature.ThermalPreferences` is shared through the documented macOS temporary shared-preference entitlement: read/write for the app, read-only for the extension. No unrestricted filesystem access, fake Team ID, or App Group entitlement is added. Shared-setting behaviour still requires real installation verification on the target macOS release.

API history uses a separate on-disk cache, keyed by grid, year and date coverage. Initial preparation fetches at most one historical year per invocation, with at least 65 seconds between attempts and a conservative 7500 weighted-history-call UTC-day budget. It reuses all cached hours and a three-day date margin. Existing desktop widgets are unchanged. The new map provider in later steps must display `historyPreparing` progress and request subsequent preparation; the map itself does not exist at this stage. On a cold cache, network-source historical comparison is deliberately unavailable until the matching API reference is ready. Local mode continues to use the full bundled three-field archive without any extra download.

The API provider, real network access, Swift compilation and installed preference sharing are not yet runtime-validated in this environment. URLProtocol tests cover API-field selection, matching historical cache preparation, cache reuse, wrong units and offline error propagation. They are queued for the online Swift test stage.
