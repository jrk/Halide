# Refactoring Halide into Loosely-Coupled Modules — A Reflection

*Companion to `IR_AND_LOWERING_REPORT.md`. That report describes what the pieces are;
this one asks how they could become genuinely separate modules with clear interfaces —
in particular, whether the expression language and the computer-algebra/bounds
machinery could be extracted for use in other systems. Claims about current coupling
are grounded in the actual include graph and use sites of this tree (Halide main,
July 2026).*

---

## 1. The starting point is better than its reputation

Halide today is one library, one `Halide::Internal` namespace, one generated
megaheader, ~370 files in a flat `src/`. That *looks* like a monolith. But two
structural facts make modularization far more tractable than for a typical compiler
of this age:

1. **Passes are already functions, not framework citizens.** There is no pass
   manager, no shared pass context, no analysis-invalidation protocol. Nearly every
   pass is one `.cpp`/`.h` pair exporting `Stmt f(Stmt, <a few value params>)`. The
   coupling between passes is entirely through the IR they exchange (plus naming
   conventions — see §4.5 of the companion report). Module boundaries between passes
   therefore cost nothing at the *interface* level; the work is all in the type layer
   below them.

2. **The core headers are already almost layered.** Measured directly:

   - `Expr.h` includes only `IntrusivePtr.h` + `Type.h`. `Type.h` includes only
     `Error.h`, `Float16.h`, `Util.h`, and the runtime ABI header.
   - The algebra headers are remarkably clean: `Interval.h` → `Expr.h` only;
     `Substitute.h`, `IREquality.h`, `CSE.h` → `Expr.h` only; `Monotonic.h`,
     `ConstantBounds.h` → `ConstantInterval` + `Scope`; `Solve.h` → `Bounds.h` +
     `Expr.h`; `Simplify.h` → `Expr.h`, `Interval.h`, `ModulusRemainder.h`,
     `Scope.h`. **`Bounds.h` needs only `Interval.h` + `Scope.h`, with `class
     Function` forward-declared** for one function (`compute_function_value_bounds`).
   - The mess concentrates in exactly two places: `IR.h` (the node definitions) pulls
     in `Buffer.h`, `Parameter.h`, `FunctionPtr.h`, `Reduction.h` — i.e., the node
     *fields* drag the frontend and the runtime buffer type into everything; and
     `IROperator.h` (the helper header everything uses) gratuitously includes
     `Target.h` and the user-facing `Tuple.h` for a handful of convenience overloads
     (`Tuple select(...)`, `target_arch_is(...)`).

So the honest summary: **the logical layering already exists; it is violated by a
small number of load-bearing physical facts.** The job is to make the implicit layers
physical (separate build targets with enforced include direction) and to break
roughly five specific couplings, detailed in §3.

---

## 2. Proposed module decomposition

Refining the user-suggested cut against the observed dependency structure:

```
L0  halide-support      Util, Error, Debug, IntrusivePtr, Float16, Scope,
                        runtime ABI types (halide_type_t, halide_buffer_t decl)
L1  halide-expr         Type, Expr/Stmt nodes, IRVisitor/IRMutator, IRPrinter,
                        IREquality, Substitute, IROperator(core), serialization of IR
L2  halide-algebra      Simplify, IRMatch, Interval, ConstantInterval,
                        ConstantBounds, ModulusRemainder, Bounds (expr/box level),
                        Solve, Monotonic, CSE, ExprUsesVar, UniquifyVariableNames,
                        SimplifyCorrelatedDifferences
L3  halide-frontend     Var, RDom/Reduction, Parameter, ImageParam, Buffer handle,
                        Function/Definition/FunctionPtr, Schedule.{h,cpp},
                        Func/Stage/FuncRef (sugar), Tuple, derivative/InlineReductions
L4  halide-midlevel     FindCalls, WrapCalls, RealizationOrder,
                        SimplifySpecializations, ScheduleFunctions, ApplySplit,
                        Inline, BoundsInference, AllocationBoundsInference,
                        SlidingWindow, StorageFolding    ("the mid-level compiler")
L5  halide-lowering     everything from SplitTuples/StorageFlattening through
                        find_intrinsics: the Stmt→Stmt pass library + Lower.cpp
                        driver; Module/LoweredFunc as its output type
L6  halide-backends     CodeGen_LLVM + per-arch, CodeGen_C, CodeGen_GPU_Dev family,
                        HexagonOffload's compilation half, runtime build
L7  halide-driver       Pipeline, JITModule, Callable, Generator, autoschedulers,
                        Python bindings
```

