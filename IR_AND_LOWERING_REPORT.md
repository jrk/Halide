# Halide's IRs and Lowering — A Deep-Dive Report

*Research report based on Halide main (July 2026, post-LLVM-22, commit ~3cf47df). All
`file:line` references are into `src/` of this tree. The report has three goals:*

1. *Document the three representations (functional frontend, schedule-as-data,
   imperative Stmt IR) and the two lowering phases that connect them, at
   re-implementation-grade detail.*
2. *Provide a blueprint for a standalone "Halide lite" recreation (§7).*
3. *Analyze exactly what is entangled inside the initial lowering step, to ground
   proposals for reifying a mid-level IR and making that step incremental (§8).*

---

## 1. The big picture

Halide's compiler has **two IR layers plus a schedule metadata layer**, connected by a
single monolithic pass (`schedule_functions`) followed by ~60 smaller passes:

```
  Func / Function / Definition            (functional layer: DAG of defs, no loops)
      + FuncSchedule / StageSchedule      (schedule: pure metadata, no IR)
      │
      │  schedule_functions (ScheduleFunctions.cpp)     ← "the big step"
      ▼
  Stmt with For/Realize/Provide/Call(Halide)/ProducerConsumer,
  loop bounds = dangling symbolic variables ("f.s0.x.min")
      │
      │  bounds_inference, sliding_window, storage_folding, ...
      ▼
  same node types, bounds now concrete Exprs (LetStmt-defined)
      │
      │  storage_flattening                              ← "the phase transition"
      ▼
  Stmt with Allocate/Store/Load, flat 1-D indices
      │
      │  vectorize / unroll / partition / cleanup / task outlining ...
      ▼
  LoweredFunc(s) in a Module  →  CodeGen_LLVM / CodeGen_C
```

Three facts shape everything:

- **The same `Expr` node types are used at every level.** A `Func` definition's RHS is
  an `Expr` in which references to other Funcs are `Call` nodes with
  `CallType::Halide`. There is no separate frontend expression AST.
- **The schedule is never IR.** Every directive (`split`, `vectorize`, `compute_at`,
  `compute_with`, ...) only edits small structs (`Split`, `Dim`, `LoopLevel`, ...)
  hanging off each `Function`. Lowering *interprets* this data.
- **The "mid-level IR" (Realize/Provide/Call-Halide + symbolic bounds) is real but
  transient**: it exists only as the output of `schedule_functions` and is consumed by
  `storage_flattening`. It is never constructible per-Func; §8 is about changing that.

---

## 2. The functional frontend layer

### 2.1 Function / FunctionContents

`Func` (Func.h) is user-facing sugar over `Internal::Function`, which is a handle
(`FunctionPtr`) to a refcounted `FunctionContents` (Function.cpp:63–175):

```cpp
struct FunctionContents {
    std::string name;                 // unique pipeline-wide (no '.')
    std::string origin_name;          // pre-wrapper name (Func::in / clone_in)
    std::vector<Type> output_types;   // one per tuple element
    std::vector<std::string> args;    // names of the pure dims (LHS of pure def)
    FuncSchedule func_schedule;       // function-wide schedule (§4.1)
    Definition init_def;              // the pure definition
    std::vector<Definition> updates;  // update definitions, in order
    std::vector<Parameter> output_buffers;         // one per tuple element
    // extern-definition state: extern_function_name, extern_arguments,
    //   extern_mangling, extern_function_device_api, extern_proxy_expr
    // tracing flags, debug_file, frozen flag, optional type/dim constraints
};
```

Key mechanics:

- **Group-based memory management.** `FunctionContents` live inside a refcounted
  `FunctionGroup` (Function.cpp:177–180); `FunctionPtr` (FunctionPtr.h:27–88) is
  either strong (owns the group) or weak (raw pointer + index). Within-group
  references must be weak; this is how self-referential updates (`f(x) = f(x)+1`) and
  mutually-referential wrappers avoid refcount cycles. `define_update` runs a
  `WeakenFunctionPtrs` mutator over new args/values to weaken self-calls
  (Function.cpp:833–846).
- **Tuples are parallel vectors, not a type.** A tuple-valued Func has N entries in
  `Definition::values`, `output_types`, `output_buffers`; a caller reading element *i*
  is a `Call` with `value_index = i`. `split_tuples` (late in lowering) renames them
  to `f.0`, `f.1`, ... buffers.
- **Freezing.** Defining `g` freezes every Function `g` calls
  (Function.cpp:281–300), so a producer can't be redefined after a consumer captured
  it.

### 2.2 Definition / DefinitionContents

One `Definition` per stage (Definition.h:38–132):

```cpp
struct DefinitionContents {
    bool is_init = true;
    Expr predicate;                  // RDom where() clauses, default const_true()
    std::vector<Expr> values, args;  // RHS tuple; LHS coordinates
    StageSchedule stage_schedule;    // per-stage loop structure (§4.2)
    std::vector<Specialization> specializations;
};
```

- For the **pure (init) definition**, `args` is exactly `[Var(a) for a in
  Function::args]`. For **updates**, `args` are arbitrary Exprs (`f(x+1)`,
  `f(r.x)`, ...).
- The RDom itself is *not* stored on the Definition. At definition time its
  `ReductionVariable`s (`{name, min, extent}`) are copied into
  `stage_schedule.rvars()` and its predicate into `predicate`
  (Definition.cpp:95–107). After that, the schedule is the authoritative record.
- **Specializations** are nested Definitions: `Specialization {Expr condition;
  Definition definition; string failure_message;}`. `add_specialization` deep-copies
  args/values/predicate *and the stage schedule* (Definition.cpp:203–217); subsequent
  directives on the returned `Stage` edit the copy. Lowering turns the list into a
  right-leaning if/else-if tree of alternative loop nests.

### 2.3 Defining functions: the purity checks

**`Function::define`** (pure, Function.cpp:547–663), for `f(x, y) = expr`:

1. Reject frozen/extern/undefined cases.
2. `CheckVars` (Function.cpp:202–278): every `Variable` in the values must be a
   pure arg, a `Parameter`, `Let`-bound, or an RVar — and for a pure definition, any
   RVar is an error. Recursive self-calls must use the pure vars in the same positions
   as the LHS. *Purity is structural, not effect-analysis.*
3. Freeze callees; CSE each value; tag `random()` calls.
4. Build `init_def` and the **default schedule**: one serial `PureVar` `Dim` per arg,
   in arg order (first arg innermost), plus the sentinel dim `__outermost`; one
   `StorageDim` per arg (Function.cpp:628–644).

**`Function::define_update`** (Function.cpp:679–896):

1. Requires an existing pure def; same dimensionality, tuple size, and per-element
   types.
2. LHS arg *i* is "pure" iff it is a naked `Variable` named exactly like pure arg *i*;
   anything else is an impure coordinate.
3. `CheckVars` additionally enforces **exactly one ReductionDomain** across args and
   values, and captures it.
4. Loop nest seeded as: RVar dims first (innermost), each classified
   `PureRVar`/`ImpureRVar` by `can_parallelize_rvar` (a race analysis:
   Function.cpp:851–865), then the pure args, then `__outermost`.

### 2.4 Var, RDom, FuncRef

- **Var** (Var.h) is just a name (with a cached Int(32) `Variable` Expr).
  `Var::outermost()` = `"__outermost"` is a scheduling sentinel (§4.4).
- **RDom** wraps a refcounted `ReductionDomain {vector<ReductionVariable>, predicate,
  frozen}` (Reduction.cpp:94–133); `where()` ANDs predicates. An `RVar` used as an
  Expr becomes `Variable::make(Int(32), name, reduction_domain)` — the `Variable`
  node's `reduction_domain` field is how `define_update` discovers which RDom an
  update touches.
- **FuncRef** is the "LHS or call?" object from `f(x, y)`. As an Expr it becomes
  `Call{CallType::Halide, name, args, FunctionPtr, value_index}`
  (Func.cpp:3390–3399). As an assignment target it routes to
  `define`/`define_update`. `operator+=` etc. auto-create a base case
  (`define_base_case`, Func.cpp:3246–3277). Implicit vars: `_` is expanded to
  `Var::implicit(0..)` to match dimensionality.

