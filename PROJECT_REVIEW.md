# Reducing the Cost of Working on Halide

*A maintenance-focused review of this tree (Halide main, July 2026). The two
companion reports cover the compiler's internal architecture:
`IR_AND_LOWERING_REPORT.md` explains the IRs and lowering, and
`MODULARIZATION_REPORT.md` works out how the compiler could become genuinely
layered modules. This report covers everything else: the build systems, the test
suite, CI, the runtime, the bindings, and the accumulated weight of code that no
longer pays rent. Every claim was checked against the actual tree — file paths
and line numbers are cited so each item can be verified or turned into a PR
without re-doing the investigation.*

---

## The shape of the problem

Halide's core compiler is in better health than most twelve-year-old compilers:
passes are plain functions, the include graph is closer to layered than it looks,
files are consistently formatted, pre-commit hooks catch orphaned sources, and
the CMake build is modern and disciplined. The maintenance cost does **not** come
from spaghetti. It comes from four specific structural facts, plus a long tail of
dead weight:

1. **Everything important is built twice.** A 2,560-line Makefile duplicates the
   CMake build — including the entire runtime cross-compilation matrix and a
   97-entry component list maintained by hand in both places.
2. **The test suite is architecturally expensive.** 700+ separate executables,
   each linking all of libHalide, verified by grepping stdout for the literal
   string `Success!`. The 141 error tests pass on *any* nonzero exit, whether or
   not the intended error fired. There is no way to test a compiler pass in
   isolation.
3. **CI multiplies that cost by a large matrix** — three LLVM versions on every
   platform on every PR — while *not* covering the things that matter most
   (64-bit x86 CMake builds are disabled; no GPU backend is tested; the fuzzer
   never runs).
4. **The GPU runtimes are six hand-written copies of the same program.** ~12,000
   lines across six backends implementing the identical 17-function device
   interface, on top of ~11,400 lines of hand-mirrored vendor headers.

Each section below explains one of these (and the long tail), ends with concrete
actions, and the report closes with a single ranked list.

---

## 1. One build system, not two

The root `Makefile` is 2,560 lines and is a complete, parallel implementation of
the build: libHalide, the runtime, every test group, generators, tutorials,
autoschedulers, and a `distrib` packaging target. `README.md` (lines 405–407)
already declares it unsupported: *"We do not provide support for the Makefile.
Feel free to use it, but if anything goes wrong, switch to the CMake build."* Yet
it is still maintained in practice, because it *must* be edited in lockstep with
CMake:

- The runtime component list — exactly 97 entries — exists verbatim twice:
  `RUNTIME_CPP_COMPONENTS` (`Makefile:826`) and `RUNTIME_CPP`
  (`src/runtime/CMakeLists.txt:4`). Same for the `.ll` modules, the `.bc`
  modules, and the exported runtime headers. Add a runtime file, edit two build
  systems.
- The trickiest build logic in the repo — cross-compiling the runtime to LLVM
  bitcode per target triple, 32/64-bit × debug/release × OS — is implemented
  twice (`Makefile:1096–1160+` and `src/runtime/CMakeLists.txt:157–397`).
- Test discovery *diverges in kind*: the Makefile globs `test/*/` directories
  while CMake registers tests per-file, so the two systems can silently cover
  different sets of tests.
- The documentation has already drifted: README says the Makefile needs "LLVM 17
  or greater"; the real floor is LLVM 21 (`CMakeLists.txt:160`,
  `src/LLVM_Headers.h`). One straggler rule still compiles with `-std=c++11`
  (`Makefile:1248`) while the project is C++17.
