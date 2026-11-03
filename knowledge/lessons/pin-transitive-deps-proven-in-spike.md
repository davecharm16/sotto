# Pin a git dependency's transitive versions exactly as the spike proved them

**What happened (2026-10-03):** the plan assumed upstream libDF (DeepFilterNet, rev `d375b2d8`) would build against
the same `tract 0.21.x` that Sotto already uses (0.21.15). It doesn't. tract 0.21.15+ moved to ndarray 0.16 and
removed `symbol_table`, and libDF uses ndarray 0.15. The wrap only built with `tract-* = "=0.21.4"` plus
`kstring = "=2.0.2"`, because kstring 2.0.5 needs rustc 1.96.

**Root cause:** a semver range (`0.21`) looked compatible, but its patch releases broke the API that libDF relies
on. Cargo resolves to the newest version in the range, so a fresh `Cargo.lock` breaks the build.

**Rule for next time:**
1. When adding a git or unmaintained dependency, run a throwaway build spike **before** planning around it.
2. Copy the exact pins that made the spike build (`=x.y.z`) into the real `Cargo.toml`, and commit `Cargo.lock`.
3. Build with `cargo build --locked`, so a lockfile drift fails loudly instead of resolving to a broken version.
4. Note the pins in the dependency's comment, with the reason, so a future upgrade knows what to re-check.

The proven pins are in [`../architecture/0001-spikes/dsp/wrap/Cargo.toml`](../architecture/0001-spikes/dsp/wrap/Cargo.toml).
