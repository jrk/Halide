# Could Halide Be Refactored into Loosely-Coupled Modules?

*Companion to `IR_AND_LOWERING_REPORT.md`. That report explains what Halide's pieces
are; this one asks how they could become genuinely separate modules with clear
interfaces — and in particular whether the expression language and the
computer-algebra/bounds machinery could be extracted as a standalone library for use
in other systems. Every claim about current coupling below was checked against the
actual `#include` graph and use sites of this tree (Halide main, July 2026).*

---

## 1. What "modular" means here, and why Halide is closer than it looks

First, terms. A codebase is *modular* when it divides into parts such that: each
part can be built, understood, and tested on its own; the parts are arranged in
layers, where lower layers never depend on higher ones; and the connections between
parts go through deliberate, documented interfaces rather than through whatever
happened to be reachable. The everyday measure of all this in C++ is blunt but
honest: **what does each header `#include`?** If the expression-language header
pulls in the runtime buffer type, then no one can use the expression language
without the runtime, whatever the architecture diagrams say.

Halide today looks like the opposite of modular: one library, one `Halide::Internal`
namespace, one generated all-in-one public header, roughly 370 files sitting in a
flat `src/` directory. But two structural facts make it far more separable than
that first impression suggests:

**Fact 1: the passes are already just functions.** Most compilers of Halide's age
accumulate a "pass framework": a manager that owns passes, shared analysis caches,
invalidation protocols. Halide has none of that. Almost every compiler pass is one
`.cpp`/`.h` pair exporting a plain function, typically `Stmt f(Stmt, <a few
values>)`, and the driver (`Lower.cpp`) simply calls them in order. Passes
communicate only through the IR they pass along. That means module boundaries
*between passes* are nearly free — all the real coupling lives in the type layer
underneath them.

**Fact 2: the core headers are already almost layered.** Measured directly:

- `Expr.h` — the expression language — includes only `IntrusivePtr.h` and `Type.h`.
  `Type.h` includes only `Error.h`, `Float16.h`, `Util.h`, and the runtime ABI
  header (a small, dependency-free C header defining things like `halide_type_t`).
- The algebra layer is strikingly clean at the header level: `Interval.h`,
  `Substitute.h`, `IREquality.h`, and `CSE.h` include only `Expr.h`; `Monotonic.h`
  and `ConstantBounds.h` sit on `ConstantInterval` and `Scope`; `Solve.h` needs
  `Bounds.h` + `Expr.h`; `Simplify.h` needs `Expr.h`, `Interval.h`,
  `ModulusRemainder.h`, `Scope.h`. Best of all, **`Bounds.h` needs only
  `Interval.h` and `Scope.h`**, with the front end's `Function` class only
  *forward-declared* — used by exactly one function signature.
- The mess is concentrated in two places. `IR.h`, which defines the actual node
  structs, includes `Buffer.h`, `Parameter.h`, `FunctionPtr.h`, and `Reduction.h`
  — because the node *fields* embed those front-end types, dragging the front end
  and the runtime buffer into everything that touches the IR. And `IROperator.h` —
  the helper header with all the operator overloads, which everything includes —
  gratuitously pulls in `Target.h` and the user-facing `Tuple.h` for a handful of
  convenience functions.

So the honest summary is: **Halide's layering already exists in design; it is
violated physically, by a small number of specific, identifiable facts.** The work
is not an architectural rescue. It is (a) making the implicit layers physical —
separate build targets with an enforced include direction — and (b) breaking
roughly five concrete couplings, catalogued in Section 3.

---

## 2. A proposed module decomposition