So the complete flow for `g(x) = f(x) + 1`: `f(x)` → `Call{Halide, "f",
[Variable("x")], func=f, value_index=0}`; `+1` wraps it in `Add`; assignment runs
`Function::define({"x"}, {Add(...)})`, freezing `f`.

### 2.5 Extern stages, Parameters, Buffers

- `define_extern` stores the extern symbol name + `ExternFuncArgument`s and
  synthesizes a fake init definition with `undef` values and `ForType::Extern` dims —
  placeholder loops so bounds inference has something to chew on (deleted later by
  `remove_extern_loops`). Bounds for extern stages use the two-phase *bounds query
  protocol* (call with null host pointers; the extern fills in what it needs).
- **Parameter** (Parameter.h) = runtime argument: scalar (type + min/max/estimate
  constraints) or buffer (per-dim `BufferConstraint {min, extent, stride, ...}`).
  Appears in the IR embedded in `Variable::param`, `Call::param`, `Load::param`,
  `Store::param`. A Func's own outputs are Parameters in `output_buffers`.
- **Buffer<>** = named concrete image; appears as `Call::image`/`Load::image` for
  compiled-in constants and JIT inputs.

---

## 3. The imperative IR: Expr/Stmt node catalog

### 3.1 Node infrastructure (Expr.h, IntrusivePtr.h, IRVisitor.h, IRMutator.h)

- **Refcounted, immutable nodes.** `IRNode {virtual accept; mutable RefCount;
  IRNodeType node_type}` (Expr.h:97–127). Halide builds without C++ RTTI; the
  `uint8_t` `node_type` tag is the substitute, and `IRHandle::as<T>()` is a tag
  compare + reinterpret_cast. `IntrusivePtr` is used (not `shared_ptr`) so a counted
  handle can be recovered from a raw `const IRNode*`.
- Node lists are generated from two X-macros (`HALIDE_FOR_EACH_IR_EXPR`,
  Expr.h:28–59; `HALIDE_FOR_EACH_IR_STMT`, Expr.h:62–79). The Expr list is in
  **canonical strength order** — the simplifier and `IRMatch.h` rely on it.
- **No hash-consing.** `make()` factories `new` a node each time; `Expr` equality is
  pointer equality (`same_as`); structural equality is `IREquality.h::equal()`.
  Because Exprs can still be DAGs (shared subtrees), `IRGraphVisitor`/`IRGraphMutator`
  memoize visits to avoid exponential blowup.
- **Visitor/mutator.** `IRVisitor` has one `visit(const T*)` per node (default:
  recurse). `IRMutator` reconstructs a node **only if a child changed**, preserving
  sharing. `VariadicVisitor` is a CRTP switch-on-tag dispatcher used by the simplifier
  for speed.
- **Type** wraps the runtime `halide_type_t` (code ∈ {Int, UInt, Float, BFloat,
  Handle}, bits, lanes) + a C++-type pointer for Handle mangling. Vector types are
  `lanes > 1` and are only created by lowering (vectorization), never by users.

Semantic ground rules (IR.h:39–76): signed ints ≥32 bits are "no-overflow" types the
simplifier treats as unbounded; narrower signed and all unsigned wrap; children of a
node have no sequence points and may be reordered/duplicated/eliminated; floats follow
fast-math.

### 3.2 Expr nodes (30)

| Node | Fields | Semantics |
|---|---|---|
| IntImm/UIntImm/FloatImm/StringImm | value | Scalar constants (int value normalized to bit width) |
| Cast | value | Conversion; float→int truncates; casts to wide signed assumed no-overflow |
| Reinterpret | value | Bit-cast, may change lanes if total bits preserved |
| Variable | name, Parameter param, Buffer<> image, ReductionDomain rdom | Named symbol; the three handles tie it to what it denotes |
| Add/Sub/Mul | a, b | Arithmetic |
| Div/Mod | a, b | **Euclidean** division/remainder; x/0 = 0, x%0 = 0 |
| Min/Max | a, b | |
| EQ/NE/LT/LE/GT/GE | a, b | Comparisons (UInt(1)×lanes); GT/GE normalized to LT/LE |
| And/Or/Not | a, b / a | Boolean |
| Select | cond, t, f | Ternary; may evaluate both sides; lane-wise |
| Load | name, predicate, index, image, param, ModulusRemainder alignment | 1-D typed load from untyped byte array; different names assumed non-aliasing. **Post-flattening only** |
| Ramp | base, stride, lanes | `[base, base+stride, ...]`; dense vector load = Load with stride-1 Ramp index |
| Broadcast | value, lanes | Splat |
| Call | name, args, CallType, FunctionPtr func, value_index, image, param | See below |
| Let | name, value, body | Expression-scoped binding |
| Shuffle | vectors, indices | Generalized lane permute (interleave/concat/slice classifiers + factories) |
| VectorReduce | value, op (Add/SaturatingAdd/Mul/Min/Max/And/Or) | Horizontal reduction of adjacent lane groups |

**`Call` is the load-bearing node.** `CallType` ∈:

- `Halide` — a call to another (or the same) Halide Function; `func` holds a
  possibly-weak `FunctionPtr`, `value_index` selects the tuple element. **This is the
  frontend's inter-Func edge** and the mid-level IR's symbolic multi-dim load.
- `Image` — load from a concrete input image (`image`) or ImageParam (`param`).
- `Extern` / `ExternCPlusPlus` — external C/C++ function, possibly side-effecting.
- `PureExtern` — reorderable/CSE-able external function (`sqrt`).
- `Intrinsic` / `PureIntrinsic` — compiler intrinsics. Halide has no dedicated node
  types for most ops; ~100 operations are intrinsics named by the `IntrinsicOp` enum
  (IR.h:607–779): shifts, saturating/widening/halving arithmetic,
  `likely`/`likely_if_innermost` (loop-partition hints), `if_then_else`, `mux`,
  `prefetch`, `promise_clamped`/`unsafe_promise_clamped`, `require`, `undef`,
  `unreachable`, `_halide_buffer_get_*`, strict-float variants, etc.

`Call(Halide)` and `Call(Image)` do not survive lowering — storage flattening
converts them to `Load`s.

### 3.3 Stmt nodes (17)

| Node | Fields | Semantics / lifetime |
|---|---|---|
| LetStmt | name, value, body | Statement-scoped binding |
| AssertStmt | condition, message | Abort pipeline with error call if false |
| ProducerConsumer | name, is_producer, body | Marker: where Func `name` is produced vs consumed. Survives to codegen as a no-op scope (used by profiling/tracing) |
| For | name, **min, max (inclusive!)**, ForType, DeviceAPI, body, Partition | Loop over `[min, max]`; `extent() = max-min+1` (IR.h:973–996 — note: this is a recent change from the historical min/extent pair). ForType ∈ Serial, Parallel, Vectorized, Unrolled, Extern, GPUBlock, GPUThread, GPULane |
| Acquire | semaphore, count, body | Semaphore wait (async runtime) |
| Store | name, predicate, value, index, param, alignment | 1-D predicated store; dual of Load. Post-flattening |
| **Provide** | name, values, args, predicate | Multi-dim symbolic store `f(args) = values`. **Mid-level only** |
| Allocate | name, type, MemoryType, extents, condition, new_expr, free_function, padding, body | Scoped scratch allocation |
| Free | name | Free the named allocation |
| **Realize** | name, types, MemoryType, Region bounds, condition, body | Multi-dim allocation for Func `name`. **Mid-level only** |
| Block | first, rest | Sequential composition (linked list) |
| Fork | first, rest | Parallel composition (async producers) |
| IfThenElse | condition, then, else? | Conditional |
| Evaluate | value | Evaluate for side effect — the only exactly-once evaluation point |
| **Prefetch** | name, types, bounds, PrefetchDirective, condition, body | Multi-dim prefetch marker. **Mid-level only** (→ `prefetch` intrinsic) |
| Atomic | producer_name, mutex_name, body | Atomicity w.r.t. enclosing parallel loops |
| **HoistedStorage** | name, body | Anchor for `hoist_storage`. **Mid-level only** |

**Mid-level-only nodes** (exist between `schedule_functions` and storage
flattening/cleanup): `Provide`, `Realize`, `Prefetch`, `HoistedStorage`, plus
`Call(Halide|Image)`. Codegen only ever sees Load/Store/Allocate/Free/For/LetStmt/
IfThenElse/Block/Fork/Acquire/Atomic/AssertStmt/Evaluate/ProducerConsumer(-as-marker).

