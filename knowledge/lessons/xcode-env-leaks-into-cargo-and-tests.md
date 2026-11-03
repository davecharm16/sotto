# Xcode's environment leaks into cargo builds and test hosts

**What happened (2026-10-04, Phase 1):**
1. The Xcode pre-build script runs `cargo build`. Xcode exports `MACOSX_DEPLOYMENT_TARGET` into script phases, and
   tract-linalg's build script tracks that variable (`EnvVarChanged { name: "MACOSX_DEPLOYMENT_TARGET" … }`). So
   every switch between an Xcode build and a terminal `cargo` build triggered a rebuild of more than 2 minutes, and
   unpinned builds also produced "built for macOS 26.0" linker warnings.
2. The test-run guard checked for an empty `XCTestConfigurationFilePath`. In the Xcode 26 test host that variable
   is **present but blank**, so the guard has to check that the variable is present, not that it has a value.

**Root cause:** both build tools and test hosts pass environment variables to child processes without saying so.
Anything that reads the environment changes behaviour depending on who launched it.

**Rule for next time:**
- Pin the variables cargo cares about in `DeepFilter/.cargo/config.toml` (`[env] MACOSX_DEPLOYMENT_TARGET = "13.0"`),
  and `unset` them in the Xcode script phase. Then both launchers produce the same fingerprint, and a build with
  nothing to do takes 0.3–0.5 s in both.
- To detect a test host: `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`. Check that it
  is present. Never compare it to an empty string.
- When a cargo build is unexpectedly slow, run it with `CARGO_LOG=cargo::core::compiler::fingerprint=info` to see
  which input changed.