Refining the intuitive cut ("expression language / analyses / IRs / mid-level
compiler / lowering / backends") against the dependency structure as measured:

```
L0  halide-support     Small utilities everything uses: error handling, debug
                       output, the intrusive pointer, Scope, the runtime ABI
                       type declarations (halide_type_t, halide_buffer_t).

L1  halide-expr        The languages themselves: Type, the Expr and Stmt node
                       structs, visitors and mutators, the printer, structural
                       equality and hashing, substitution, the core operator
                       helpers, and the existing binary serializer.

L2  halide-algebra     Everything that *reasons* about expressions: the
                       simplifier, the rewrite-rule matcher (IRMatch), interval
                       arithmetic and boxes (Bounds), constant-integer intervals,
                       alignment analysis (ModulusRemainder), monotonicity,
                       the equation solver (Solve), CSE, variable renaming.

L3  halide-frontend    The user-facing program representation: Var, RDom,
                       Parameter, Buffer handle, Function/Definition, the
                       schedule structs, and the Func/Stage sugar.

L4  halide-midlevel    The first compilation phase: call-graph discovery,
                       realization order, schedule_functions, split replay,
                       inlining, bounds inference, allocation bounds,
                       sliding window, storage folding.

L5  halide-lowering    The second phase: storage flattening onward — the
                       library of Stmt→Stmt passes plus the Lower.cpp driver,
                       producing Module/LoweredFunc.

L6  halide-backends    CodeGen_LLVM and the per-architecture backends,
                       CodeGen_C, the GPU device code generators, the runtime.

L7  halide-driver      Pipeline, JIT execution, Generators, autoschedulers,
                       Python bindings — the products assembled from the rest.
```

Two placement decisions deserve defense, because they answer questions raised in
framing this exercise:

**Expressions and statements belong in one module (L1).** It is tempting to say
"Stmt is back-end IR; split it out of the front end's way." But measured against
reality: the statement node set is small; it shares the visitor/mutator machinery,
the type-tag scheme, the printer, and the serializer with expressions; and the
algebra layer legitimately operates on statements (statement simplification, boxes
over statements, CSE). Meanwhile the "mid-level" statement forms (Provide, Realize,
etc.) reference nothing from the front end — only names, types, and expressions —
so keeping them in L1 drags nothing upward. What actually distinguishes "front-end
IR" from "back-end IR" is not different node structs but *which nodes and which
Call kinds are legal at which phase* — better expressed as cheap per-phase validity
checkers (informal versions already exist) than as parallel type hierarchies.

**The mid-level compiler (L4) and lowering (L5) should stay separate, not merge.**
There is a real representation boundary between them: L4 works on the world of
multi-dimensional coordinates and symbolic sizes and is exactly the code that must
read front-end types (Function, Definition, schedules, LoopLevels); L5, from tuple
splitting and storage flattening onward, needs none of that — its passes consume
only IR plus a Target. So L4 depends on L3, while L5 depends only on L1/L2. That
asymmetry is the whole point of the cut — and the L4/L5 seam is precisely where the
companion report's reified mid-level IR would live, so keeping the modules separate
keeps that evolution path open.

A word on `Target` (the description of the machine being compiled for): 47 pass
headers take a `const Target &`. That looks like pervasive coupling, but `Target`
is a plain value type — architecture, OS, bit width, feature flags — with no heavy
dependencies. The pragmatic resolution is to move it *down* into L0/L1 as data
(stripping the few convenience methods that reach upward, like JIT feature
detection, which belong in L7), rather than fighting 47 signatures.

---

## 3. The five couplings that actually block the layering

### 3.1 IR nodes embed front-end handles — *the* coupling

The `Variable` node carries fields of type `Parameter`, `Buffer<>`, and
`ReductionDomain`; `Call` carries `FunctionPtr`, `Parameter`, and `Buffer<>`;
`Load`/`Store` carry `Parameter`/`Buffer<>`. These fields are *why* `IR.h` includes
the front-end headers, and why you cannot today compile the expression language
without also compiling `Parameter`, `Buffer` (which brings the runtime buffer
template and the device interface), and the function-pointer machinery.

Why do the fields exist? They let an expression carry its own symbol table: a
Variable that refers to a runtime parameter *points at* that parameter, so any
later pass can look up its declared range without a global environment. It is a
genuinely convenient design — and the fields are load-bearing for lifetime
management too (a `Call`'s pointer keeps the callee's definition alive, with a
deliberate weak-pointer discipline to avoid cycles).

The measured good news: **the algebra layer treats these fields as opaque cargo.**
The simplifier's only contact with them is passing `op->func, op->value_index,
op->image, op->param` through unchanged when it reconstructs a node
(Simplify_Call.cpp:870, Simplify_Exprs.cpp:395–448). Interval analysis consults
them in a handful of places (an image parameter's declared bounds; the value bounds
of a called function — exactly two sites in Bounds.cpp). Nothing in L2 needs their
*types*; it needs, at most, two or three narrow *queries*.

Options for breaking the coupling, in increasing ambition:

1. **A type-erased annotation slot.** Replace the typed fields with one opaque,
   reference-counted annotation pointer whose concrete types live in L3. The few
   passes that need the payload (storage flattening attaching output parameters to
   stores; the image-checks pass; codegen resolving symbols) downcast via the same
   tag-comparison idiom the IR already uses for nodes. Mechanical; preserves
   lifetime semantics; costs some static typing and touches every `Call::make` /
   `Load::make` call site.
2. **Small abstract interfaces defined in L1** (`SymbolBinding`, `BufferLike`)
   that the L3 types implement — keeps the algebra's queries typed, at the price
   of virtual dispatch in hot paths and interfaces that tend to grow.
3. **Side tables keyed by name** — strip the fields entirely. Rejected: Halide
   expresses per-call-site facts through these pointers (wrapper substitution
   redirects the function pointer of *individual* call sites, WrapCalls.cpp),
   which a name-keyed table cannot represent, and object lifetime currently rides
   on them.

Recommendation: option 1, with a thin typed accessor for the two or three queries
L2 makes. This is the refactor to do *first*: it is wide but shallow, and every
other boundary firms up behind it.

### 3.2 `Bounds.cpp` reaches into the front end — for three fixable reasons

The bounds implementation file includes `Func.h`, `Param.h`, `Var.h` — apparently
damning for extractability. Inspection shows three separable causes:

- **One function is mis-homed.** `compute_function_value_bounds` walks the
  front end's function environment to bound each function's *values* (e.g. "this
  function returns a uint8, so its values lie in [0,255]"). That is mid-level
  compiler logic living in the algebra file; move it to L4. What the core box
  machinery actually needs is a **call-bounds oracle** — "given this Call node,
  what interval can its value take?" — passed in as a callback or small
  interface. The existing `FuncValueBounds` map already *is* that oracle in data
  form; the change is making it a parameter of the module boundary instead of a
  type defined in terms of `Function`.
- **The file contains its own test suite** (`bounds_test()`, Bounds.cpp:3549),
  which builds little pipelines with `Func` and `Var`. Tests compiled into the
  library force upward includes; moving them to the test tree deletes whole edges
  of the include graph. The same pattern recurs across the codebase (Solve,
  IRMatch, and others carry embedded tests) — **relocating embedded tests is the
  cheapest single decoupling win available.**
- The box machinery special-cases calls of kind Halide/Image in two places —
  subsumed by the oracle above.

### 3.3 `IROperator.h` reaches upward

The universal helper header includes `Target.h` (for a few expression helpers that
mention target features — needing Target only *as data*, resolved by moving Target
down per Section 2) and `Tuple.h` (for `Tuple select(...)` overloads — pure
user-facing sugar). Split it into the core expression helpers (L1) and a small
front-end sugar header (L3), with a deprecation shim. Mechanical, low-risk, and it
un-links the single most-included header in the codebase from the front end.

### 3.4 Lowering instantiates backends — a dependency pointing the wrong way

GPU offloading works by having a *lowering pass* construct a device code generator
and compile kernels to PTX/SPIR-V right there, mid-lowering
(OffloadGPULoops.cpp); the Hexagon path goes further and produces a linked shared
object inside a pass. As written, L5 depends on L6 — backwards.

The fix is standard dependency inversion: L5 defines a narrow abstract interface —
"add this kernel; give me the compiled bytes" — plus a registry; the backends in
L6 register implementations; the driver in L7 wires them together. The interface
essentially already exists as the virtual API of `CodeGen_GPU_Dev`; the work is
moving the *instantiation decision* out of the pass. A pleasant side effect: GPU
lowering becomes testable with a mock device backend, no GPU toolchain required.

### 3.5 The front end's convenience methods couple it to the whole compiler

`Func::realize()` and `compile_to_*` give the user-facing handle a direct path
through Pipeline → lowering → JIT → LLVM. Ergonomically right; structurally it
means "include Func.h, link everything." The split that matters is between
`Function`/`Definition`/`Schedule` — pure data, which never call into lowering —
and the `Func` sugar layer that owns the compilation entry points. Making the data
layer an honest library and letting the top-level product provide `realize` (via a
small indirection installed at startup) keeps user ergonomics while letting tools
that only *build or inspect* pipelines — serializers, autoschedulers,
schedule-search experiments, the companion report's mid-level prototypes — link
L3+L4 without LLVM.

### 3.6 Honorable mention: ambient global state

Name-uniquing counters, installed error handlers, debug-level flags, and the
compiler logger are process globals used from every layer. They do not block the
refactor, but they *do* affect embedding an extracted library into a host system
that has its own notion of context (two hosts in one process would share
counters and error handlers). An extracted library should either accept an
explicit context object or document the globals as process-wide policy. (The
thread-safety battle here was already fought and won — the counters are atomic —
so this is hygiene, not correctness.)

---

## 4. The prize: `halide-expr` + `halide-algebra` as a standalone library

What the extracted pair would contain, following the measured boundaries:

- **halide-expr**: the type system (over the self-contained runtime ABI header);
  the ~30 expression and 17 statement node kinds, with annotation slots instead
  of front-end fields; visitors/mutators; the printer; structural
  equality/hashing; substitution; and — a real differentiator — the existing
  binary serializer, which gives the extracted IR a stable interchange format on
  day one.
- **halide-algebra**: `simplify(expr-or-stmt, scope of known intervals and
  alignments)`; `can_prove(condition)`; the rewrite-rule matcher; interval
  arithmetic with symbolic and possibly-infinite endpoints; box/region
  computation over statements (with the call-bounds oracle from §3.2); alignment
  (modulus/remainder) analysis; monotonicity classification; the solver
  (`solve_expression`, solve-for-interval); CSE; and correlated-difference
  cancellation.

Why this is worth wanting: **there is no comparable off-the-shelf package.** What
Halide has, and others lack, is a *symbolic* algebra over machine-integer and
float expressions designed for **directional conservatism** — every operation
knows whether it is computing a lower or an upper bound and rounds the safe way —
with Euclidean division, explicit wrap-vs-no-overflow integer semantics, vector
types, and proof obligations of the shape compilers actually face ("can this loop
bound ever exceed that allocation size?"). Systems needing this have
re-implemented it: TVM's `arith::Analyzer` is a direct descendant; MLIR grew its
own integer-range and Presburger libraries; each autodiff or polyhedral hybrid
rolls its own. Halide's is old, battle-hardened, and its simplifier corpus has
been the subject of published formal-verification work — an extracted library
makes that asset reusable, and independently fuzzable and verifiable.

Honest caveats for a would-be external user:

- **The semantics come as a package.** The rewrite corpus is sound only under
  Halide's rules: signed ints of ≥32 bits never overflow, narrower/unsigned
  wrap, division by zero yields zero, Euclidean rounding, fast-math floats. A
  host language with C semantics cannot adopt the rules unmodified. The library
  must export these semantics loudly (today they live in a comment block,
  IR.h:39–76).
- **Symbols are strings** bound in scope stacks. A host with its own symbol
  representation needs an interning shim at the boundary. Acceptable, but part
  of the contract.
- **The rule corpus is both the value and the burden.** The simplifier is tens
  of thousands of lines of carefully ordered rewrite rules. Extraction means
  committing to a stable public surface *over* it (simplify / can_prove / the
  matcher for user-supplied rules) while keeping rule internals private and
  free to churn.

---

## 5. A realistic, incremental sequencing

Ordered so that each step lands independently, keeps every test green, and makes
the next step smaller. No big-bang required; steps 1–3 are pure hygiene with no
design risk.

1. **Move the embedded self-tests out of `src/`.** Deletes many upward include
   edges outright (§3.2), shrinks the shipped library, zero design risk.
2. **Add layer-checking to CI immediately**, against the *current intended*
   layers, with a whitelist of known violations. A fifty-line script over
   `#include` lines suffices. Every later step shrinks the whitelist; no
   regression can sneak in. This is the highest-leverage single action, because
   it converts an aspiration into a ratchet.
3. **Split `IROperator.h`; move `Target` down; prefer forward declarations**
   where headers only name types (§3.3, §2).
4. **Introduce the call-bounds oracle and relocate
   `compute_function_value_bounds`** (§3.2). Small; detaches the algebra layer
   from front-end semantics.
5. **The annotation-slot refactor of the IR node fields** (§3.1). The big
   mechanical one; do it in one change, preserving typed accessors so downstream
   diffs stay reviewable.
6. **Split the build into object libraries along L0–L7** with explicit
   public/private include sets — physical modules, still shipping one installed
   `libHalide`. Trivial once the include graph is clean; a fight if attempted
   before.
7. **Invert the lowering→backend instantiation** (§3.4); then, optionally,
   publish `halide-expr`/`halide-algebra` as separately buildable — and
   separately fuzzable — targets.

Deliberately **not** proposed: a pass manager (the pass-as-function convention is
a strength, not a gap); splitting Expr and Stmt into separate type hierarchies;
replacing string symbols wholesale; namespace reorganizations. Each would be
high-churn surgery for a problem Halide does not actually have.

---

## 6. Summary table: where it's easy, where it's hard

| Boundary | Difficulty | The blocker, in one line |
|---|---|---|
| algebra ← expr | **Easy** | Already header-clean; only embedded tests and two oracle sites violate it |
| expr ← front-end handles | **Hard but mechanical** | Node fields (§3.1): wide blast radius, shallow semantics |
| expr ← runtime buffer type | Medium | Falls out of §3.1; the ABI *declarations* are fine as L0 |
| front-end data ↔ Func sugar | Medium | `realize()`/compile entry points need an installed indirection (§3.5) |
| mid-level ← front end | **Correct as-is** | L4 is *supposed* to read Function/Schedule — don't fight it |
| mid-level / lowering | **Easy** | A real representation boundary already exists (storage flattening) |
| lowering ← backends | Medium | Invert the in-pass GPU/Hexagon codegen instantiation (§3.4) |
| backends ← everything | Easy | Already isolated behind the CodeGen classes and one LLVM header shim |
| ambient globals | Medium | Only matters for embedding the extracted library (§3.6) |

The through-line: **Halide's modularity problem is physical, not architectural.**
The design already has the right layers; they were never mechanically enforced,
and five specific conveniences — embedded node handles, tests inside
implementation files, one kitchen-sink helper header, backend instantiation
inside lowering passes, and compile methods on the front-end sugar — blurred
them. All five are fixable incrementally. The first three steps alone would make
the expression language and the algebra extractable — and that is where most of
the value for the outside world lies.
