Draft for TurboBench #65 (NOT sent; Yakiv sends). No technical conclusions.

---

Thanks again. We have not been able to reproduce the crash yet with the v2026.11.06.164 release binaries, so we need a
few details to run exactly what you ran:

1. The exact command line (including `-e...`, any `t#`, `-b`, `-i`, `-C`, `-m`/`-M` options).
2. TurboBench: the release asset you used and its SHA-256, or the commit and build command if you built it yourself
   (compiler and version, makefile options).
3. Platform: OS and version, CPU model, and whether it ran on a GitHub runner or a local machine.
4. Input: the file name, size and SHA-256 (silesia.tar and enwik9 vary between sources).
5. Which `aceapex` level was running when it crashed, and how it ended: signal (SIGSEGV, SIGILL, SIGBUS, ...), exit
   code or a TurboBench error message, with the last lines of the output.
6. If possible, a backtrace or core file.

Thank you.