---

## 4. The schedule as data

Every directive is *pure metadata mutation* — no IR is transformed at directive time.
Two objects per Function:

### 4.1 FuncSchedule — "where/how is this Func stored and realized" (Schedule.cpp:233–283)

```cpp
struct FuncScheduleContents {
    LoopLevel store_level, compute_level, hoist_storage_level; // all default inlined()
    std::vector<StorageDim> storage_dims;  // layout: order, alignment, bound, fold
    std::vector<Bound> bounds;             // bound()/align_bounds() assertions
    std::vector<Bound> estimates;          // autoscheduler hints
    std::map<std::string, FunctionPtr> wrappers;   // Func::in()
    MemoryType memory_type;                // store_in()
    bool memoized, async;  Expr ring_buffer, memoize_eviction_key;
};
```

Directive → field (all in Func.cpp): `compute_at` assigns `compute_level`
(compute_root = `compute_at(LoopLevel::root())`, compute_inline =
`compute_at(LoopLevel::inlined())`); `store_at`/`store_root` → `store_level`;
`hoist_storage`; `reorder_storage` permutes `storage_dims`; `align_storage`/
`bound_storage`/`fold_storage` set per-dim fields; `bound`/`bound_extent`/
`align_bounds` push `Bound{var, min, extent, modulus, remainder}` records;
`set_estimate`; `memoize`; `async`; `ring_buffer`; `store_in`.

**Default schedule = inlined**: `store_level = compute_level = hoist_storage_level =
LoopLevel::inlined()` at construction.

### 4.2 StageSchedule — "what does this stage's loop nest look like" (Schedule.cpp:297–336)

```cpp
struct StageScheduleContents {
    std::vector<ReductionVariable> rvars;   // copied from the RDom
    std::vector<Split> splits;              // ordered transformation log
    std::vector<Dim> dims;                  // loop list, INNERMOST FIRST, ends with __outermost
    std::vector<PrefetchDirective> prefetches;
    FuseLoopLevel fuse_level;               // compute_with: who I'm fused into
    std::vector<FusedPair> fused_pairs;     // derived: children fused into me
    bool touched, allow_race_conditions, atomic, override_atomic_associativity_test;
};
```

### 4.3 Split, Dim, LoopLevel

```cpp
struct Split {                       // Schedule.h:332–353
    std::string old_var, outer, inner;
    Expr factor;
    bool exact;                      // true for RVar splits: tail may not over-iterate
    TailStrategy tail;               // RoundUp, GuardWithIf, Predicate, PredicateLoads,
                                     // PredicateStores, ShiftInwards, ShiftInwardsAndBlend,
                                     // RoundUpAndBlend, Auto
    enum SplitType { SplitVar, RenameVar, FuseVars } split_type;
};
```

One record type encodes split (`old → outer*factor + inner`), rename, and fuse
(`outer,inner → old`), in a single ordered list so ordering between them is respected.
(Note: the historical `PurifyRVar` split type no longer exists in current main.)

```cpp
struct Dim {                         // Schedule.h:446–491
    std::string var;
    ForType for_type;                // Serial/Parallel/Vectorized/Unrolled/Extern/GPU*
    DeviceAPI device_api;
    DimType dim_type;                // PureVar | PureRVar | ImpureRVar
    Partition partition_policy;      // Auto | Never | Always
};
```

`DimType` encodes legality: `PureVar` (reorder freely, may over-compute), `PureRVar`
(reorder freely, exact domain), `ImpureRVar` (must run in order; parallelize only via
associativity proof + `atomic()`, or `allow_race_conditions()`).

```cpp
struct LoopLevelContents {           // Schedule.cpp:20–42
    std::string func_name;           // "" for inline/root
    int stage_index;                 // -1 = unspecified
    std::string var_name;            // "__root" = root(), "" = inlined()
    bool is_rvar, locked;
};
```

`LoopLevel` is a *mutable shared handle* until lowering starts:
`Function::lock_loop_levels()` freezes all of them and implements
"store_level, if left inlined, follows compute_level; hoist_storage_level follows
store_level" (Function.cpp:1164–1185) — why `compute_at` alone gives fused
storage+compute.

**compute_with**: `Stage::compute_with` records only a `FuseLoopLevel {LoopLevel,
map<string, LoopAlignStrategy>}` on the stage being moved. The parent-side
`FusedPair{func_1, stage_1, func_2, stage_2, var_name}` list is *derived* during
`realization_order()` by `populate_fused_pairs_list`.

### 4.4 How directives edit the state

Almost every `Func::` method forwards to `Stage` (the init definition). The important
ones:

- **`split(old, outer, inner, factor, tail)`** (Func.cpp:1076–1306): (1) finds the
  dim by *suffix match* (`var_name_match`: dim names accumulate qualified spellings
  like `x.xi`); (2) edits `dims` in place — duplicates the entry so `inner` is
  immediately inside `outer`, both inheriting for_type/dim_type; (3) resolves
  `TailStrategy::Auto` (RVar → GuardWithIf; update defs → RoundUp/GuardWithIf; pure
  defs → ShiftInwards, or RoundUp when a prior ShiftInwards split already covers the
  var); (4) appends the `Split` record. **No IR.**
- **`fuse`**: erases the outer dim, renames the inner to the fused name, merged
  DimType = more restrictive, appends a `FuseVars` Split.
- **`reorder`**: permutes `dims` only; reordering two ImpureRVars requires an
  associativity proof. `__outermost` must remain last.
- **`vectorize/unroll/parallel/serial(var)`**: sets `dims[i].for_type` only. The
  factor forms are literally split + mark (`vectorize(x, 8)` = `split(x, x, xi, 8);
  vectorize(xi)`).
- **`tile`** = two splits + one reorder. Nothing more.
- **`rfactor`** is the one directive that rewrites the *algorithm*: it projects the
  RDom into two, synthesizes an intermediate Func, and directly assigns
  `dims`/`rvars`/`splits` on both stages.
- **GPU**: `gpu_blocks/threads/lanes` just set for_type + device_api on dims; the
  canonical `.__thread_id_x` names are applied later by lowering's
  `canonicalize_gpu_vars`, keyed by nesting depth.

### 4.5 Worked example

```cpp
f(x, y) = x + y;
f.tile(x, y, xi, yi, 8, 8).vectorize(xi).parallel(y);
```

Final schedule state:

```
dims:   x.xi        Vectorized  PureVar     (innermost)
        y.yi        Serial      PureVar
        x.x         Serial      PureVar
        y.y         Parallel    PureVar
        __outermost Serial      PureVar
splits: SplitVar(x -> x.x * 8 + x.xi, ShiftInwards)
        SplitVar(y -> y.y * 8 + y.yi, ShiftInwards)
```

Lowering replays this into `parallel y.y { serial x.x { serial y.yi { vectorized
x.xi { ... } } } }`.

The sentinel `__outermost` dim (zero-extent anchor "outside all real loops") exists so
schedules can name that site (e.g. `gpu_single_thread`) and so rfactor has a stable
insertion point; its degenerate loops are stripped at the end of schedule_functions.

---

## 5. Initial lowering: schedule_functions + bounds inference

The front half of `lower_impl()` (Lower.cpp:137). Everything here operates on a
**deep copy** of the Function DAG (Lower.cpp:151) so user Funcs are never mutated.

### 5.1 Environment construction (before any Stmt exists)

1. **`build_environment`** (FindCalls.cpp:96): transitively collect every Function
   reachable from the outputs by walking `Call(Halide)` nodes, plus extern-def Func
   args and schedule wrappers.
2. **`lock_loop_levels`**, `lower_target_query_ops`, `strictify_float`.
3. **`wrap_func_calls`** (WrapCalls.cpp:72–177): implements `Func::in()` by
   substituting `FunctionPtr`s inside caller definitions — per-caller for custom
   wrappers, global otherwise, composing chained wrappers.
4. **`realization_order`** (RealizationOrder.cpp:295–421): returns (a) a flat
   topological order of Functions, (b) `fused_groups` — connected components of the
   compute_with adjacency, in order. compute_with pairs are validated (no data
   dependence between fused Funcs in either direction, no cycles); the DAG uses dummy
   per-group nodes so all inputs of a group precede the whole group; edge lists are
   sorted by a stable name+visitation key so the order is deterministic.
