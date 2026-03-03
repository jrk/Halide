# Plan: Get Correctness Tests Running in the Wasm Build

## Context

The Halide compiler can be cross-compiled to WebAssembly via Emscripten and run under Node.js (`wasm/build.sh`). Currently only 3 smoke tests pass (AOT-only, using `compile_to_bitcode`). The full test suite is disabled (`-DWITH_TESTS=OFF`). We want the ~280 correctness tests running.

**Core challenge**: Correctness tests call `realize()` which does JIT compilation. Native JIT (mmap/mprotect for executable pages) is impossible in wasm.

**Key insight**: Halide already has a wasm JIT path (`HL_JIT_TARGET=wasm-32-wasmrt`) that compiles pipelines to wasm bytecode and interprets them via WABT — a pure software interpreter with no mmap/mprotect. This should work when the compiler itself is wasm. The result: "wasm interpreting wasm" — slow but functionally correct. Many correctness tests already have `[SKIP]` annotations for wasm-incompatible features (custom allocators, async, extern pointer args, debug_to_file, etc.), so the test suite is already partially wasm-aware.

## Step 1: Enable WABT in the wasm build

The wasm build currently sets `Halide_WASM_BACKEND=OFF` because WABT requires C++ exceptions. Fix this using Emscripten's native wasm exceptions (`-fwasm-exceptions`, fast, zero cost on non-throwing paths, requires Node 17+).

**Changes to `wasm/build.sh`**:
- Add `-fwasm-exceptions` to `CXXFLAGS`/`CFLAGS`/`LDFLAGS` before `emcmake cmake`
- Change `-DHalide_WASM_BACKEND=OFF` to `-DHalide_WASM_BACKEND=wabt`
- Add `-DHalide_ENABLE_EXCEPTIONS=ON`

WABT will be fetched and built automatically via the existing FetchContent setup in `cmake/dependencies.cmake` (line 19-25). The dependency provider (line 36-41) already sets `WITH_EXCEPTIONS="${Halide_ENABLE_EXCEPTIONS}"`, `BUILD_TESTS=OFF`, `BUILD_TOOLS=OFF`, `BUILD_LIBWASM=OFF`. With `Halide_ENABLE_EXCEPTIONS=ON` and `-fwasm-exceptions`, WABT should compile cleanly under em++.

**Key files**: `wasm/build.sh` (Stage 2 config), `cmake/dependencies.cmake` (already correct), `src/CMakeLists.txt:581-609` (wabt detection, already correct)

## Step 2: Enable correctness tests in the CMake wasm build

Change Stage 2 in `wasm/build.sh` from `-DWITH_TESTS=OFF` to:
```
-DWITH_TEST_CORRECTNESS=ON
-DWITH_TEST_ERROR=OFF     -DWITH_TEST_WARNING=OFF
-DWITH_TEST_PERFORMANCE=OFF  -DWITH_TEST_GENERATOR=OFF
-DWITH_TEST_RUNTIME=OFF   -DWITH_TEST_FUZZ=OFF
-DHalide_TARGET=wasm-32-wasmrt
```

This sets both `HL_TARGET` and `HL_JIT_TARGET` to `wasm-32-wasmrt` via `add_halide_test()` in `HalideTestHelpers.cmake:74`. When tests call `realize()`, Halide takes the wasm JIT path (via `WasmExecutor.cpp`): LLVM wasm backend → LLD wasm linker → WABT interpreter → results copied back.

The existing `CMAKE_CROSSCOMPILING_EMULATOR=node` makes CTest run each test as `node <test>.js`.

**Key files**: `wasm/build.sh`

## Step 3: Add Emscripten link flags for test executables

Every test executable needs these Emscripten settings. Add to `cmake/HalideTestHelpers.cmake` in the `tests()` function (after `target_link_libraries` on line 121):

```cmake
if (EMSCRIPTEN)
    target_link_options("${TARGET}" PRIVATE
        "SHELL:-s NODERAWFS=1"             # host filesystem access (temp files for JIT)
        "SHELL:-s ALLOW_MEMORY_GROWTH=1"   # dynamic memory (LLVM+Halide+WABT is large)
        "SHELL:-s INITIAL_MEMORY=536870912"  # 512MB initial
        "SHELL:-s STACK_SIZE=8388608"        # 8MB stack (LLVM recursive passes)
        "SHELL:-s NO_EXIT_RUNTIME=0"         # allow exit()
        "SHELL:-s ENVIRONMENT=node"
        "-fwasm-exceptions"
    )
endif ()
```

