[written by ChatGPT (AI) at the author's request; checked by the author]

# CROWN-2 research

The owner-authorized goal and forecasts are in [CALIBRATION.md](CALIBRATION.md).
The first task commit is `5a3d21d6b9765dc8cf7f00090e135f71a6324b8d` and contains
only the preregistration. No production ACEAPEX code or format is changed.

Current implementation is H2.1 only: an independently written packed-Psi inverse
with K=1/4/8/16/32, optionally prefetching independent next rows. libsais supplies
only suffix-array construction for our encoder; the inverse is our code.
The comparison reference is the unchanged pinned libbsc BWT API isolated in its
own DSO. See [DEPENDENCIES.md](DEPENDENCIES.md) for source isolation and build.

`CRN2BWT1` is an integrity-protected research representation, not an entropy-coded
archive. Little-endian fields: 8-byte magic; u32 kind, length, requested K,
primary row, index count; count u32 indices; n BWT bytes; u32 CRC32 of all preceding
bytes. Complete size is n+32+4*count. Kind 0 is our virtual-sentinel transform;
kind 1 preserves reference API bytes/indices. Length must be below 2^24 and match
the exact remaining payload before allocation. The container protects metadata
and payload; its negative controls are exercised in cloud correctness probes.

Cloud execution is explicit, after the source is committed, on ace-core:

```sh
python3 research/crown2-bwt/run_cloud.py --source-sha FULL_SOURCE_COMMIT
```

This creates exactly one labelled C4 SPOT VM with a two-hour DELETE limit,
verifies locked DEV-2 inputs, builds on Ubuntu 22.04, runs correctness/negative
controls, saves SHA-bound packet/restored-byte logs and optional instruction
availability, retrieves the evidence, and deletes only this task's VM. It does
not run the speed subcommand. Private inputs, packets, keys and transient build
data stay under the ignored `_local/` attempt directory. The controller records
compute-list-price estimates separately from disk/network/taxes; none is an
actual invoice. Its cloud resource operations use the already-authorized Ubuntu
GCP configuration; it never modifies IAM or shared firewall rules.

`cloud_job.py` saves failed methods/builds too. A failed method is a stop for
diagnosis, not permission to silently retune and rerun. A build/environment
failure is recorded separately from a codec correctness failure. No performance
claim follows from a C4 probe. All speed measurements require ace-core, the OVH
flock, pinned CPU0 and the preregistered admission and comparison controls.

`crown2_probe bench` additionally checks hostname `ace-core`. It times complete
inverse calls, with equal mutable-output preparation before the timer, one
verified warmup and a fixed decoded-byte repeat budget. SHA and byte checks are
outside the timer. H2.1 representation bytes must not be labelled compressed
archive bytes or compared as the final density axis.