Notes on contentious placements:

- **Expr and Stmt stay in one module (L1).** The temptation is to say "Stmt is
  backend IR, split it out." Measured against reality: the Stmt node set is tiny,
  shares the visitor/mutator/type-tag infrastructure, the printer, and the
  serializer; and the algebra layer legitimately works on Stmts
  (`simplify(Stmt)`, `boxes_touched(Stmt)`, CSE, uniquify). The mid-level-only nodes
  (`Provide`, `Realize`, `Prefetch`, `HoistedStorage`) reference nothing from the
  frontend — only names, types, and Exprs — so they don't drag L3 into L1. What
  distinguishes "frontend IR" from "backend IR" is not the node struct definitions
  but *which nodes and which Call types are legal at which phase* — better expressed
  as per-phase validity checkers (cheap IRVisitors, several already exist informally)
  than as separate type hierarchies. Splitting the node set would force either
  duplicated infrastructure or a templated visitor layer; neither pays.

- **Mid-level (L4) vs lowering (L5): keep them separate.** The user asked whether
  they should be combined. The companion report's finding argues no: there is a real
  representation boundary (Provide/Realize/Call-Halide + symbolic bounds vs.
  flat Load/Store/Allocate), and L4 is exactly the part that reads the *frontend*
  types (Function, Definition, StageSchedule, LoopLevel). L5 needs none of that —
  from `split_tuples` onward, passes consume only the IR plus `Target`. The L4/L5
  boundary is also precisely where a reified mid-level IR (companion §8) would live;
  keeping the modules separate keeps that evolution path open. L4 depends on L3; L5
  depends only on L1/L2 (+ Parameter/Buffer, see §3.1). That asymmetry is the whole
  point of the cut.

- **Target** is annoying: 47 pass headers take `const Target &`. But `Target` is a
  value type (arch/os/bits + feature bitset) with no heavy dependencies; the clean
  resolution is to move it to L0/L1 as plain data and strip its convenience methods
  that reach upward (e.g. `natural_vector_size` is fine; JIT-detection helpers belong
  in L7). Fighting the plumbing instead (per-pass option structs) would be a large
  diff for no architectural gain.

---

## 3. The five hard couplings (and how to break them)

### 3.1 IR nodes embed frontend handles — *the* coupling

`Variable` carries `Parameter param; Buffer<> image; ReductionDomain
reduction_domain`; `Call` carries `FunctionPtr func; Parameter param; Buffer<>
image`; `Load`/`Store` carry `param`/`image`; `Prefetch` carries a `Parameter`.
This is why `IR.h` includes `Parameter.h`, `Buffer.h`, `FunctionPtr.h`,
`Reduction.h`, and why the expression language cannot today be compiled without the
frontend and the runtime `Halide::Runtime::Buffer`.

Observed usage pattern, which is the good news: **the algebra layer treats these
fields as opaque cargo.** The simplifier's only contact with them is passing
`op->func, op->value_index, op->image, op->param` through to reconstructed nodes
(Simplify_Call.cpp:870, Simplify_Exprs.cpp:395–448). Interval analysis consults them
in a handful of places (an ImageParam's declared bounds; `Call::Halide` value bounds
— exactly 2 sites in Bounds.cpp). Nothing in L2 needs their *types*.

