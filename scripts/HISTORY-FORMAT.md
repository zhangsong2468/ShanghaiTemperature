# Historical weather archive v1

Complete ERA5 samples for 100 locations, 2015–2025, Asia/Shanghai: 9,643,200 point-hours, three supplied fields per record. No daily aggregation, fitted thresholds, or synthetic replacement.

Run `python3 scripts/build-history.py --source research/temperature-map/data` after collecting all source fragments. Default output is `Widgets/Resources/WeatherHistory`, embedded in the extension once. All source fragments must exist and pass model, timestamp, unit, finite-value and range checks. The builder reads every encoded record back and compares all three values against source payloads before installation.

Each year is a little-endian binary file, ordered by manifest point then local hourly timestamp. Record: signed int16 temperature ×100 (°C), unsigned int16 relative humidity ×100 (%), unsigned int16 10m wind ×100 (m/s). The builder rejects any value not exactly representable to two decimals; this source dataset is preserved without numeric precision loss. Each year has 8760/8784 hours per point. All binary files total 57,859,200 bytes, with a small provenance index and attribution notice.

`index.json` contains version, schema, points, years, SHA256, original fragment SHA256 and returned model coordinates. The Swift actor validates the schema, verifies each mapped year's size/hash on first use and reads records by calculated offset. Whole files are not decoded into millions of Swift objects. Python's mmap benchmark is a diagnostic, not a WidgetKit performance result. Swift tests and Xcode compilation still require the online toolchain.

Source: Open-Meteo ERA5 historical weather API, https://open-meteo.com/en/docs/historical-weather-api . CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ . The conversion changes storage format, not the supplied weather values.
