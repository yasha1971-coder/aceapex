"""ledger_patch.py <copy of the entropy-coder header> - cost accounting in a COPY of the frozen v1 decoder: every decoded
symbol adds log2(4096 / f) bits to its context, every raw-bit field adds its bits to the context of the symbol decoded
just before it (bucket extra bits -> that value's context; ABS position -> the strand context 51; escaped literal byte ->
the literal's context). Decoding itself is unchanged."""
import sys
p = sys.argv[1]; s = open(p).read()
a = "    const uint32_t f = T->freq[c][s]; if (!f) { d->bad = 1; return 0; }\n"
b = "        v |= (uint64_t)b << sh; sh += k; nb -= k; }\n    return v;"
assert s.count(a) == 1 and s.count(b) == 1
s = s.replace(a, a + "    if (g_led) { g_led_sym[c] += 12.0 - log2((double)f); g_led_n[c]++; g_led_last = c; }\n")
s = s.replace(b, "        v |= (uint64_t)b << sh; sh += k; nb -= k; }\n    if (g_led) g_led_raw[g_led_last] += sh;\n    return v;")
s = s.replace('#include "refrel_format.h"', '#include "refrel_format.h"\n#include <math.h>\nstatic int g_led = 0, g_led_last = 0; static double g_led_sym[64]; static unsigned long long g_led_raw[64], g_led_n[64];', 1)
open(p, "w").write(s)
