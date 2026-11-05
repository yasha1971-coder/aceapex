# Security policy

## Supported versions

Only the latest release (2.6.x). Older releases get no fixes; upgrade.

## Reporting

Use GitHub private vulnerability reporting only: the **Security** tab of this repository -> **Report a vulnerability**.
Do not open a public issue for a vulnerability.

First reply within 7 days. No fix date is promised; a fix ships in the next release and is named in CHANGELOG.md.

Include: version or commit, the archive or input that triggers it (or how to make it), the call or command, what
happened.

## What counts

- a read or write outside the buffers given to the library (any API, any input);
- a crash or an abort on any input;
- a hang: a decode that does not return on a finite input;
- on a checked path (`aceapex d`, `aceapex_decompress_stream` with `ACEAPEX_STREAM_VERIFY`): success with bytes that
  differ from the original.

## What does not

- other bytes from the raw API (`aceapex_decompress`, `aceapex_decompress_mt`, `aceapex_decompress_region`) on a
  damaged archive: it does not hash its output by design, see README, section Integrity. Use a checked path;
- slow compression or high memory use within the documented bounds;
- the research code outside `src/` and `c/` (GPU prototypes, scripts).