- `apps/` doubles the duplication: 33 apps have Makefiles, 30 have CMake, and
  *neither set is a superset* — `HelloPyTorch`, `auto_viz`, `hexagon_dma`,
  `resnet_50`, and `simd_op_check` build only via make (tracked since #5374),
  while `HelloBaremetal` and `linear_blur` build only via CMake.
- A whole CI workflow (`testing-make.yml`, two OSes) exists just to keep the
  unsupported build alive.

The one thing the Makefile still provides that CMake doesn't match ergonomically
is `make correctness_foo` — build-and-run one test with no ceremony. That is a
small tooling gap, not a reason to maintain 2,500 lines: a ~20-line script (or a
documented `cmake --build build --target correctness_foo && ctest -R '^correctness_foo$'`
wrapper) closes it.

**Actions.** (a) Port the five make-only apps to CMake; (b) provide the
one-command single-test path; (c) delete the root Makefile, the per-app
Makefiles, and `testing-make.yml`. This is the single largest one-time reduction
in maintenance surface available: ~2,560 + 33 app Makefiles + one CI workflow +
the permanent two-place edit rule all disappear, with no user-facing API change.
If deletion needs a deprecation window, do (b) plus generate both component
lists from one shared manifest in the interim so the 97×2 lockstep edit dies
first.

---

## 2. Testing: the model is the cost

### 2.1 How it works today

Every test is a hand-rolled `main()` with `printf`; there is no test framework
anywhere in the tree. `cmake/HalideTestHelpers.cmake` creates **one executable
per source file** — ~416 correctness + 141 error + ~101 generator + 35
performance + the rest ≈ 700+ binaries, each linking `Halide::Test` and thus all
of libHalide. A test passes if its stdout matches the regex `Success!`
(`HalideTestHelpers.cmake:102`). Link time and binary count scale linearly with
test count, and this — multiplied by the CI matrix — is where the compute goes.

### 2.2 Error tests don't test the error

The 141 tests in `test/error/` work by doing something illegal and aborting.
CMake marks them `WILL_FAIL TRUE` (`HalideTestHelpers.cmake:95`) and links a
terminate handler (`test/common/expect_abort.cpp`) that converts `Halide::Error`
into a nonzero exit. Nothing checks *which* error fired: a test that aborts for
the wrong reason — a typo, an unrelated assertion, an error moved to a different
check — still passes. Only 2 of 141 actually catch and inspect the exception.
The suite therefore verifies "something went wrong," not "the diagnostic we
promise users still fires." Hardening this is mechanical: have each error test
declare an expected-message substring and match it with CTest's
`PASS_REGULAR_EXPRESSION` against the handler's output — one change to two CMake
functions, then a sweep adding one line per test.

### 2.3 There is no way to test a pass

Coverage of the ~90 lowering passes is almost entirely end-to-end: build a
pipeline that (hopefully) triggers the pass, JIT it, check the pixels. You
cannot feed a pass a `Stmt` and assert on the transformed `Stmt`; there is no
golden-file or FileCheck-style IR testing anywhere. (The closest thing,
`simd_op_check`, pattern-matches *disassembled machine code* — valuable, but
backend-level.) The consequences: pass regressions are detected far from their
cause, minimal reproducers are hard to write, and the cheapest kind of test to
maintain — input IR in, expected IR out — simply isn't available to
contributors. The building blocks exist (`IREquality`, the printer, the parser
in `test/fuzz`'s infrastructure); what's missing is a small harness and the
convention. This dovetails with `MODULARIZATION_REPORT.md` §3.2: the embedded
self-tests (17 `*_test()` functions compiled *into libHalide* and hand-wired
into `test/internal.cpp` — where `CodeGen_PTX_Dev::test()` is declared but
forgotten) should move out of `src/` anyway for layering reasons; moving them
into a real unit-test binary with auto-registration solves both problems at
once.

### 2.4 Infrastructure that exists but is switched off

Three finished pieces of test infrastructure are currently inert:

- **The fuzzers never run for real.** `test/fuzz/` has six libFuzzer targets,
  including a sophisticated differential simplifier fuzzer with automatic
  test-case minimization and C++ repro emission. No workflow builds with
  `-fsanitize=fuzzer` (`grep -ri fuzz .github/` is empty); in CI they run only
  as 1000-iteration stdlib-fallback smoke tests. Given that the simplifier is
  the component with the highest bug-severity (miscompiles), a nightly fuzz job
  is likely the highest bugs-found-per-CI-dollar change available.
- **Sharding is implemented and unused.** `test/common/test_sharding.h` is a
  GoogleTest-compatible sharder; its own comment says the buildbots don't use
  it. CI runs `ctest -j$(nproc)` per job instead.
- **`test/failing_with_issue/` is dead.** `test/CMakeLists.txt:67` says so
  literally: `# FIXME: failing_with_issue is dead code :)`. Its four
  reproducers for open issues are never compiled and are bit-rotting. There is
  no XFAIL mechanism — the `[SKIP-WITH-ISSUE-n]` regex is defined
  (`HalideTestHelpers.cmake:94`) but nothing uses it. Wiring these up as true
  expected-failures would mean a fix for the underlying issue is *detected* the
  day it lands.

### 2.5 Performance tests are a flaky gate

Performance tests assert hard thresholds ("vectorized must beat scalar",
`test/performance/vectorize.cpp:88`) and CI papers over the resulting flakiness
with `--repeat until-pass:5` (`testing-linux.yml:109`). Five retries both burns
CI time and masks real regressions — a genuine 4-out-of-5 slowdown still passes.
The honest design is to gate PRs only on coarse "didn't catastrophically break"
checks and move real performance tracking to a non-gating benchmark channel with
history.

**Actions.** In order of value-per-effort: (1) expected-message matching for all
error tests; (2) a nightly libFuzzer job; (3) a pass-level IR test harness plus
moving the 17 embedded self-tests into a framework-based unit test binary
(auto-registration, filtering, per-assertion diagnostics — and it un-breaks the
orphaned PTX test); (4) revive `failing_with_issue` as XFAIL; (5) consolidate
small tests into fewer binaries to cut link cost (a framework gives this for
free); (6) de-flake the performance gate.

---

## 3. CI: spend where the risk is

The GitHub Actions setup is well-built in the small — cancel-in-progress
everywhere, careful `paths-ignore`, and a genuinely nice bot that pushes
formatting auto-fixes back to PR branches. The problems are allocation:

- **The matrix multiplies the wrong dimension.** Every PR builds and tests
  against *three* LLVM versions (main/22/21) on Linux, Windows, and ARM —
  roughly 20+ jobs — even though LLVM-version breakage is (a) rare, (b) almost
  always caught by one version leg, and (c) already monitored by the nightly
  `upgrade-llvm.yml` job. Presubmit on the primary LLVM only, with the other
  versions nightly, would cut PR CI cost roughly in half with negligible added
  risk.
- **Meanwhile the primary configuration isn't tested.** `testing-linux.yml:38`:
  `bits: [ "32" ]  # Intentionally not 64, as we haven't configured self-hosted
  runners for it yet.` The same on Windows. So the CMake presubmit exercises
  i686 — a configuration almost no user ships — and never x86-64, which
  standard GitHub runners provide natively. No GPU backend is exercised at all
  (zero references to cuda/vulkan/metal/opencl targets in any workflow), which
  makes the 12k-line GPU runtime effectively untested (see §4).
- **The LLVM version number lives in ~8 places and they already disagree**:
  `pip.yml` says 22.1.0 (with a `TODO: detect this from repo somehow: #8406`),
  the clang-format/tidy scripts pin 21, pre-commit pins v21.1.8, brew installs
  `llvm@21`, make/ecosystem workflows say 22, `pyproject.toml` groups say
  main/22/21 — and `pyproject.toml:212` references a `ci-llvm-20` group that no
  longer exists. Every LLVM bump is a multi-file scavenger hunt. One source of
  truth (resolve #8406) turns it into one edit.
- **Small dead weight**: `run-clang-format.sh` duplicates the pre-commit
  format hook (different pinned version, called by nothing — delete it); the
  `skip_buildbots` label and README's buildbot links point at an era that ended
  (CI is fully on Actions); the devcontainer installs LLVM 21 while the project
  is on 22; the `.clang-tidy` file disables ~130 checks with zero recorded
  rationale, so nobody can ever prune the list; there is no `CODEOWNERS` even
  though CONTRIBUTING.md itself describes the "who reviews this?" problem.

**Actions.** Rebalance: 1 LLVM version presubmit / 3 nightly; add x86-64
Linux+Windows legs (free on hosted runners); add one GPU leg even if it's just
CPU-emulated OpenCL or a Metal run on the macOS runner; single-source the LLVM
version; delete `run-clang-format.sh`; add CODEOWNERS; annotate `.clang-tidy`.

---

## 4. The runtime: six copies of the same program

The runtime's freestanding design (no libc, compiled to per-target bitcode) is a
real constraint and mostly well-handled. The costs that *aren't* inherent:

- **GPU backend duplication.** `d3d12compute.cpp` (4,478 lines), `opencl.cpp`
  (1,970), `vulkan.cpp` (1,490), `cuda.cpp` (1,485), `metal.cpp` (1,384),
  `webgpu.cpp` (1,176) each independently implement the identical 17-function
  `halide_device_interface_impl_t` contract — device malloc/free, copies, crop,
  slice, wrap/detach — plus their own dlopen/proc-table idiom and error
  plumbing. The shared machinery already half-exists
  (`device_buffer_utils.h`, `device_interface.cpp`'s `halide_default_*`,
  `gpu_context_common.h`); it's just not pushed far enough. A trait-based
  driver where a backend supplies only alloc/copy/sync/launch primitives would
  collapse thousands of lines and — more importantly — make the seventh backend
  cheap and the existing six uniform. This is also the precondition for making
  "add a GPU CI leg" meaningful.
- **The lock library is the scariest file in the repo.**
  `synchronization_common.h` (948 lines) is a hand-rolled port of parking-lot
  mutexes/condvars with **23 TODO/FIXME markers, several of them open
  correctness questions** ("Is 1 the right value…", "Is it safe to ignore
  return value here"), and `thread_pool_common.h` (878 lines) sits on top with
  its own unresolved acquire/release-count TODO (line 783). Test coverage of
  both: none — `test/runtime/` (8 files, 1,153 lines) tests only the
  allocators/containers. Whatever else happens, the synchronization and thread
  pool code should get direct stress tests; they underpin every parallel
  pipeline Halide runs.
- **~11,400 lines of hand-mirrored vendor headers** (`mini_d3d12.h` 6,895,
  `mini_webgpu.h` 2,633, `mini_cl.h`, `mini_cuda.h`, …) must be manually
  diffed against upstream SDKs forever. Where upstream ships a permissively
  licensed header (as already done for Vulkan/SPIR-V in `dependencies/`),
  consume it instead.
- **41 tiny per-OS files** (`*_threads`, `*_clock`, `*_yield`,
  `*_cpu_features`, …) make "support a new OS" a file-scavenger hunt; a thin
  OS-trait consolidation would cut the count substantially.
- **No `src/runtime/README.md`.** The freestanding rules, the bitcode build
  model, and the ABI live only in scattered comments and the 2,257-line
  `HalideRuntime.h`. This is the cheapest fix in this whole report and pays for
  itself with the first new runtime contributor.

On the bindings side: the Python bindings are healthy (scikit-build-core driving
the same CMake — no duplicate build logic) but pin pybind11 2.11.1 (old), ship
**zero `.pyi` type stubs** (so no IDE/typing support for the 5k lines of
bindings), and carry a 906-line Python reimplementation of generator argument
machinery (`_generator_helpers.py`) that shadows the C++ `AbstractGenerator`.
Stubs via `pybind11-stubgen` + a pybind bump are cheap, user-visible wins.

---

## 5. Dead weight and modernization

Things the project pays for that no longer pull their weight, roughly ordered by
(cost saved ÷ breakage risk):

- **`Generator.h` is 4,157 lines and contains two APIs.** Old-style and
  new-style Generators coexist (`Generator.h:3136` — "empty if old-style
  Generator"), with internal pleas on record (`:1449` — "Better yet, find a way
  to remove these"). Retiring the old style behind one deprecation cycle is the
  biggest single header simplification available. Relatedly, the Generator
  CMake API (`cmake/HalideGeneratorHelpers.cmake`, 1,447 lines, 20 functions)
  is the largest and most user-facing CMake surface — worth splitting and
  testing, though only as a behavior-preserving refactor.
- **D3D12Compute is the weakest backend by every measure**: largest runtime
  file (4,478 lines) + 2,267 lines of codegen, Windows-only, 29 TODO/FIXME/HACK
  markers, zero CI coverage, and a 6,895-line hand-mirrored SDK header. Either
  it gets a CI leg and an owner, or it should be formally deprecated. WebGPU
  and Vulkan are self-labeled WIP/BETA in `doc/` — accurate labels; the
  decision there is just to keep the labels honest. PowerPC (198-line codegen)
  is cheap either to keep or to drop.
- **The two ML autoschedulers are near-clones.** `adams2019` and `anderson2021`
  each carry their own `FunctionDAG`, `LoopNest`, `State`, `Weights`, cost
  model generator, retraining tool, and checked-in binary weights — largely
  parallel file-for-file. Extracting the shared scaffolding into
  `autoschedulers/common/` cuts the duplication without dropping either.
  (`li2018` is tiny and is the only GPU-capable one — keep; `mullapudi2016`
  pulls in `std::regex` for trivial parsing — swap for the existing
  `ParamParser`.)
- **A C++20 bump has already been paid for.** Three parked TODOs are waiting on
  it (`Util.h:516`, `DecomposeVectorShuffle.h:71`, `Solve.cpp:401`), and much
  of `Util.h` becomes deletion: `popcount64`/`clz64`/`ctz64` → `<bit>`,
  `reinterpret_bits` → `std::bit_cast`, `starts_with`/`ends_with` → member
  functions, `reverse_adaptor` → `views::reverse`. (`meta_and`/`meta_or` →
  `std::conjunction`/`disjunction` needs no bump at all.) Given the LLVM 21+
  toolchain floor, compiler support is a non-issue.
- **Small confirmed cruft**: `IntegerDivisionTable.cpp` is 4,665 lines of
  committed generated data whose generator (`tools/find_inverse.cpp`) is in
  tree — generate it at build time; `CodeGen_PyTorch.cpp` + `HelloPyTorch` are
  CI-orphaned (make-only build, #5374) — revive or retire; dangling references
  to the already-deleted `Introspection` module linger in `Func.h` and
  `Serialization.cpp`; `util/Halide-VS2017.natvis` targets a dead toolchain;
  the two `HelloAndroid*` apps ship Apache-Ant build files (deprecated ~2015)
  and don't build in CI.

For the *architectural* simplification axis — extracting the expression language
and algebra as a standalone library, breaking the five couplings that violate
the layering — see `MODULARIZATION_REPORT.md`; its step 1 (move embedded tests
out of `src/`) and step 2 (a 50-line include-direction checker in CI) belong on
any short list, and both double as testing/CI improvements described above.

---

## The ranked list

If the goal is maximum reduction in carrying cost per unit of effort and risk:

| # | Action | Effort | Risk | What it buys |
|---|--------|--------|------|--------------|
| 1 | Delete the Makefile (port 5 apps, add a one-command test path first) | M | Low (contributor-workflow only) | Ends all build-logic duplication: 2,560 lines + 33 app Makefiles + one CI workflow + the 97×2 lockstep edit |
| 2 | Error tests assert the expected message | S | Low | Turns 141 vacuous tests into real diagnostics coverage |
| 3 | Rebalance CI: 1 LLVM presubmit / 3 nightly; add x86-64 legs; single-source the LLVM version | S | Low | ~2× cheaper PRs *and* coverage of the platform users actually ship |
| 4 | Nightly libFuzzer job (harness already exists) | S | None | Continuous miscompile-hunting on the simplifier for free |
| 5 | Stress tests for `synchronization_common.h` / `thread_pool_common.h` | M | None | De-risks the least-tested, highest-consequence code in the tree |
| 6 | Unit-test framework for the 17 embedded self-tests + a pass-level IR harness | M | Low | Isolated, fast pass tests; also modularization step 1 |
| 7 | Shared GPU device-runtime driver | L | Med | Collapses ~12k duplicated lines; makes backends uniform and testable |
| 8 | C++20 bump + `Util.h` cleanup | S | Low | Deletes hand-rolled std replicas; cashes in three parked TODOs |
| 9 | Retire the old-style Generator API (deprecation cycle) | M | Med (user-facing) | Biggest header in the tree shrinks; one API to document and test |
| 10 | Decide D3D12's fate: CI leg + owner, or deprecate | S–L | Med | Either way ends "4,478 untested Windows-only lines" limbo |

Plus the under-an-hour list: delete `run-clang-format.sh`; fix
`pyproject.toml:212`'s phantom `ci-llvm-20`; wire up or delete
`failing_with_issue/`; wire in the orphaned `CodeGen_PTX_Dev::test()`; write
`src/runtime/README.md`; add `CODEOWNERS`; purge the stale buildbot references
and the `Makefile:1248` `-std=c++11` straggler; generate `.pyi` stubs.

The through-line matches the modularization report's conclusion from the other
direction: **Halide's problems are physical, not conceptual.** Nothing here
requires redesigning the compiler. It requires deleting one of two build
systems, making the tests assert what they claim to test, pointing the CI budget
at the configurations users run, and factoring the one genuinely duplicated
subsystem (the GPU runtimes). All of it lands incrementally, and each item makes
the next one cheaper.
