# Contributing

## Build and test

    make            # CLI and library (needs libzstd)
    make test       # the judge: ./verify.sh HEAD, one verdict per claim, results/HEAD.json

A change is accepted with `make test` at 0 fail and every CI job green (`.github/workflows/ci.yml`: build and
round trips, API fuzzing under ASan+UBSan, portability, ARM, decoder source check; ClusterFuzzLite on pull requests).

## The judge is bit-perfect

Every decode is compared byte for byte with the original; fixture archives are compared with pinned sha256 (`verify/fixtures/`).
A new feature or a fixed bug comes with a claim in `verify/judges/HEAD.sh` (a script printing `name<TAB>pass|fail<TAB>
detail`) and, when it is about corrupt input, a negative control that shows the check can fail.

## The format is frozen

ACEPX2 (`docs/FORMAT_ACEPX2.md`, `docs/FORMAT_FAST.md`) does not change in a pull request. A format change starts as an
issue and ships only as a new header version. Changes to the bytes the encoder writes at
an existing level are format-level too: issue first.

## Pull requests

- one topic per pull request; CI green before review;
- no force-push to a branch under review: add commits, merges are not squashed;
- commit subject: `area: what changed (numbers)`, e.g. `CLI d: atomic --out FILE (200/200 corrupt archives leave no
  FILE)`; the body says how it was measured and where the log is (`results/`).

## License

Contributions are accepted under the MIT license of this repository (`LICENSE`). Code taken from elsewhere keeps its
license and is listed in `THIRD_PARTY_LICENSES`.