5. **`simplify_specializations`**.

### 5.2 schedule_functions: the driver (ScheduleFunctions.cpp:2565–2630)

The initial Stmt is a synthetic zero-trip loop named like `LoopLevel::root()` — so
`compute_root` is *just a special case of `compute_at`* (the root loop's name matches
root LoopLevels). Then, iterating **fused groups in reverse realization order**
(consumers first, so each producer is injected into the partially built consumer
nest):

- **`validate_schedule`**: runs `ComputeLegalSchedules` — an IRVisitor over the
  *current partial Stmt* that records the stack of enclosing For loops at every use of
  the Function and intersects them; the requested hoist/store/compute levels must
  appear in that common stack outside-in, with no parallel loop between store and
  compute levels. (On failure it prints the legal `compute_at` sites.)
- If the group is a single pure Func with `compute_level().is_inlined()` →
  **`inline_function`** (§5.6). Note inlining is decided *here*, before any loops for
  that Func exist.
- Otherwise → **`InjectFunctionRealization`** mutates the Stmt (§5.4).

Finally the dummy root loop is peeled off and degenerate `__outermost` loops removed.

### 5.3 One Definition → one loop nest

**`build_provide_loop_nest`** (ScheduleFunctions.cpp:470–545):

- The stage **prefix** is `"<func>.s<stage>."` (`f.s0.` pure, `f.s1.` first update);
  all schedule vars are qualified with it (`x` → `f.s0.x`).
- Seed statement: `Provide::make(f, values, site, const_true())` — for a pure def the
  site is the qualified args; for an update, whatever the LHS args are. Wrapped in
  `Atomic` if scheduled atomic.
- `build_loop_nest` produces the default nest; **specializations** then each
  recursively build their own complete nest from their own Definition, composed as a
  right-leaning `IfThenElse` chain with the default as the final else.

**`build_loop_nest`** (ScheduleFunctions.cpp:184–467), working inside-out from the
Provide:

1. **Apply splits** in schedule order via `apply_split` (ApplySplit.cpp:14–166), each
   returning actions applied to the statement: whole-body substitutions,
   Call-only/Provide-only substitutions, `Let` wrappers, `if` predicates, and
   Provide-value blends. Tail strategies:
   - *RoundUp*: nothing extra — the outer bound `(extent+factor-1)/factor` overruns
     and the producer's realization is enlarged to match.
   - *GuardWithIf / Predicate*: substitute `old_var` with a `.guarded` let defined as
     `promise_clamped(old_var, old_min, old_max)` (so bounds inference knows the true
     range despite the overrun), and wrap the body in `if (likely(old_var <=
     old_max))`.
   - *PredicateLoads/PredicateStores*: same, but the condition goes into
     `if_then_else` around Calls / ANDed into the Provide predicate.
   - *ShiftInwards*: `base = min(likely_if_innermost(base), old_max + 1 - factor)` —
     the last outer iteration slides backward; `likely_if_innermost` later triggers
     loop partitioning into steady state + tail.
   - *Blend variants*: additionally mask re-stored values with
     `select(cond, new, f(args))`.
   - `compute_loop_bounds_after_split` emits the loop-bound lets: split loops are
     zero-based (`inner ∈ [0, factor-1]`, `outer ∈ [0, ceil(extent/factor)-1]`) and
     rebased onto real coordinates by a `.base` let.
2. **For containers** are created from the `dims` list (outermost-first), interleaved
   with the lets/ifs the splits produced.
3. **compute_with guards**: dims at/inside the fusion point get `likely(var >=
   loop_min) && likely(var <= loop_max)` guards, because fused siblings iterate the
   *union* of bounds.
4. **RDom `where()` predicates** become `if (likely(...))` containers.
5. **Container sorting**: three insertion-sort passes push pure lets and guards as far
   outward as dependences allow. This is *not* generic LICM — it exists solely so
   bounds inference's `BoxesTouched` sees the `likely` conditions at the outermost
   scope and computes tight bounds. (§8 flags this as a design smell a clean redesign
   should fix structurally.)
6. **Rewrap**: each `For` gets bounds `Variable(prefix + dim + ".loop_min" /
   ".loop_max")`; then in reverse split order the split-bound lets are emitted;
   `__outermost` gets `loop_min = loop_max = 0`; finally for each pure arg `v`:
   `let f.s0.v.loop_min = f.s0.v.min; let f.s0.v.loop_max = f.s0.v.max`, and RVar
   loops likewise reference `f.s1.r.min/.max`.

**The `.min`/`.max` symbols are left dangling on purpose.** They are the contract that
bounds inference will later fulfill with LetStmts. This string-named symbolic contract
is the composition mechanism of the whole system.

### 5.4 Injection: matching LoopLevels against the growing Stmt

`InjectFunctionRealization::visit(const For*)` (ScheduleFunctions.cpp:1180–1870):

1. Digs through prefetch placeholders and *pure* lets/ifs at the top of the loop body
   (never past a side-effecting let), recurses into the body first (innermost match
   wins).