Options, in increasing order of ambition:

1. **Type-erased annotation slot.** Replace the three concrete fields with one
   `IntrusivePtr<const IRAnnotation>` (or a small tagged handle) whose concrete types
   live in L3. Passes that need the payload (`storage_flattening` attaching output
   Parameters to Stores; `add_image_checks`; codegen resolving symbols) downcast via
   the same tag-compare idiom the IR already uses for nodes. Pros: mechanical,
   preserves refcount lifetime semantics (important: `Call::func` keeps Functions
   alive, with the deliberate weak-pointer discipline for cycles). Cons: loses static
   typing where it currently exists; ~hundreds of trivial call-site edits
   (`Call::make`/`Load::make` signatures).
2. **Interface classes in L1.** Define minimal abstract interfaces in L1
   (`SymbolBinding { name, kind }`, `BufferLike { dims, type, bound(d) }`) that
   `Parameter`/`Buffer`/`FunctionPtr` implement in L3. Pros: keeps queries typed
   where the algebra needs them (ImageParam bounds). Cons: virtual dispatch in hot
   simplifier paths unless done carefully; interfaces tend to grow.
3. **Side tables keyed by name.** Strip the fields entirely; carry a
   `map<string, Binding>` alongside the IR. Rejected: Halide leans on node-embedded
   identity in too many places (wrappers redirect `FunctionPtr`s *per call site* —
   WrapCalls.cpp — which a name-keyed table cannot express), and lifetime management
   of `FunctionContents` currently rides on these pointers.

Recommendation: option 1, possibly with a thin typed accessor layer for the two or
three queries L2 actually makes. This single refactor detaches L1+L2 from L3 and from
`runtime/HalideBuffer.h`, and it is *shallow* — wide blast radius, no semantic depth.
It should be done first, because every other boundary firms up behind it.

### 3.2 `Bounds.cpp` reaches into the frontend

Three distinct reasons, each with a different fix:

- `compute_function_value_bounds(order, env)` iterates `map<string, Function>` to
  bound each Func's *values*. This function is mid-level compiler logic that happens
  to live in Bounds.cpp; move it to L4. The core box machinery then needs only a
  **call-bounds oracle**: `Interval (*)(const Call *)` (or a small interface) passed
  into `bounds_of_expr_in_scope`/`BoxesTouched` — the existing `FuncValueBounds` map
  already *is* that oracle in data form; the change is making it a parameter of the
  module boundary rather than a type defined in terms of `Function`.
- Bounds.cpp includes `Func.h`/`Var.h`/`InlineReductions.h` substantially for the
  embedded self-test (`bounds_test()`, Bounds.cpp:3549) that constructs pipelines.
  Moving in-file tests to the test tree removes whole edges of the include graph;
  the same pattern (tests-in-cpp forcing upward includes) recurs across the codebase
  and is the cheapest single decoupling win available.
- `boxes_touched`'s special knowledge of `Call::Halide`/`Call::Image` (2 sites) —
  subsumed by the annotation/oracle designs above.

### 3.3 `IROperator.h` reaches upward

The universal helper header includes `Target.h` (for `strict_float` helpers,
`target_arch_is` — expression-level features that only need Target-as-data, resolved
by moving Target down per §2) and `Tuple.h` (for `Tuple select(...)` overloads —
pure user sugar). Split it: `IROperator.h` (L1: Expr helpers, casts, math) and a
small `FuncOperators.h`-style header in L3 for the Tuple overloads. Mechanical; the
only cost is a deprecation shim.

### 3.4 Lowering instantiates backends

