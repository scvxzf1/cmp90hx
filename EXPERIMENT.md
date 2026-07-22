# CMP 90HX controlled selector experiment

This copy is derived from the supplied archive.  It differs only in two ways:

1. It accepts the one additional `(ss0, ss1)` pair observed twice on the
   target card after the V67 candidate opened `FEAT_OVR_PLM` and the driver was
   unbound: `(0x00424054, 0x00000006)`.
2. It records kernel evidence from an epoch-based `journalctl --since` start
   time.

No register addresses or requested write values were changed.  The existing
two-write order, immediate and settled BAR0 readback checks, non-compute
invariants, FLR, stock-driver reload, RM issue-rate verification, and the
ten-minute emergency power-off timer remain intact.

`unlock.sh probe-after-candidate` is a no-write mode. It accepts only a fresh
or already-open PLM state, captures the post-candidate BAR0 snapshot, and lets
the existing recovery trap restore the stock driver.