2. If `compute_level.match(for_loop->name)` (LoopLevel matching is against qualified
   loop names like `g.s0.x`): body → `build_pipeline_group(body)`:
   - Topologically sorts the group's *stages* (compute_with constraints), builds each
     stage's loop nest via `build_provide_loop_nest`, and injects it: `Block(producer
     so far, new nest)` for unfused stages, or — for compute_with — grafts the child
     nest as a Block *inside* the parent's For loop matching the fuse LoopLevel
     (`InjectStmt`), then rewrites bounds: each child fused loop becomes an
     extent-1 loop whose min is the parent's loop var, and the parent loop's bounds
     become the **union** over all fused children
     (`replace_parent_bound_with_union_bound`).
   - Wraps each member in `ProducerConsumer::make_produce`, and the original body in
     `ProducerConsumer::make_consume` (skipped for outputs); result =
     `Block(produce..., consume)`.
3. On the way back out, a `store_level` match wraps the body in
   **`Realize(f, types, [f.<arg>.min_realized / f.<arg>.extent_realized ...])`**
   (skipped for outputs — they live in caller buffers). This is how
   `store_at` outside `compute_at` works: ProducerConsumer at the compute loop,
   Realize further out. A distinct `hoist_storage_level` match inserts a
   `HoistedStorage` marker.
4. Special cases: inlined extern Funcs inside vectorized loops get realized around the
   vector loop; multi-stage Funcs scheduled "inline" are realized immediately around
   each consuming Provide (`inline_to_provide`) — inline is lowered as "compute at
   innermost".

### 5.5 Naming conventions (the de-facto ABI of mid-level IR)

- Loop vars: `<func>.s<stage>.<var>` (`g.s0.x`, `blur.s1.r$x`), split children
  `g.s0.x.xi`, fused loops `g.s0.fused.x`, sentinel `g.s0.__outermost`.
- Loop bounds: `<loopvar>.loop_min/.loop_max` lets defined in terms of stage-bounds
  symbols `<func>.s<stage>.<var>.min/.max` — free variables until bounds inference.
  Splits add `.base` and `.guarded`; explicit bounds keep `.min_unbounded/.max_unbounded`.
- Realization extents: `<func>.<arg>.min_realized/.extent_realized` (per-Func, no
  stage) — free until `allocation_bounds_inference`.
- Buffer parameters: `<name>.min.<d>`, `.extent.<d>`, `.stride.<d>`, `<name>.buffer`.

### 5.6 Inlining (Inline.cpp)

For a pure Func scheduled inline, `inline_function` replaces every `Call` to `f` with
`f`'s value Expr, binding each call argument to `f.<arg>` via `substitute` (trivial
args) or a `Let` (compound args, preserving work sharing), with per-Provide CSE to
bound expression growth. `validate_schedule_inlined_function` errors on
parallel/vectorized dims, store levels, etc. After inlining the Func simply vanishes —
no Realize, no loops — which is why bounds inference must *itself* re-inline such
Funcs into consumer expressions (it re-runs an internal `Inliner`).

### 5.7 Bounds inference (BoundsInference.cpp, Bounds.cpp)

Substrate (Bounds.cpp): `bounds_of_expr_in_scope` — symbolic interval arithmetic over
Exprs given `Interval` bounds for free variables (possibly ±∞), with Halide Calls
bounded by precomputed `FuncValueBounds`. `Box` = vector of Intervals + `used`
condition; `boxes_required` / `boxes_provided` / `boxes_touched` compute, per Func
name, the region covered by all Calls / Provides / both within a Stmt — respecting For
scopes and using `likely`-tagged `if` conditions to trim domains (which is why
build_loop_nest hoisted them).

The pass (`bounds_inference`, BoundsInference.cpp:1312):

- **Static phase**: build a `Stage` record per (Function, stage) in realization order.
  Inlined Funcs get no stages and are substituted into consumers' expressions. For
  each consumer stage, `boxes_required` of its exprs (in a scope mapping its own vars
  to `[f.sN.x.min, f.sN.x.max]` symbols) is recorded on each producer as
  `producer.bounds[{consumer, stage}]`. Output stages seed the system with boxes from
  their output-buffer parameters (`g.min.0`, `g.extent.0`).
- **Mutation phase** (`visit(const For*)`): the pass walks the loop nest; on the way
  out of each loop body it inserts LetStmts defining the `.min`/`.max` symbols needed
  inside:
  - For each stage produced inside this loop, merge the Boxes from every *relevant*
    consumer (the currently-producing stage, anything produced inside, fused
    siblings) via dimension-wise interval union — **this is where multiple consumers
    merge**.
  - Apply explicit `bound()`/`align_bounds()` (with `.min_unbounded` kept for the
    later too-small check).
  - Emit `let f.s0.x.max = ...; let f.s0.x.min = ...`, plus RVar bounds
    `let f.s1.r.min = rv.min; let f.s1.r.max = rv.min + rv.extent - 1` (how RDom
    bounds enter the IR). Extern stages instead run the bounds-query protocol.
  - If this loop belongs to a producing stage, also re-bind the *production* bounds
    from `boxes_provided` one level in — deliberately **shadowing** the same names:
    at each depth, `g.s0.x.min/.max` mean "the region of g handled by the current
    iterations of all enclosing loops". This shadowing is why no whole-Stmt
    simplification is legal until `uniquify_variable_names` runs (Lower.cpp:207–209).

### 5.8 Worked micro-example

`f(x) = 2*x; g(x) = f(x) + f(x+1); f.compute_at(g, x);` — after schedule_functions
and bounds inference (simplified):

```
let g.s0.x.min = g.min.0                      // from output buffer params
let g.s0.x.max = g.min.0 + g.extent.0 - 1
produce g {
  for (g.s0.x, g.s0.x.loop_min, g.s0.x.loop_max) {
    let g.s0.x.min = g.s0.x                   // production bounds: SHADOW outer defs
    let g.s0.x.max = g.s0.x.min               // single point: this iteration
    let f.s0.x.max = g.s0.x.max + 1           // region of f required inside this loop
    let f.s0.x.min = g.s0.x.min
    realize f([f.x.min_realized, f.x.extent_realized]) {
      produce f {
        for (f.s0.x, f.s0.x.loop_min, f.s0.x.loop_max) {   // 2 iterations
          f(f.s0.x) = 2*f.s0.x                             // Provide
        }
      }
      consume f {
        g(g.s0.x) = f(g.s0.x) + f(1 + g.s0.x)              // Provide + Calls
      }
    }
  }
}
```

The classic compute_at redundant-compute/locality trade is directly visible.
`min_realized`/`extent_realized` are resolved later by allocation bounds inference
(`boxes_touched` inside the Realize).

### 5.9 Immediately downstream: sliding window, storage folding

- **`sliding_window`** (SlidingWindow.cpp): for `store_at` outside `compute_at`,
  when the required region marches monotonically with the intervening serial loop,
  rewrite the producer's computed region so each iteration computes only the *new*
  values (`new_min = prev_max + 1`, warm-up clamped). Recompute shrinks; storage
  stays full-size.
- **`storage_folding`** (StorageFolding.cpp): the storage-side complement — if the
  live window along a dimension fits in `F`, rewrite all accesses modulo `F` and
  shrink the Realize extent, making a circular buffer (e.g. two scanlines). Emits
  fold-factor-too-small assertions for dynamic cases; async pipelines get semaphore
  releases so producers don't overwrite unconsumed entries.

Both passes work by *rewriting the bounds of already-placed fragments* — worth
noticing for §8.

---

## 6. The rest of lowering: pass pipeline to codegen

`lower_impl` (Lower.cpp:137–606) threads one Stmt through the passes below (exact
order; grouped by phase). The load-bearing ones get detail after the list.

**Phase A — instrumentation and early semantic injection** (Provide/Call/Realize IR):
1. `inject_memoization` — cache lookup/store around memoized realizations.
2. `inject_tracing` — `halide_trace` calls at loads/stores/realizations.
3. `add_parameter_checks` — asserts on scalar params + "constrained" substitutes.
4. `clamp_unsafe_accesses` — clamp Func-indexes-Func patterns where allocation
   bounds may exceed compute bounds.

**Phase B — making bounds concrete:**
5. `bounds_inference` (§5.7).
6. `add_split_factor_checks` — parameter split factors must be > 0.
7. `remove_extern_loops` — delete extern stages' placeholder loops.
8. `sliding_window` (§5.9).
9. `uniquify_variable_names` — after this, syntactic name equality is semantic.
10. `simplify` (first full run; rerun after most structural passes below).
11. `simplify_correlated_differences` — cancel correlated let differences that naive
    interval arithmetic would blow up (issue #3697).
12. `allocation_bounds_inference` — per Realize, `boxes_touched` over its body defines
    `f.<arg>.min_realized/.max_realized/.extent_realized` lets outside the Realize;
    `bound()` overrides with too-small assertions; unbounded access is a user error.
13. `add_image_checks` — required-region lets per input/output buffer, buffer
    type/dims/OOB/alignment asserts, constrained-variable substitution (so declared
    strides fold into address math), and the bounds-query path (null host → fill
    buffer shapes instead of running).
14. `remove_undef` — delete Provides whose value is `undef`.
15. `storage_folding` (§5.9).
16. `debug_to_file`.
17. `inject_prefetch` — fill placeholder Prefetch regions.
18. `lower_safe_promises` — strip `promise_clamped` (its job — tightening
    boxes_touched — is done).

**Phase C — eliminating mid-level nodes:**
19. `skip_stages` — guard productions that are conditionally never read.
20. `fork_async_producers` — `async()` producers become `Fork` branches synchronized
    with `Acquire`/semaphore-release pairs; ring buffers add slots.
21. `split_tuples` — tuple Realize/Provide/Call → per-component `f.0`, `f.1`, ...
22. `canonicalize_gpu_vars` — canonical `.__block_id_x`/`.__thread_id_x` names.
23. `bound_small_allocations` (+ another `simplify_correlated_differences`) —
    constant-bound small allocations (enables stack promotion; required in GPU
    kernels).
24. **`storage_flattening`** — the phase transition (detail below).
25. `add_atomic_mutex` — mutex buffers for non-hardware-atomizable Atomic nodes.
26. `unpack_buffers` — every buffer symbol's `host`/`min.i`/`extent.i`/`stride.i` and
    dirty bits become lets over `_halide_buffer_get_*` calls on the single
    `name.buffer` handle. After this, the only free symbols are scalar params and
    `.buffer` handles — exactly a LoweredFunc's argument list.
27. `rewrite_memoized_allocations`.

**Phase D — device data movement** (if GPU-ish target): 28. `select_gpu_api`;
29. `inject_host_dev_buffer_copies` (dirty-bit tracking, `halide_copy_to_device/host`,
`halide_device_malloc`); 30. `select_gpu_api` again.

**Phase E — loop-level restructuring:**
31. `simplify` + `unify_duplicate_lets`.
32. `reduce_prefetch_dimension`.
33. `simplify_correlated_differences`.
34. `bound_constant_extent_loops` — vectorized/unrolled loops must get constant
    extents (pad + guard if only a constant bound exists).
35. `unroll_loops` — literal body duplication (Block of substituted copies).
36. `vectorize_loops` + `simplify` (detail below).
37. `fuse_gpu_thread_loops` — normalize thread loops per block, insert barriers, merge
    shared allocations.
38. `rewrite_interleavings` — `select(x%2==0, a, b)` store patterns → shuffles + dense
    stores.
39. `partition_loops` + `simplify` (detail below).
40. `stage_strided_loads` — strided vector loads → wider dense loads + shuffles when
    provably safe.

**Phase F — final cleanup and canonicalization:**
41. `trim_no_ops`; 42. `rebase_loops_to_zero`; 43. `hoist_loop_invariant_if_statements`;
44. `inject_early_frees`; 45. `fuzz_float_stores` (testing feature);
46. `simplify_correlated_differences`; 47. `bound_small_allocations` again;
48. `inject_profiling`; 49. `lower_warp_shuffles` (CUDA);
50. `common_subexpression_elimination` (once, late — earlier passes prefer expanded
    exprs); 51. `lower_unsafe_promises` (assert in Debug, strip in release);
52. `extract_tile_operations` (AMX; the representative target-legalization slot);
53. `flatten_nested_ramps`; 54. `remove_dead_allocations` + `simplify` + LICM
    (`hoist_loop_invariant_values` — matters for GPU kernels where LLVM won't);
55. `find_intrinsics` — pattern-match `widening_add`/`rounding_shift_right`/... —
    deliberately *after* the last simplify, which would undo these forms;
56. `hoist_prefetches`; 57. `strip_asserts` (NoAsserts); 58. user's custom lowering
    passes. The Stmt is snapshotted as the module's "conceptual stmt" (what
    `.stmt`/`.stmt_html` show).

**Phase G — offload splitting and outlining (Stmt → multiple LoweredFuncs):**
59. `inject_hexagon_rpc`; 60. `inject_gpu_offload` — GPU loop nests are compiled *now*
    (inside lowering) by a `CodeGen_GPU_Dev` into device modules (PTX/SPIR-V/...)
    embedded as buffers; host side becomes `halide_<api>_run(...)` calls;
61. `infer_arguments` — scan for referenced Parameters/Buffers to build the argument
    list; 62. `lower_parallel_tasks` — **where `ForType::Parallel` dies** (detail
    below).

Finally: output-buffer Parameters become arguments, referenced-but-unlisted Buffers
are embedded, weak Function refs strengthened, and the Stmt becomes
`LoweredFunc(name, args, body, linkage)` in the `Module`.

### 6.1 storage_flattening (StorageFlattening.cpp)

Four sub-passes: `zero_gpu_loop_mins`, `FlattenDimensions`, `HoistStorage`,
`PromoteToMemoryType`.

- **Realize → Allocate**: match the Function's `storage_dims` against its args to get
  the storage permutation; apply `bound_storage` (with assert) and `align_storage`
  (round allocation extents up); mint `f.min.i / f.extent.i / f.stride.i` symbols in
  storage order; build a `_halide_buffer_init` struct bound as `let f.buffer` (so
  internal allocations can be passed to extern stages/device copies); emit
  `Allocate(f, type, extents, body)`; define strides in storage order
  (`stride[inner]=1`, `stride[j] = stride[prev]*allocation_extent[prev]`) — **this is
  where reorder_storage/align_storage actually change layout** — then min/extent lets.
- **Flat index** (`flatten_args`): internal allocations use
  `(x - f.min.0)*f.stride.0 + (y - f.min.1)*f.stride.1` (terms cancel after
  simplification); external buffers use `x*stride0 + y*stride1 - (min0*stride0 +
  min1*stride1)` (the base term is loop-invariant and hoists). Constant coordinate
  offsets are peeled so stencil taps share a base address. `LargeBuffers` → int64
  index math.
- **Provide → Store**, attaching the output-buffer Parameter when writing an output;
  **Call(Halide|Image) → Load**, attaching Buffer/Parameter. (GPU texture memory
  becomes `image_load`/`image_store` intrinsics instead.)
- Input/output buffers get no Allocate and no local shape lets — their
  `min/stride/extent` symbols stay free until `unpack_buffers` defines them from the
  `halide_buffer_t`.
- **HoistStorage** deletes Allocates at their original site, bounds their extents over
  intervening loop ranges, and re-creates one Allocate at the `HoistedStorage` marker.

### 6.2 Vectorize / unroll / partition

- **`unroll_loops`**: for `ForType::Unrolled` (constant extent guaranteed by pass 34),
  emit `extent` substituted copies of the body as a Block; re-uniquify names after.
- **`vectorize_loops`** (`VectorSubs`): the vectorized loop var becomes
  `Ramp(min, 1, lanes)` (nested vectorization → broadcasts of ramps / ramps of
  broadcasts to the combined lane count). Mutation is type-driven widening: binary
  ops broadcast the narrower side; Lets get `.widened` versions; Load/Store widen
  index+value+predicate (dense index = Ramp → dense load; anything else =
  gather/scatter for codegen). Vector conditions: first try pushing the condition
  into Load/Store `predicate` fields (`PredicateLoadStore`); if the condition carries
  `likely` (partitioning material), emit `if (all_true_of_lanes) vectorized else
  (predicated | scalarized)`; last resort `scalarize` (re-wrap the body in a serial
  loop over lanes). Allocations inside vector loops get extents × lanes.
- **`partition_loops`**: find `likely`-tagged conditions in the body, solve each for
  the loop var, intersect → the steady-state interval where all likely branches hold;
  emit prologue [min, steady) with the original body, steady state with tagged exprs
  replaced by their likely values (no clamps/selects → dense vector code), epilogue
  (steady, max]. Best-effort and semantics-preserving; per-loop `Partition` policy
  controls it. This is how `ShiftInwards` splits and `BoundaryConditions::*` become
  zero-overhead in the steady state.

### 6.3 Parallelism and async

`ForType::Parallel` is a plain attribute all the way through lowering; it is
eliminated by **`lower_parallel_tasks`** (LowerParallelTasks.cpp, pass 62 — a lowering
pass now, no longer codegen): compute a `Closure` (every referenced var/buffer),
pack it into a struct, outline the body into a new internal `LoweredFunc` with a
`halide_task_t`/`halide_loop_task_t` signature, and replace the loop with
`halide_do_par_for(fn, min, extent, closure)` (or `halide_do_parallel_tasks` with a
semaphore-acquire array for Fork/Acquire task graphs from `async()`).
`CodeGen_LLVM::visit(For)` asserts it never sees a Parallel loop.

### 6.4 End state before codegen

Final Stmt node inventory: serial `For` (rebased to 0), `LetStmt` everywhere
(buffer field extraction, bounds, CSE), `IfThenElse` (asserts' guards, skip-stages,
partition remnants, bounds-query branch), `AssertStmt` → `halide_error_*`,
flat possibly-vector `Load`/`Store` (Ramp/Broadcast indices, predicates,
ModulusRemainder alignment), `Allocate`/`Free` for internals, `ProducerConsumer` as
inert markers, `Call` to extern runtime functions and pure intrinsics, `Atomic` only
where real. `Realize`/`Provide`/`Call(Halide)`/`Prefetch`-node/`Fork`/`Acquire` are
gone — their presence after lowering is a compiler bug.

A **`Module`** (Module.h:144) = target + `LoweredFunc`s + embedded Buffers (weights,
device blobs) + submodules + the conceptual Stmt. A **`LoweredFunc`** = {name,
`LoweredArgument`s (Argument + alignment), body Stmt, linkage, mangling}. Buffer
arguments arrive as `halide_buffer_t*` bound to `name.buffer`; the body unpacks
via `_halide_buffer_get_*` lets and validates via the image-check asserts.
`CodeGen_LLVM::compile_func` then just walks the Stmt — everything semantically
interesting was decided in lowering.

---

## 7. Blueprint: "Halide lite"

A standalone recreation that stays close in design and capability, targeted at
research. What follows is a distillation of the minimum machinery that reproduces the
essential Halide behavior, with the cruft named explicitly.

### 7.1 Core data structures (~1–2 kLoC)

1. **Type**: {Int/UInt/Float/Handle, bits, lanes}.
2. **Expr nodes** (immutable, refcounted, type-tagged; `as<T>` by tag): immediates,
   Variable, Cast, Add/Sub/Mul/Div/Mod (Euclidean!), Min/Max, comparisons, And/Or/Not,
   Select, Let, Call, Ramp, Broadcast, Load. Keep Halide's Call design: one node with
   a CallType enum covering {Halide, Image, Extern, Intrinsic} — it is what lets the
   same Expr type span all levels.
3. **Stmt nodes**: LetStmt, AssertStmt, For (pick min/extent *or* min/max and be
   consistent; Halide recently moved to inclusive min/max), Block, IfThenElse, Store,
   Provide, Allocate, Free, Realize, ProducerConsumer, Evaluate.
4. **Visitor + Mutator** with rebuild-only-on-change. Generate from an X-macro or
   equivalent; this is boilerplate you want exactly once.
5. **Function** = {name, args, init Definition, update Definitions, FuncSchedule};
   **Definition** = {args, values, predicate, StageSchedule}. Enforce the two purity
   rules (§2.3): pure-def RHS vars ⊆ {args, params}; update pure LHS positions match
   by name, exactly one RDom.
6. **Schedule**: `Split {old, outer, inner, factor, tail, kind}` ordered log; `Dim
   {var, for_type, dim_type}` list, innermost-first, with the `__outermost` sentinel
   (it genuinely simplifies compute_at-at-outermost and is cheap); `LoopLevel {func,
   stage, var} | root | inlined`; FuncSchedule {compute_level, store_level,
   storage_dims, bounds}. Directives are metadata edits exactly as in §4.4 — `tile` =
   2 splits + reorder, `vectorize(x, n)` = split + mark.

Two Halide design decisions worth *changing* in a clean recreation:

- **Strings as the composition mechanism.** Halide's suffix-matching of dim names
  (`x` matches `x.xi`... no, query `xi` matches dim `x.xi`) and the
  `f.s0.x.loop_min` naming ABI work, but they are the single largest source of
  fragility. Use interned structured symbols ({func, stage, var, role}) with a
  printable form.
- **Bounds symbols as dangling free variables + shadowing redefinition.** Works, but
  forces the "no simplification until uniquify" rule and makes the IR unreadable
  mid-flight. §8's fragment parameters are the cleaner alternative; even without the
  full proposal, making the bounds contract a first-class map (stage → required Box
  expression) rather than name conventions costs little.

### 7.2 Lowering skeleton (~10 passes)

1. **Environment + realization order**: walk Call(Halide) edges; topological sort.
   (Skip wrappers, fused groups.)
2. **Inline pure funcs scheduled inline** (substitute value into Call sites, Let-bind
   compound args).
3. **schedule_functions**: reverse realization order; per stage,
   `build_provide_loop_nest` = Provide seed → apply splits (RoundUp + GuardWithIf tail
   strategies only, with the promise_clamped/`likely` trick if you implement
   partitioning; otherwise plain `if`) → wrap Fors from dims (bounds = symbolic) →
   emit split-bound lets and `.loop_min = .min` lets. Injection: walk the consumer
   Stmt; at compute-level match wrap body in Block(produce nest, consume body); at
   store-level match wrap in Realize with symbolic extents.
4. **bounds_inference**: interval arithmetic (`bounds_of_expr_in_scope`) +
   `boxes_required/provided`; walk the nest, emit `.min/.max` lets per loop depth
   with the shadowing semantics (or fragment parameters). Union over consumers.
5. **allocation bounds**: `boxes_touched` per Realize → concrete Realize extents.
6. **uniquify + simplify.** Budget real effort for the simplifier: Halide's is
   enormous (Simplify_*.cpp) because *every* pass leans on it; a lite version needs
   at least constant folding, let substitution/dead-let elimination, algebraic
   min/max/div/mod rules, and bounds-aware branch pruning. This is the second-largest
   component after the frontend and the one that most determines output quality.
7. **storage_flattening**: Realize→Allocate + stride lets, Provide→Store,
   Call(Halide/Image)→Load with the two indexing strategies of §6.1.
8. **vectorize/unroll** (optional but high-value): VectorSubs-style widening; unroll
   by substitution. Skip predication/scalarization initially — require clean divides
   via RoundUp/GuardWithIf.
9. **Output checks**: minimal image checks (dims/type asserts, required-region ≤
   buffer bounds) or simply trust inputs in a research setting.
10. **Codegen**: easiest credible target is C source (Halide's own CodeGen_C is a
    direct Stmt walk); LLVM is a direct translation too since the Stmt is that low
    level.

### 7.3 What to cut (and what each cut costs)

| Cut | Cost |
|---|---|
| Specializations | lose per-condition schedule variants (autoschedulers use them; users rarely start there) |
| compute_with | lose horizontal loop fusion; large simplification of schedule_functions (§5.4's bound-union machinery disappears) |
| async/Fork/Acquire/ring_buffer | lose pipeline parallelism; ProducerConsumer stays a pure marker |
| Tuples | little; or keep — parallel-vectors design is cheap |
| rfactor / associativity prover | lose parallel reductions (big feature, big machinery) |
| Extern stages + bounds queries | lose FFT/library interop |
| Sliding window + storage folding | lose the line-buffering pattern; consider keeping — both are compact, high-payoff passes |
| GPU, Hexagon, memoization, tracing, profiling | orthogonal features |
| Tail strategies beyond RoundUp/GuardWithIf | lose blend/predicate niches, keep the essential semantics |
| Loop partitioning + `likely` machinery | boundary conditions cost a branch per pixel until you add it |

Keep, non-negotiably: the two-layer IR with a shared Expr type; schedule-as-data with
the ordered split log + dims list; the Provide/Realize/Call(Halide) mid-level;
symbolic-then-inferred bounds; interval arithmetic; storage flattening as a distinct
phase; the Euclidean div/mod semantics (interval arithmetic depends on it).

Pitfalls observed in the real codebase worth pre-empting: (a) the "no simplify before
uniquify" trap; (b) interval arithmetic must handle ±∞ and correlated differences or
allocation bounds explode; (c) suffix name matching bites the moment two vars share a
suffix; (d) `For` min/max-vs-extent off-by-ones; (e) RVar splits must not over-iterate
(exactness), which is why `exact` exists on Split.

---

## 8. Toward a reified mid-level IR: making the big step incremental

### 8.1 What is entangled today

`schedule_functions` is one pass that does six jobs in a single traversal:

1. **Per-stage loop synthesis** (`build_provide_loop_nest`) — *already independent per
   stage*: it consumes only the Definition + StageSchedule and produces a
   self-contained nest with a symbolic-bounds interface.
2. **Specialization trees** — per-stage too (recursive nest construction + if-chain).
3. **compute_with fusion** — statement grafting into a sibling's nest plus bound-union
   rewriting; entangled with (4) because fused groups inject together.
4. **Consumer-nest injection** — `InjectFunctionRealization` walks the *partially
   built global Stmt* to find LoopLevel matches; legality checking
   (`ComputeLegalSchedules`) also reads the global Stmt.
5. **Inlining decisions** — routed *before* loop synthesis to `Inline.cpp`, operating
   on the functional layer; an inlined Func never gets loops. Bounds inference must
   then separately re-implement inlining internally for its analysis.
6. **Output/legality validation** against the whole pipeline.

The composition mechanism binding these together is the **string-named symbolic
bounds contract** (§5.5): each nest leaves `f.sN.v.min/.max` free; injection places
nests; a *global* bounds-inference pass fulfills every contract level-by-level with
shadowing lets. Semantically, each stage's loop nest is already a **function from a
requested region (Box) to a Stmt** — but that function exists only implicitly, in
the naming convention, and is only ever applied once, by one global pass. There is no
point in the pipeline where "the set of per-Func loop nests with explicit call edges"
is a first-class, manipulable value.

Two further observations sharpen the case:

- The container-sorting in `build_loop_nest` (§5.3 step 5) exists *only* so a later
  global analysis (BoxesTouched) can see `likely` guards at outer scopes. That's a
  pass communicating with another pass through incidental statement placement — a
  clear sign the interface wants to be structural.
- `sliding_window` and `storage_folding` are *bounds rewrites of already-placed
  fragments* — they edit exactly the quantities (per-iteration produced/required
  regions) that a reified fragment interface would expose as parameters.

### 8.2 The proposal, concretely

Reify the mid-level as a value: a **pipeline of loop-nest fragments with explicit
call edges and explicit region parameters**.

```
MidPipeline {
  fragments: map<StageId, Fragment>
  order:     realization order / dependence DAG
  placement: map<FuncId, {compute: Site, store: Site, hoist: Site}>   // from schedule
}