The `_test_internal` target in `test/CMakeLists.txt:6` also needs these flags (it's the PCH donor executable). If PCH under em++ causes issues, guard it with `if (NOT EMSCRIPTEN)`.

**Key files**: `cmake/HalideTestHelpers.cmake` (line 121), `test/CMakeLists.txt` (line 6-16)

## Step 4: Exclude incompatible tests and set timeouts

Add to `test/correctness/CMakeLists.txt`:

```cmake
if (EMSCRIPTEN)
    set(_wasm_excluded_tests
        correctness_load_library              # dlopen
        correctness_custom_auto_scheduler     # shared library loading
        correctness_input_larger_than_two_gigs   # >2GB in wasm32
        correctness_output_larger_than_two_gigs
        correctness_realize_larger_than_two_gigs
    )
    foreach (_test IN LISTS _wasm_excluded_tests)
        if (TARGET ${_test})
            set_tests_properties(${_test} PROPERTIES DISABLED TRUE)
        endif ()
    endforeach ()
endif ()
```

Many other tests already self-skip via runtime checks like `get_jit_target_from_environment().arch == Target::WebAssembly` (async, custom_allocator, extern_error, cast_handle, debug_to_file, etc. — found ~37 such tests). GPU tests self-skip via `target.has_gpu_feature()`. Arch-specific simd_op_check tests skip for non-matching architectures.

Set generous timeouts — WABT interpretation is ~100-1000x slower, plus the wasm host adds another ~2-5x:
```cmake
if (EMSCRIPTEN)
    set(CTEST_TEST_TIMEOUT 600)  # 10 min per test
endif ()
```

**Key files**: `test/correctness/CMakeLists.txt`

## Step 5: Extend `wasm/build.sh` with test support

Add `--run-tests` option:
```bash
if ${RUN_TESTS}; then
    log "Stage 4: Building and running correctness tests"
    cmake --build "${HALIDE_WASM_BUILD}" --target build_correctness -j "${JOBS}"
    cd "${HALIDE_WASM_BUILD}"
    ctest -L correctness -j1 --timeout 600 --output-on-failure
fi
```

Keep the existing `--run-test` smoke test as a quick sanity check.

**Key files**: `wasm/build.sh`

## Expected outcome

~150-200 of the ~280 correctness tests should pass. The rest will either:
- Self-skip via `[SKIP]` (~37 tests with wasm-specific skips, ~47 GPU tests)
- Be excluded at CMake level (~5 tests)
- Possibly timeout on very heavy computation tests

## All files to modify

| File | Change |
|------|--------|
| `wasm/build.sh` | Exception flags, `WASM_BACKEND=wabt`, enable tests, `--run-tests` |
| `cmake/HalideTestHelpers.cmake` | Emscripten link options for test executables |
| `test/CMakeLists.txt` | Emscripten link options for `_test_internal`, PCH guard |
| `test/correctness/CMakeLists.txt` | Exclusion list, timeout settings |

## Risks

| Risk | Mitigation |
|------|-----------|
| WABT doesn't build under Emscripten | Pure C++, straightforward; `-fwasm-exceptions` is the key flag |
| Memory pressure (LLVM+WABT in wasm) | `ALLOW_MEMORY_GROWTH=1`, 512MB initial, maybe `--max-old-space-size` for Node |
| Tests too slow | 600s timeout, `-j1`, exclude known-slow tests if needed |
| `ENABLE_EXPORTS` tests fail under Emscripten | Most extern tests self-skip; may need `-sEXPORT_ALL=1` for a few |

## Verification

1. Build: `./wasm/build.sh --skip-llvm --run-tests` (reuse existing LLVM wasm build)
2. Quick smoke: run `node correctness_argmax.js` — should print "Success!"
3. Full suite: `ctest -L correctness -j1 --timeout 600 --output-on-failure`
4. Triage failures: genuine bugs vs. tests needing skip annotations