`inject_gpu_offload` (OffloadGPULoops.cpp) constructs `CodeGen_GPU_Dev` instances and
compiles kernels to PTX/SPIR-V *inside a lowering pass*; `HexagonOffload.cpp` goes
further and produces a linked shared object mid-lowering. As-is, L5 depends on L6 —
backwards. Fix by inversion: define in L5 a narrow `DeviceCodegen` interface
(`add_kernel(Stmt, name, args) → handle; compile_to_src() → blob`) plus a registry;
L6 registers implementations; the driver (L7) wires them. The interface essentially
already exists (`CodeGen_GPU_Dev`'s virtual API) — the work is moving the
instantiation decision out of the pass and depending on the abstract class only.
This also creates, for free, the seam needed to test GPU lowering without any device
toolchain present.

### 3.5 Frontend convenience couples upward to the whole compiler

`Func::realize()`/`compile_to_*` give the user-facing handle a path to Pipeline →
Lower → JIT → LLVM. That is fine *for the product* but means "include Func.h, link
everything." The internal split that matters: `Function`/`Definition`/`Schedule`
(pure data, L3) versus `Func` (sugar + compilation entry points). `Function` already
never calls into lowering; the dependency is only in the sugar layer. Making
`halide-frontend` an honest data library and letting a top-level `halide` target
provide `Func::realize` (e.g. via a small indirection that L7 installs) keeps user
ergonomics intact while letting tools that only build/inspect pipelines (serializers,
autoschedulers, schedule搜索 tools, the proposed mid-level experiments) link L3+L4
without LLVM.

### 3.6 (Honorable mention) Ambient global state

`unique_name()` counters, the installed error handlers, `debug()` env-var levels, and
`CompilerLogger` are process globals used from every layer. They don't block
modularization, but they do block *concurrent* use of an extracted library by a host
system that has its own notion of context. An extracted halide-expr/algebra should
either accept a context object or document the globals as process-wide. (Halide
already fought and mostly won the thread-safety battle here — the counters are
atomic — so this is about embedding hygiene, not correctness.)

---

## 4. The prize: extracting `halide-expr` + `halide-algebra`

What the standalone library would contain, per the measured boundaries:

- **halide-expr**: `Type` (over `halide_type_t`, a self-contained ABI header),
  the ~30 Expr + 17 Stmt nodes with annotation slots instead of frontend handles,
  visitors/mutators, printer, structural equality/hashing, substitution, and — a
  genuine differentiator — the existing binary serializer/deserializer
  (Serialization.cpp/Deserialization.cpp), which gives the extracted IR a stable
  interchange format from day one.
- **halide-algebra**: `simplify(Expr|Stmt, scope of Intervals + alignments)`,
  `can_prove`, the rule-based `IRMatch` engine, interval arithmetic
  (`bounds_of_expr_in_scope` with ±∞-capable `Interval` and the constant-folding
  `ConstantInterval`), `ModulusRemainder` (alignment) analysis, monotonicity
  classification, `solve_expression`/`solve_for_inner_interval` (solver used by loop
  partitioning and RDom bound trimming), box/region computation over Stmts via a
  call-bounds oracle, CSE, and correlated-difference simplification.

Why this is worth extracting — there is no comparable off-the-shelf package:
a *symbolic* integer/float algebra designed for **conservative directional rounding**
(lower vs upper bounds), Euclidean div/mod, wrap-vs-no-overflow integer semantics,
vector types, and proof obligations of the "can this loop bound exceed that one"
form. Systems that needed this have re-implemented it (TVM's `arith::Analyzer` is a
direct descendant; MLIR grew `presburger` + `IntRangeInference`; every autodiff/
polyhedral hybrid rolls its own). Halide's is battle-hardened, and its simplifier
rules have been the subject of formal verification work — an extracted library makes
that asset reusable and independently fuzzable/verifiable.

Honest caveats for would-be external users:

- **The semantics come as a package.** The simplifier's soundness depends on Halide's
  specific rules: signed ≥32-bit = no-overflow, narrower/unsigned = wraps, x/0 = 0,
  Euclidean rounding, fast-math floats. A host system with C semantics (UB overflow,
  truncating division) cannot use the rewrite corpus unmodified. The library should
  export these semantics loudly (they are currently documented in a comment block,
  IR.h:39–76).
- **Strings-as-symbols.** Variables are bound by name in `Scope`s; a host with its
  own symbol representation needs an interning shim. Fine, but part of the API
  contract.
- **The rule corpus is the value and the maintenance burden.** Simplify_*.cpp is tens
  of thousands of lines of ordered rewrite rules; extraction means committing to a
  stable public surface over it (`simplify`, `can_prove`, `IRMatch` for user rules)
  while keeping the rule internals private.

---

## 5. Sequencing: a realistic incremental path

Ordered so each step lands independently, keeps all tests green, and makes the next
step smaller. Steps 1–3 are pure hygiene with no design risk; nothing depends on a
big-bang.

1. **Move embedded self-tests out of src/** (Bounds.cpp, Solve.cpp, IRMatch.cpp,
   etc. expose `*_test()` compiled into the library). Deletes many upward includes
   outright.
2. **Introduce layer-checking in CI now**, on the *current* logical layers, with a
   whitelist of known violations (a ~50-line script over `#include` lines suffices;
   IWYU optional). Every subsequent step shrinks the whitelist; nothing regresses.
   This is the single highest-leverage action because it converts an aspiration into
   a ratchet.
3. **Split IROperator; move Target down; forward-declare instead of include where
   cheap.** (§3.3, §2.)
4. **Call-bounds oracle + relocate `compute_function_value_bounds`** (§3.2). Small,
   detaches L2 from `Function` semantics.
5. **The annotation-slot refactor of IR node fields** (§3.1). The big one; do it as
   one mechanical change with typed accessors preserved
   (`Expr::as_parameter_ref()`-style) so downstream code diffs stay reviewable.
6. **CMake object-library split along L0–L7** with public/private include sets —
   physical modules, still one installed `libHalide` for users. Only after the
   include graph is clean is this step trivial rather than a fight.
7. **Invert the lowering→backend instantiation** (§3.4), then optionally publish
   `halide-expr`/`halide-algebra` as separately buildable (and separately testable/
   fuzzable) targets.

Deliberately *not* proposed: a pass manager, splitting Expr/Stmt into separate type
hierarchies, replacing string symbols wholesale, or namespace reshuffles. Each is
high-churn and, per the analysis above, addresses a problem Halide doesn't actually
have.

---

## 6. Ease/difficulty summary

| Boundary | Ease | The blocker, in one line |
|---|---|---|
| algebra ← expr | **Easy** | Already clean at the header level; only test code and 2 oracle sites violate it |
| expr ← frontend handles | **Hard-mechanical** | `Variable/Call/Load/Store` fields; wide but shallow (§3.1) |
| expr ← runtime Buffer | Medium | Falls out of §3.1; `halide_type_t`/`halide_buffer_t` decls are fine as L0 |
| frontend (data) ↔ Func (sugar) | Medium | `realize()`/compile entry points need an L7-installed indirection |
| mid-level ← frontend | **Correct as-is** | L4 is *supposed* to read Function/Schedule; don't fight it |
| mid-level / lowering | **Easy** | Real representation boundary already (storage flattening); keep separate |
| lowering ← backends | Medium | Inversion of GPU/Hexagon codegen instantiation (§3.4) |
| backends ← everything | Easy | Already isolated behind CodeGen_* + LLVM_Headers.h |
| global state | Medium | Context-object question only matters for external embedding |

The through-line: **Halide's modularity problem is physical, not architectural.** The
design already has the right layers; they were never enforced, and five specific
conveniences (embedded handles, in-file tests, IROperator's kitchen-sink includes,
in-pass backend instantiation, sugar-on-the-data-types) blurred them. All five are
fixable incrementally, and the first two or three steps would already make the
expression language + algebra extractable — which is where most of the external value
lies.