Fragment {                        // one per (Func, stage) — today's build_provide_loop_nest output
  id:      StageId                // {func, stage}
  region:  list<RegionParam>      // REIFIED: today's dangling f.sN.v.min/.max, now formal params
  body:    Stmt                   //   loop nest; For bounds reference region params;
                                  //   reads are Call(Halide); writes are Provide
  requires: map<StageId, BoxExpr> // boxes_required of body in terms of region params
                                  //   (computable per-fragment, cacheable)
}

Site = Root | Inlined | At(StageId, var)   // reified LoopLevel; loops carry stable ids,
                                            // so matching is structural, not string suffix
```

Lowering then becomes a sequence of small, independently testable rewrites, each of
which today is a facet of the monolith:

1. **`lower_stage(func, stage) → Fragment`** — pure per-stage synthesis. Exists today
   as `build_provide_loop_nest`; the only change is emitting region params instead of
   dangling names. Every Func gets loops — including ones that will later be inlined.
2. **`graft(pipeline, producer, site)`** — replace the site anchor with
   `Block(produce(producer.body), consume(original))`, and place `Realize` at the
   store site. This is today's `InjectFunctionRealization` + `inject_stmt`, but as an
   explicit combinator on the reified value. compute_with becomes a variant
   combinator: `graft_fused(parent, child, depth)` with the bound-union rule applied
   locally.
3. **`bind_regions(pipeline)`** — compositional bounds inference: at each graft
   point, the consumer fragment's `requires[producer]` (a Box expression over the
   consumer's own region params and loop vars at that depth) *is* the argument to the
   producer fragment's region parameters. Multiple consumers = interval union of
   their arguments. Today's global shadowing-lets pass becomes a fold over the graft
   tree; today's `FuncValueBounds` and RDom bounds slot in unchanged. (You can keep a
   single global pass initially — the point is the *contract* is explicit, so the
   pass is a checker/instantiator, not the sole owner of the semantics.)
4. **`inline(pipeline, call_site | func)`** — now *optional and late*: since reads
   are explicit `Call(Halide)` nodes into a still-standing producer fragment,
   inlining is a mid-level rewrite (substitute the producer's value expression, or —
   new capability — merge the producer's *loop* into the consumer at matching depth),
   instead of a frontend-only Expr substitution that must be decided before any loops
   exist. This directly answers the "first create loops for each Func/stage
   separately, with explicit calls, and only then optionally inline" goal: step 1
   always creates the loops; inlining folds a fragment away afterwards.
5. **`slide/fold/hoist(pipeline, func)`** — sliding window, storage folding, and
   storage hoisting become fragment-local rewrites of region arguments and Realize
   extents rather than pattern-matching passes over a global Stmt.

Storage flattening and everything after it are unchanged — they already consume
exactly this level, they just currently receive it fused into one Stmt. `flatten` is
the eliminator that folds the MidPipeline into today's post-bounds Stmt.

### 8.3 What you gain

- **Incrementality**: change one Func's schedule → re-run `lower_stage` for its
  stages and re-graft; other fragments (and their cached `requires` boxes) are
  untouched. Today any schedule change re-runs the entire monolith.
- **Testability**: per-stage synthesis, grafting, bounds binding, and inlining each
  get unit tests with small inputs. Today the only observable output is the whole
  pipeline's Stmt.
- **Autoscheduler/cost-model access**: the fragment set with explicit `requires`
  boxes is precisely the structure Halide's autoschedulers rebuild for themselves
  from the functional layer (e.g. the featurization loop nests in
  `src/autoschedulers/adams2019`); reifying it removes a whole shadow
  implementation.
- **New schedule semantics become combinators**, not monolith surgery: alternative
  fusion strategies, partial inlining (inline into one consumer, realize for
  another — today only expressible via `Func::in()` wrappers, which are a frontend
  workaround for exactly this gap), recompute-vs-store decisions per consumer.
- **Debuggability**: `.stmt`-style dumps exist *between* every micro-step.

### 8.4 Design cautions (learned from the current code)

1. **The shadowing-bounds semantics is the subtle core.** "`g.s0.x.min` means the
   region handled by the current iterations of enclosing loops" — in the reified
   design this becomes: a fragment grafted at depth *d* has its region params bound to
   expressions over the consumer's loop vars outer to *d*. Get this binding rule
   right first; everything else is engineering.
2. **Guards must be structural.** Replace the container-sorting/`likely`-hoisting
   dance with explicit predicate fields on fragments (RDom predicates, GuardWithIf
   conditions, specialization conditions), consumed directly by bounds binding.
3. **Specializations multiply fragments** (one per specialization branch, sharing
   region params). Fine, but the if-chain composition should live in `lower_stage`,
   not leak into grafting.
4. **A Func has up to three attachment points** (hoist ⊇ store ⊇ compute) — the Site
   record needs all three, and the legality rule (all on one root-to-leaf path in the
   consumer nest, no parallel loop between store and compute) becomes a static check
   on the placement map instead of a walk over a half-built Stmt
   (`ComputeLegalSchedules` today).
5. **Multi-stage Funcs share one Realize** across their stage fragments — the graft
   of a Func is the graft of an ordered fragment *sequence* under one produce marker.
6. **compute_with is the hardest customer**: bound-union of fused siblings and the
   extent-1 child-loop rewrite (§5.4) must be a first-class combinator, or should be
   descoped initially (it was added to Halide years after the architecture settled,
   and its bolted-on nature — FusedPairs as derived data living on the *parent's*
   schedule — shows).

### 8.5 Precedents

TVM's TensorIR made exactly this move: its `Block` construct reifies stage boundaries
with explicit read/write region annotations inside imperative IR, so scheduling
primitives are IR→IR rewrites rather than a lowering interpreter over metadata.
MLIR's `linalg`/`affine`/`scf` stack demonstrates progressive lowering with each
level a stable, inspectable dialect. Exo pushes further (scheduling as user-visible
rewrite rules on imperative IR). Halide's design — schedule as metadata interpreted
by one big pass — predates all of these; the proposal here is essentially retrofitting
the TensorIR insight while keeping Halide's front-end ergonomics and its
interval-arithmetic bounds machinery, which remains best-in-class.

---

## Appendix: key file map

| Concern | Files |
|---|---|
| Expr/Stmt nodes, handles | `Expr.h`, `IR.h/.cpp`, `IntrusivePtr.h`, `Type.h` |
| Visitors | `IRVisitor.h`, `IRMutator.h` |
| Functional layer | `Func.h/.cpp`, `Function.h/.cpp`, `FunctionPtr.h`, `Definition.h/.cpp`, `Var.h`, `RDom.h/.cpp`, `Reduction.h/.cpp` |
| Schedule data | `Schedule.h/.cpp`, `LoopPartitioningDirective.h`, `PrefetchDirective.h` |
| Driver | `Lower.cpp` (`lower_impl`, pass list) |
| Environment | `FindCalls.cpp`, `WrapCalls.cpp`, `RealizationOrder.cpp`, `SimplifySpecializations.cpp` |
| Initial lowering | `ScheduleFunctions.cpp`, `ApplySplit.cpp`, `Inline.cpp` |
| Bounds | `Bounds.cpp` (interval arithmetic, boxes), `BoundsInference.cpp`, `AllocationBoundsInference.cpp` |
| Mid→low transition | `SlidingWindow.cpp`, `StorageFolding.cpp`, `SplitTuples.cpp`, `StorageFlattening.cpp`, `UnpackBuffers.cpp`, `AddImageChecks.cpp` |
| Loop restructuring | `BoundConstantExtentLoops.cpp`, `UnrollLoops.cpp`, `VectorizeLoops.cpp`, `PartitionLoops.cpp`, `TrimNoOps.cpp`, `RebaseLoopsToZero.cpp` |
| Parallel/async/GPU | `AsyncProducers.cpp`, `LowerParallelTasks.cpp`, `OffloadGPULoops.cpp`, `InjectHostDevBufferCopies.cpp`, `FuseGPUThreadLoops.cpp` |
| Output | `Module.h`, `CodeGen_LLVM.cpp`, `CodeGen_C.cpp` |
