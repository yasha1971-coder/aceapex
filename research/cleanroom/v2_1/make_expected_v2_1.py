"""make_expected_v2_1.py <v2 package dir> <v1 reader binary> - EXPECTED.json v2.1 and v1_reader_responses.tsv (next to
this script) from the v2 package: same archives / fetch tables / fixtures; every refusal fixture gets the normative stage
and reason string of FORMAT_V1_SPEC.md 1.0.1 (§5, §15, §20), taken from the actual output of the v1 reader built from
research/refrel/refrel3v1.cpp @ 5b6d5ce (`decode <ref> <archive> <out>`: stderr `refused: <reason>` / `decode failed
(<reason>)`). The one fixture that reader accepts (meta_two_frames: it has no step 12a, FORMAT_V1_SPEC.md §21) gets the
step 12a reason `meta frame count`. Exits 1 if the v2 package does not match its SHA256SUMS or a response differs from
the normative table below. Not shipped."""
import hashlib, json, os, re, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
P, BIN = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
sha = lambda b: hashlib.sha256(b).hexdigest()

# normative (stage, reason) per refusal fixture: FORMAT_V1_SPEC.md 1.0.1 section of the check that fires
NORM = {"corrupt/truncated.rr3": ("open", "section sizes"),                     # §5 step 7
        "corrupt/header_byte.rr3": ("open", "block count"),                     # §5 step 8
        "corrupt/block_with_hash.rr3": ("decode", "block"),                     # §15
        "corrupt/valid_for_wrong_reference.rr3": ("open", "reference SHA-256 / size differs"),  # §5 step 11
        "corrupt/block_hash_byte.rr3": ("decode", "block XXH3"),                # §15, §12.2
        "corrupt/fasta_xxh3_field.rr3": ("decode", "FASTA XXH3"),               # §13 step 5
        "corrupt/blocks_swapped.rr3": ("decode", "block XXH3"),                 # §15, §12.2
        "corrupt/zero_context.rr3": ("decode", "block"),                        # §6.3, §15
        "corrupt/meta_two_frames.rr3": ("open", "meta frame count")}            # §5 step 12a
ACCEPTED_BY_V1_READER = {"corrupt/meta_two_frames.rr3"}                        # §21


def main():
    bad = [l for l in subprocess.run(["sha256sum", "-c", "--quiet", "SHA256SUMS"], cwd=P, capture_output=True, text=True).stdout.splitlines() if l]
    if bad: sys.exit("v2 package differs from its SHA256SUMS: %s" % bad[:5])
    exp = json.load(open(os.path.join(P, "EXPECTED.json")))
    exp["format"] = "refrel3 v1 (FORMAT_V1_SPEC.md 1.0.1)"
    exp["expected_version"] = "2.1"
    exp["refusal_reasons"] = ("corrupt[].reader_response: stage (open / decode) and reason = the normative reason string of "
                              "FORMAT_V1_SPEC.md 1.0.1 (sections 5, 15, 20), exact; a reported reason matches if it equals the "
                              "string or is the string followed by ' (' and a detail. message = the reference reader's message "
                              "for it (informative). Nothing may be written on a refusal.")
    rows, fails = [], 0
    with tempfile.TemporaryDirectory() as T:
        for c in exp["corrupt"]:
            a = c["archive"]; out = os.path.join(T, "out.fa")
            r = subprocess.run([BIN, "decode", os.path.join(P, c["reference"]), os.path.join(P, a), out], capture_output=True, text=True)
            written = os.path.exists(out)
            if written: os.remove(out)
            err = r.stderr.strip()
            m = re.fullmatch(r"refused: (.*)", err) or re.fullmatch(r"decode failed \((.*)\)", err)
            got = (("open" if err.startswith("refused: ") else "decode"), m.group(1)) if m else None
            st, rs = NORM[a]
            if a in ACCEPTED_BY_V1_READER: ok = r.returncode == 0 and got is None and written
            else: ok = got == (st, rs) and r.returncode == (2 if st == "open" else 3) and not written
            fails += not ok
            rows.append((a, r.returncode, err or "-", "yes" if written else "no", st, rs, ("accepted (no step 12a, spec 21)" if a in ACCEPTED_BY_V1_READER else "equal") if ok else "DIFFERS"))
            c.pop("reader_response", None)
            c["reader_response"] = {"stage": st, "reason": rs, "message": ("refused: %s" if st == "open" else "decode failed (%s)") % rs,
                                    "output_written": False}
    with open(os.path.join(H, "v1_reader_responses.tsv"), "w") as o:
        o.write("# v1 reader (refrel3v1.cpp @ 5b6d5ce, binary sha256 %s) on the refusal fixtures of package v2\n" % sha(open(BIN, "rb").read()))
        o.write("archive\texit\tstderr\toutput_written\tnormative_stage\tnormative_reason\tagreement\n")
        for r in rows: o.write("\t".join(map(str, r)) + "\n")
    json.dump(exp, open(os.path.join(H, "EXPECTED.json"), "w"), indent=1)
    open(os.path.join(H, "EXPECTED.json"), "a").write("\n")
    for r in rows: print("\t".join(map(str, r)))
    print("EXPECTED.json v2.1", sha(open(os.path.join(H, "EXPECTED.json"), "rb").read()), "| agreement", len(rows) - fails, "/", len(rows))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
