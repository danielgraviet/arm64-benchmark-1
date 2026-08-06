# Vendored repositories

## sqlite-utils

- Source: https://github.com/simonw/sqlite-utils
- Pinned tag: 4.1.1
- Pinned commit: 458b3ab5b169eff1f8319c44a7c320c68f54d28b
- Vendored: 2026-08-06
- Stripped: `.git`, `docs/`, `.github/`, `.readthedocs.yaml`, `codecov.yml`, `Justfile`, `mypy.ini`
  (CI/docs tooling not part of the benchmark workload)

To re-vendor or update the pin:
```bash
git clone https://github.com/simonw/sqlite-utils.git
cd sqlite-utils && git checkout <tag>
git rev-parse HEAD   # record the commit here
```

### Fixed test subset

The full suite (~742 test functions, 800+ collected with parametrization) is too
large and redundant to run every benchmark iteration. The fixed subset below
(111 collected tests, ~0.2s) was chosen for: no network calls, no unseeded
randomness/timing dependence, no compiled-extension or docs/ dependency, and
coverage of distinct CPU/memory muscles rather than overlapping CLI wrappers
around the same logic.

```bash
pytest \
  tests/test_fts.py \
  tests/test_analyze_tables.py \
  tests/test_m2m.py \
  tests/test_extract.py \
  tests/test_upsert.py
```

| File | Tests | CPU muscle |
|---|---|---|
| test_fts.py | 51 | Tokenization/indexing — builds FTS index tables |
| test_analyze_tables.py | 16 | Full column scans, distinct-value counting |
| test_m2m.py | 11 | Multi-table join queries |
| test_extract.py | 15 | Lookup-table extraction/dedup from repeated values |
| test_upsert.py | 18 | Repeated insert/update cycles keyed on hashed PKs |

Excluded and why:
- `test_docs.py` — asserts against the `docs/` directory, which was stripped
- `test_hypothesis.py` — property-based, generates its own inputs each run
- `test_gis.py` — requires the SpatiaLite compiled extension (arch risk)
- `test_cli_bulk.py` — spawns real OS subprocesses (`subprocess.Popen`), not
  just in-process Click calls; adds process-scheduling noise
- All other files — CLI-level or redundant wrappers around the same logic
  already exercised by the five files above
