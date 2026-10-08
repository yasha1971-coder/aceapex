"""trace_patch.py <copy of the entropy-coder header> - adds two printf lines (state after each symbol / raw-bit field)."""
import sys
p = sys.argv[1]; s = open(p).read()
a = """    while (d->x < R3_L) { if (d->p >= d->e) { d->bad = 1; return s; } d->x = (d->x << 8) | *d->p++; }
    return s;"""
b = """        v |= (uint64_t)b << sh; sh += k; nb -= k; }
    return v;"""
assert s.count(a) == 1 and s.count(b) == 1
s = s.replace(a, a.replace("    return s;", '    if (r3_trace) printf("S %d %u %u %ld\\n", c, s, d->x, (long)(d->p - r3_trace_base));\n    return s;'))
s = s.replace(b, b.replace("    return v;", '    if (r3_trace && sh) printf("B %u %llu %u %ld\\n", sh, (unsigned long long)v, d->x, (long)(d->p - r3_trace_base));\n    return v;'))
s = s.replace('#include "refrel_format.h"', '#include "refrel_format.h"\n#include <stdio.h>\nstatic int r3_trace = 0; static const uint8_t* r3_trace_base = 0;', 1)
open(p, "w").write(s)
