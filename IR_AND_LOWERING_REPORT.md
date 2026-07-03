# How Halide Represents and Compiles Programs

*A deep-dive report based on reading the Halide source at main (July 2026). File and
line references point into `src/` of this tree. The report has three goals:*

1. *Explain, from first principles, the data structures Halide uses to represent
   programs — the functional front end, the schedule, and the imperative
   intermediate representation — and the two compilation phases that connect them.*
2. *Give a blueprint for building a small, clean "Halide lite" from scratch (§9).*
3. *Analyze what is tangled together inside Halide's first big lowering step, as
   groundwork for a proposal to make that step incremental (§10).*

---

## 1. The core idea, and the shape of the compiler

Halide is built around one central idea: **separate what you compute from how you
organize the computation**. A Halide program has two parts:

- The **algorithm**: a set of function definitions like "the blurred image at pixel
  (x, y) is the average of the input at (x−1, y), (x, y), and (x+1, y)". This says
  what every value *is*, as pure math. It says nothing about loops, memory, or
  order of evaluation.
- The **schedule**: a separate set of instructions like "compute the blur in tiles
  of 64×64, vectorize the innermost loop by 8, and parallelize across rows". This
  says how to organize the work, and *cannot change the result* — only the speed.

The compiler's job is to combine the two into an ordinary imperative program —
loops, arrays, loads, and stores — and hand that to a code generator.

To do this, Halide uses three distinct representations of a program, and the whole
compiler is the story of moving between them:

```
 1. The functional front end               "g(x) = f(x) + f(x+1)"
    (a graph of definitions; no loops)
         +
    The schedule                           "compute f inside g's loop over x"
    (plain data attached to each function)
         │
         │   Phase 1: schedule_functions + bounds inference
         ▼
 2. Mid-level imperative IR                loops + "realize f", "f(x) = ...",
    (loops over multi-dimensional          calls to f(x) by coordinate
     values; sizes still symbolic)
         │
         │   Phase 2: storage flattening + ~50 more passes
         ▼
 3. Low-level imperative IR                loops + malloc/free + loads and
    (flat memory, explicit addresses)      stores at computed addresses
         │
         ▼
    Code generation (LLVM, C, GPU, ...)
```

"IR" here means *intermediate representation*: the in-memory data structure the
compiler manipulates, as opposed to source text or machine code. "Lowering" means
translating a higher-level representation into a lower-level one.

Three design decisions shape everything else in the codebase, so it's worth
stating them up front:

1. **One expression language spans all three levels.** The right-hand side of a
   function definition ("f(x) + f(x+1)") and the address arithmetic in the final
   machine-level program are built from the *same* expression node types. What
   changes across levels is which *statement* forms are allowed and how a
   reference to another function is represented — not the expression language
   itself.
2. **The schedule is never a program.** Calling `f.vectorize(x, 8)` does not
   transform anything. It just records a note in a struct attached to `f`. All
   the actual transformation happens later, when lowering *interprets* those
   notes. This makes schedules cheap to build, inspect, and serialize, at the
   cost of concentrating all the transformation logic in one big pass.
3. **The mid-level IR is real but fleeting.** There is a well-defined intermediate
   world — loops over multi-dimensional values, with symbolic sizes — but it
   exists only *between* two passes. You cannot build it directly, one function at
   a time. Section 10 is about changing that.

The rest of this report walks through each representation and each phase in
enough detail to reimplement them.

---

## 2. The expression language

### 2.1 What an expression tree is, and how Halide builds one

An expression like `2 * x + 1` is represented as a tree of nodes: an `Add` node
whose left child is a `Mul` node (children: constant `2`, variable `x`) and whose
right child is the constant `1`. Every compiler has something like this. Halide's
version has a few specific properties worth understanding:

**Nodes are immutable and reference-counted.** Once built, a node never changes.
"Modifying" an expression means building a new tree that shares the unchanged
parts of the old one. Sharing is safe *because* nodes are immutable, and
reference counting (each node tracks how many pointers refer to it, and frees
itself when the count hits zero) makes the sharing memory-safe without a garbage
collector. Halide uses an *intrusive* reference count — the counter lives inside
the node itself (`IRNode` at Expr.h:97–127) rather than in a separate control
block — so that a plain raw pointer can always be turned back into an owning
handle. The handle types are `Expr` (for expressions) and `Stmt` (for
statements), both thin wrappers around a pointer.

**Every node carries a type tag instead of using C++ RTTI.** Each node stores a
one-byte enum (`IRNodeType`) saying which kind of node it is. Asking "is this an
Add?" is a tag comparison plus a pointer cast (`Expr::as<Add>()`), which is much
faster than `dynamic_cast`. The full list of node kinds is generated from a
macro list (Expr.h:28–79), and the expression kinds are deliberately listed in a
canonical "strength" order that the simplifier uses to decide which of two
equivalent forms is preferable.

**Equal-looking expressions are usually distinct objects.** Halide does not
"hash-cons" (i.e., it does not keep a global table so that building `x + 1`
twice yields the same pointer). Pointer equality (`same_as`) therefore means
"literally the same node", and structural equality is a separate deep comparison
(`IREquality.h`). Trees can still share subtrees when code explicitly reuses an
`Expr`, so traversal utilities exist that memoize visits to avoid exponential
blowup on heavily shared graphs (`IRGraphVisitor`, `IRGraphMutator`).

**Traversal uses the visitor pattern, and rewriting rebuilds only what changed.**
An `IRVisitor` has one virtual method per node kind; the default implementation
just recurses into children. An `IRMutator` is the rewriting version: its default
for each node visits the children and reconstructs the node *only if some child
actually changed*, returning the original pointer otherwise. This preservation of
identity keeps memory use sane and makes "did anything change?" checks cheap.
Nearly every compiler pass in Halide is a small subclass of one of these two.

**Types are simple.** A `Type` is a code (signed int, unsigned int, float,
bfloat, or opaque pointer/"handle"), a bit width, and a *lane count* (Type.h). A
lane count above 1 means a SIMD vector value — e.g. `Int(32, 8)` is eight 32-bit
integers processed together. Users never write vector types; they appear only
when the compiler vectorizes a loop.

**The arithmetic has carefully chosen, slightly unusual semantics** (documented
at IR.h:39–76), because the compiler must be able to *reason* about expressions,
not just evaluate them:

- Signed integers of 32 bits or more are assumed never to overflow. This lets
  the simplifier treat them as ideal mathematical integers (e.g. rewrite
  `x + 1 > x` to true). Narrower signed types and all unsigned types wrap.
- Division and modulo are *Euclidean*: the remainder is never negative, and
  division rounds toward negative infinity. This makes interval reasoning
  (Section 6) much cleaner than C's truncate-toward-zero rules. Division by
  zero yields zero rather than being undefined — again so that expressions are
  total functions that analysis can safely move around.
- Subexpressions may be reordered, duplicated, or dropped freely; there are no
  sequence points inside an expression. Floating point follows fast-math rules.

### 2.2 The expression node kinds

There are 30 expression node kinds. Most are unsurprising; the interesting ones
get extra commentary below.

*Constants:* `IntImm`, `UIntImm`, `FloatImm`, `StringImm`.

*Arithmetic and logic:* `Add`, `Sub`, `Mul`, `Div`, `Mod` (Euclidean), `Min`,
`Max`, the comparisons `EQ NE LT LE GT GE`, and `And`, `Or`, `Not`. `Select` is
a ternary "if" as a value; unlike C's `?:` it may evaluate both arms, and it
works elementwise on vectors.

*Conversion:* `Cast` (value conversion) and `Reinterpret` (bit-for-bit
reinterpretation).

*Binding:* `Let` introduces a named value for use inside a sub-expression, like
`let t = x*x in t + t`. Names are strings; scoping is handled by the passes that
walk the tree, using a helper `Scope` class (a stack-of-bindings map).

*Vectors:* `Ramp(base, stride, lanes)` is the vector
`[base, base+stride, base+2·stride, ...]` — a load whose index is a
stride-1 ramp is a contiguous vector load, the pattern all vectorization
revolves around. `Broadcast(value, lanes)` repeats a scalar across lanes.
`Shuffle` rearranges lanes; `VectorReduce` sums (or mins, maxes, ...) groups of
adjacent lanes.

*Memory:* `Load(name, index, predicate, ...)` reads one element (scalar or
vector) from a *named, flat, one-dimensional* buffer at a computed index. Loads
from different names are assumed not to alias. `Load` belongs to the low-level
world; it only appears after storage flattening (Section 7.1).

Three node kinds deserve close attention:

**`Variable`** is a reference to a named value — a loop counter, a function
argument, a `Let` binding, or a runtime parameter. Besides the name, a Variable
can carry a handle to the thing it denotes: a `Parameter` (a runtime scalar or
buffer argument), a `Buffer` (a concrete image baked into the program), or a
`ReductionDomain` (Section 3.4). These embedded handles are how later stages
know what a name means without a global symbol table — and, as Section 10 and
the companion modularization report discuss, they are also the main thing
coupling the expression language to the rest of the system.

**`Call`** is the workhorse. One node kind represents every kind of "function
application", distinguished by an enum:

- `Halide`: a call to another Halide function *by coordinate* — `f(x, y+1)`
  means "the value of f at (x, y+1)". This is the multi-dimensional read, and
  it is how the front end's function graph is knit together: the node holds a
  pointer to the callee's definition. It does not survive lowering; storage
  flattening turns it into a `Load`.
- `Image`: a coordinate read from a concrete input image or image parameter.
  Also becomes a `Load`.
- `Extern` / `ExternCPlusPlus`: a call to an outside C/C++ function, possibly
  with side effects.
- `PureExtern`: an outside function the compiler may freely reorder, duplicate,
  or de-duplicate (e.g. `sqrt`).
- `Intrinsic` / `PureIntrinsic`: operations the compiler itself understands.
  Rather than defining a node kind for every operation, Halide represents about
  a hundred operations as intrinsics identified by name (IR.h:607–779):
  bit-shifts, saturating and widening arithmetic, `if_then_else` (a Select that
  guarantees only one arm is evaluated), `prefetch`, and several *annotation*
  intrinsics that exist purely to carry analysis hints — most importantly
  `likely` (marks a branch as the common case, driving loop partitioning,
  §7.3) and `promise_clamped` (asserts a value lies in a range, tightening
  bounds analysis).

**`Let` vs names in general:** everything is bound by string name. Halide keeps
this manageable with two disciplines: compiler-generated names are made unique
by a global counter, and one lowering pass (`uniquify_variable_names`) renames
everything so that, from that point on, textual name equality really means
"same variable".

### 2.3 The statement node kinds

Statements are things executed for effect, in order. There are 17 kinds. The
low-level ones look like any imperative language:

- `LetStmt` — bind a name to a value for the duration of a statement (the
  statement-level version of `Let`).
- `AssertStmt` — check a condition; on failure call an error routine and abort
  the pipeline.
- `For(name, min, max, kind, body)` — a loop. **Note: current Halide stores an
  inclusive `min` and `max`** (extent = max − min + 1; IR.h:973–996), a recent
  change from the historical min/extent pair — older papers and docs differ.
  The `kind` says how iterations relate: `Serial` (in order), `Parallel` (any
  order, concurrently), `Vectorized` (all at once, in lockstep, as SIMD lanes),
  `Unrolled` (copies pasted in sequence), plus GPU variants that map iterations
  onto GPU blocks/threads/lanes. A vectorized or unrolled loop must eventually
  have a compile-time-constant trip count.
- `Block` — run one statement, then another (sequencing).
- `IfThenElse`, `Evaluate` (evaluate an expression for its side effect),
  `Store(name, value, index, predicate)` (the write-side twin of `Load`),
  `Allocate`/`Free` (scoped scratch memory with computed extents).

Then there are the **mid-level statements** — the ones that make Halide's
intermediate world distinctive. They speak in *multi-dimensional coordinates*
rather than flat memory:

- `Provide(name, values, args)` — "set f at coordinates (args...) to
  (values...)". A symbolic, multi-dimensional store. The plural `values` is how
  tuple-valued functions (functions returning several values per point) are
  handled.
- `Realize(name, types, bounds, body)` — "for the duration of `body`, there
  exists storage for function f covering this rectangular region of
  coordinates". A symbolic, multi-dimensional allocation. Which concrete memory,
  and at what addresses, is decided later.
- `ProducerConsumer(name, is_producer, body)` — a marker saying "this region of
  the program computes f" / "this region uses f". It carries no semantics of
  its own; it exists so analyses, profilers, and humans can tell which loops
  belong to which function. It survives to the very end as an inert label.
- `Prefetch`, `HoistedStorage` — markers for the prefetch and
  storage-lifting scheduling features; both are dissolved during lowering.

Finally a few specialized ones: `Fork` (run two statements as concurrent
tasks), `Acquire` (wait on a semaphore — `Fork`/`Acquire` implement
asynchronous producer-consumer pipelines), and `Atomic` (the body must execute
atomically with respect to surrounding parallel loops).

**The invariant that defines "lowering" in Halide:** `Provide`, `Realize`,
`Prefetch`, `HoistedStorage`, and `Call`s of kind `Halide`/`Image` exist only in
the middle of the pipeline. The code generator never sees them; if one survives
lowering, that's a compiler bug. Everything else can reach the back end.

---

## 3. The functional front end

### 3.1 What a Func is made of

When a user writes

```cpp
Func f;  Var x, y;
f(x, y) = x + y;
```

they are building an `Internal::Function` — a reference-counted record
(`FunctionContents`, Function.cpp:63–175) containing, in essence:

- a globally unique **name**;
- the list of **argument names** (`{"x", "y"}`) — these are the function's
  *dimensions*: `f` is defined over an infinite integer grid indexed by (x, y);
- the **pure definition**: the right-hand-side expression(s), stored as a
  `Definition`;
- zero or more **update definitions** (Section 3.3);
- the **schedule** for the function as a whole (`FuncSchedule`, Section 4);
- output types, and one output-buffer `Parameter` per returned value;
- optional machinery for externally-implemented stages, tracing flags, and a
  "frozen" flag: once some other function's definition has captured `f` as a
  callee, `f` can no longer be redefined (Function.cpp:281–300). This gives
  the front end value semantics — a consumer sees the producer as it was when
  the consumer was written.

A **`Definition`** (Definition.h:38–132) is one "stage" of a function:

- `args`: the left-hand-side coordinates. For the pure definition these are
  exactly the argument variables. For updates they can be arbitrary expressions.
- `values`: the right-hand-side expression(s) — plural for tuple-valued
  functions. There is no tuple type anywhere in the IR; a k-tuple function is
  just k parallel expression lists, k output types, and callers select an
  element by index.
- `predicate`: a boolean guard (from `RDom::where`, Section 3.4).
- a `StageSchedule` — the per-stage half of the schedule (Section 4).
- a list of `Specialization`s: pairs of (boolean condition, complete alternate
  Definition). `f.specialize(cond)` deep-copies the definition *and its
  schedule* so the copy can be scheduled differently; lowering compiles the
  list into an if/else-if chain choosing among differently-scheduled versions
  of the same computation.

### 3.2 How `f(x, y) = expr` becomes data

The expression `f(x, y)` by itself is ambiguous: it might be the left side of a
definition or a read of `f` inside some other expression. Halide resolves this
with a small proxy object, `FuncRef`, returned by `Func::operator()`:

- Used as a **value** (converted to `Expr`), it becomes
  `Call(Halide, "f", {x, y}, pointer-to-f's-definition)` — a by-coordinate
  read (Func.cpp:3390–3399).
- **Assigned to**, it calls `Function::define` (first time) or
  `Function::define_update` (subsequently).

`Function::define` (Function.cpp:547–663) enforces what "pure" means, checks it
structurally rather than by any clever analysis: every variable appearing on
the right-hand side must be one of the argument variables, a runtime parameter,
or bound by a `Let` — and no reduction variables are allowed. It also
freezes every function the definition calls, runs common-subexpression
elimination over the values, and — importantly — installs the **default
schedule** (Section 4.4).

### 3.3 Update definitions: how Halide expresses reductions

A pure definition alone cannot express "sum over a window" or a histogram,
because each output point would have to be a single closed-form expression.
Halide's answer is *update definitions*: after the pure definition initializes
every point, subsequent definitions imperatively revise selected points, in
order. For example, a histogram:

```cpp
histogram(x) = 0;                       // pure: initialize all bins
RDom r(0, input.width());
histogram(input(r)) += 1;               // update: walk r, bump bins
```

Semantically: run the pure step over whatever region is needed; then run each
update, iterating its reduction domain serially in order, applying its
assignment at each point.

`define_update` (Function.cpp:679–896) enforces the rules that make updates
compilable:

- The update's left-hand-side coordinate in position *i* is "pure" only if it
  is literally the same variable name as pure argument *i*. Anything else
  (`f(x+1)`, `f(r)`, `f(g(r))`) makes that position "impure", which constrains
  scheduling (an impure dimension can't be freely reordered or parallelized).
- All the reduction variables used must come from **exactly one** `RDom`.
- Types and dimensionality must match the pure definition.

### 3.4 Reduction domains

An `RDom` (reduction domain) is an explicit, named iteration space: a list of
`ReductionVariable`s, each with a name, a min, and an extent, plus an optional
boolean `where` predicate restricting the domain (Reduction.cpp:94–133). When an
update definition is created, the RDom's variables are copied into the stage's
schedule as loop dimensions, and the predicate is stored on the Definition —
after that moment the schedule, not the RDom object, is the authority.

How does the compiler know which RDom an update uses? Through the expression
language itself: a reduction variable used in an expression is a `Variable`
node carrying a pointer to its `ReductionDomain`, and the definition-checking
visitor simply collects those pointers.

One scheduling subtlety worth naming now: reduction loops are *ordered* by
default (updates may depend on earlier iterations, as `+=` does), so
parallelizing or reordering them is illegal unless the compiler can prove the
update is associative (there is a real associativity prover, used by
`rfactor` and `atomic()`), or the user explicitly waives safety.

### 3.5 The pieces around the edges

- **`Var`** is nothing but a name with sugar. **`RVar`** is a name plus a
  pointer into an RDom.
- **`Parameter`** represents a runtime argument to the compiled pipeline: a
  scalar (with optional declared range) or a buffer (with optional declared
  shape/stride constraints the compiler can exploit). Funcs' outputs are
  themselves buffer Parameters.
- **`Buffer`** is a concrete, named block of pixel data available at compile
  time (for JIT execution or baked-in tables).
- **Extern stages** let a Func be implemented by an outside function (an FFT
  library, say) instead of Halide expressions. The compiler still needs to
  reason about what region such a stage reads, which it does via a
  *bounds-query protocol*: call the extern function with null data pointers
  and let it fill in what it would need (Section 6.4).
- Reference-count hygiene: a function that calls itself (every update does)
  would create a cycle. Halide stores function payloads in shared "groups"
  and demotes within-group pointers to weak (non-owning) ones
  (FunctionPtr.h:27–88), a detail any reimplementation must get right or leak.

---

## 4. The schedule: a program's organization, as plain data

### 4.1 What scheduling directives mean

Before looking at the data structures, here is what the main directives *do*,
stated operationally. Take `f(x, y)` with its natural loop nest `for y { for x
{ compute f(x,y) } }` (conceptually):

- **`split(x, xo, xi, 8)`**: replace loop x with two nested loops — an outer
  loop `xo` and an inner loop `xi` of 8 — where `x = xo*8 + xi`. This is the
  primitive from which tiling is built. It immediately raises the *tail
  question*: what if the extent isn't divisible by 8? (Section 5.3.)
- **`fuse(x, y, xy)`**: the inverse — collapse two nested loops into one longer
  loop.
- **`reorder(xi, y, xo)`**: permute the loop nesting order.
- **`vectorize(xi)` / `unroll(xi)` / `parallel(y)`**: change a loop's execution
  kind (the `ForType` from Section 2.3) without changing its structure.
- **`tile(x, y, xi, yi, 8, 8)`**: pure sugar — two splits and a reorder.
- **`compute_at(g, y)`**: place the entire computation of `f` *inside* g's loop
  over y — so each iteration of that loop computes just the piece of f that
  iteration needs. This is the locality/recompute lever: computing f in small
  pieces near its use keeps data in cache but may recompute values needed by
  several pieces.
- **`compute_root()`**: compute all of f up front, before anything that uses it.
- **`store_at(g, y)` / `store_root()`**: choose where f's *storage* lives,
  independently of where its computation happens. Storage placed outside the
  compute loop enables reuse across iterations (Section 6.5).
- **`compute_inline()`** (the default!): don't materialize f at all; substitute
  its expression into every use, like inlining a function in a conventional
  compiler.

The remarkable implementation fact: **none of these transform anything when
called.** Each is a few lines that edit small structs hanging off the Function.
Lowering later replays those structs. The full catalog:

### 4.2 The per-function schedule

`FuncSchedule` (Schedule.cpp:233–283) answers "where does this function live?":

- `compute_level`, `store_level`, `hoist_storage_level` — three `LoopLevel`s
  (below). All three default to "inlined".
- `storage_dims` — the memory layout: the order dimensions are laid out in
  (innermost = contiguous), plus optional alignment, an explicit size bound,
  or a *fold factor* (Section 6.5) per dimension. Set by `reorder_storage`,
  `align_storage`, `bound_storage`, `fold_storage`.
- `bounds` — user promises/requirements about region sizes (`bound`,
  `align_bounds`); `estimates` — non-binding size hints for autoschedulers.
- `wrappers`, `memoized`, `async`, `ring_buffer`, `memory_type` — the
  wrapper-function (`Func::in`), memoization, and asynchronous-execution
  features.

A **`LoopLevel`** (Schedule.h:203–309) names a place in the eventual loop nest:
"function g, stage s, loop variable v", or one of two special values, *root*
(outside everything) and *inlined*. It is a mutable shared handle so libraries
can hand one out and decide its value later; at the start of lowering all
LoopLevels are locked, and two defaulting rules are applied: an unset store
level follows the compute level, and an unset hoist-storage level follows the
store level (Function.cpp:1164–1185).

### 4.3 The per-stage schedule

Each Definition owns a `StageSchedule` (Schedule.cpp:297–336) answering "what
does this stage's loop nest look like?". Its two central fields:

**`dims` — the loop list.** One `Dim {var, for_type, device_api, dim_type,
partition_policy}` per loop, ordered **innermost first**, always ending with a
sentinel pseudo-loop named `__outermost` (so schedules can name the place
outside all real loops, and so there's a stable anchor for inserting new outer
loops). `for_type` is the execution kind (serial/parallel/vectorized/...).
`dim_type` records what reordering is legal: a *pure* dimension can be
reordered and even over-computed freely; a *pure reduction* dimension can be
reordered but must cover exactly its domain; an *impure reduction* dimension
must run serially in order unless associativity is proven or safety is waived.

**`splits` — the transformation log.** An ordered list of `Split {old_var,
outer, inner, factor, exact, tail, kind}` records, where kind is split, rename,
or fuse. (The historical fourth kind, `PurifyRVar`, no longer exists.) Order
matters: lowering replays the log left to right. Directives like `vectorize(x,
8)` are literally implemented as `split(x, x, xi, 8)` followed by marking the
new inner dim vectorized (Func.cpp:1665–1702).

Also on the stage schedule: the copied reduction variables (`rvars`), prefetch
directives, the `compute_with` fusion state (below), and the race-condition
waiver flags (`allow_race_conditions`, `atomic`).

`compute_with` — a rarely-used but architecturally interesting directive that
interleaves the loop nests of two *sibling* functions (fusing their loops
without either consuming the other) — is recorded as a `FuseLoopLevel` on the
stage being moved; the inverse `FusedPair` records are derived onto the parent
stage later, during realization ordering.

### 4.4 The default schedule, and a worked example

When a pure definition is created (Function.cpp:628–644): one serial, pure
`Dim` per argument, in argument order — so the *first* argument is the
*innermost* loop — plus `__outermost`; storage laid out in the same order; and
all three loop levels inlined. **The default is full inlining**, not
compute-root. For pipeline outputs, lowering rewrites "inlined" to "root".
Update stages get their reduction variables as the innermost dims, then the
pure LHS variables, then `__outermost`.

Worked example — after:

```cpp
f(x, y) = x + y;
f.tile(x, y, xi, yi, 8, 8).vectorize(xi).parallel(y);
```

the schedule data is:

```
dims:   x.xi        Vectorized   (innermost)
        y.yi        Serial
        x.x         Serial
        y.y         Parallel
        __outermost Serial
splits: split(x -> x.x * 8 + x.xi, tail = ShiftInwards)
        split(y -> y.y * 8 + y.yi, tail = ShiftInwards)
```

Note the naming: when `x` is split, the children are named `x.xi` and `x.x` —
names accumulate their history as dot-separated prefixes, and later lookups
match by *suffix*. This works, but it is one of the string-typed conventions a
clean reimplementation should replace (Section 9.1).

---

## 5. Phase 1a: building loops (`schedule_functions`)

Now the heart of the compiler: combining the functional program with the
schedule to produce the first imperative program. Everything here is in
Lower.cpp (the driver) and ScheduleFunctions.cpp.

### 5.1 Setting the table

Before any statement exists, the driver (Lower.cpp:137–178):

1. **Deep-copies the whole function graph**, so lowering can mutate schedules
   without corrupting the user's objects.
2. Collects the **environment** — every function reachable from the outputs, by
   walking `Call(Halide)` nodes (FindCalls.cpp).
3. Applies **wrapper substitution** (`Func::in`, WrapCalls.cpp) and locks all
   LoopLevels.
4. Computes the **realization order** (RealizationOrder.cpp:295–421): a
   topological order of the functions (producers before consumers), plus the
   grouping of `compute_with`-fused functions, with careful tie-breaking so
   the order is deterministic run to run.

### 5.2 The trick that makes it all compose: symbolic bounds

Here is the key design idea, worth absorbing before the mechanics.

When Halide builds the loop nest for a function `f`, **it does not yet know how
big the loops should be**. How much of `f` is needed depends on who consumes it
and where it was placed — which may itself be inside loops whose bounds aren't
known yet. So loop bounds are emitted as *named placeholders*: the loop over
f's x dimension runs from symbol `f.s0.x.loop_min` to `f.s0.x.loop_max`, which
are defined (by trivial `let`s) in terms of symbols `f.s0.x.min` and
`f.s0.x.max` — which are **deliberately left undefined**. ("s0" = stage 0, the
pure definition; updates are s1, s2, ....)

These dangling names form a *contract*: a later pass (bounds inference, Section
6) will compute the required region of every function at every point in the
program and insert `let` statements defining exactly these names. Because the
contract is "free variables with agreed names", loop nests can be built
independently and grafted into each other before anyone knows any sizes. The
same trick is used for storage: a `Realize` node's extents are symbols like
`f.x.min_realized` / `f.x.extent_realized`, satisfied later by allocation
bounds inference.

This works, and it is the mechanism that makes the whole architecture hang
together. Its weakness — the contract is invisible, string-typed, and
satisfiable only by one global pass — is the subject of Section 10.

### 5.3 Building one stage's loop nest

`build_provide_loop_nest` (ScheduleFunctions.cpp:470–545) turns one Definition
into a loop nest, from the inside out:

**Start with the store.** The seed is a `Provide` node: for the pure stage of
`f(x, y) = x + y`, conceptually `f(f.s0.x, f.s0.y) = f.s0.x + f.s0.y` — the
definition with every variable renamed to its qualified loop name.

**Replay the split log** (`apply_split`, ApplySplit.cpp:14–166). Each split
record turns into substitutions and wrappers around the statement: for
`split(x, xo, xi, 8)`, substitute `x → xo*8 + xi + min` and record how the new
loops' bounds derive from the old one's (inner runs 0..7; outer runs
0..ceil(extent/8)−1). Here the **tail strategies** are implemented — the
answers to "extent not divisible by 8":

- **RoundUp**: let the loops overrun to the next multiple of 8; the producer's
  storage and computed region are simply enlarged to match. Fast, but only
  legal when computing extra points is harmless (pure stages into internal
  storage).
- **GuardWithIf**: overrun the loops, but wrap the body in
  `if (x <= x_max)` so the extra iterations do nothing. Always legal; the
  branch cost is later mostly eliminated by loop partitioning. The
  implementation also substitutes a `promise_clamped` annotation so bounds
  analysis knows `x` never actually exceeds its true max despite the loop
  overrunning.
- **ShiftInwards** (default for pure stages): make the *last* outer iteration
  slide backwards so its inner block ends exactly at the boundary —
  `base = min(xo*8 + min, max+1−8)`. Every iteration does a full 8 elements;
  some elements near the edge are computed twice. Illegal for updates
  (recomputing an update is not idempotent), which is why updates default to
  RoundUp/GuardWithIf.
- Variants (`Predicate`, `PredicateLoads/Stores`, blend forms) push the guard
  into load/store predicates instead of a branch — needed for vectorized
  updates.
- Splits of reduction variables are marked *exact*: an RVar loop may never
  visit points outside its domain (the domain is semantically meaningful), so
  their tails must guard, never round up.

**Wrap the loops.** Walking the `dims` list from innermost to outermost, wrap a
`For` node per dim, with the symbolic bounds described in §5.2, the ForType
from the schedule, and interleaved `let`s from the splits.

**Add the guards.** The RDom's `where` predicate becomes an `if` in the body;
specializations become an if/else-if chain of complete alternative loop nests
(one per specialization, sharing nothing but the Provide's meaning); under
`compute_with`, extra guards keep each fused sibling inside its own bounds.
The pass then does a careful bit of rearranging: it pushes pure `let`s and
guards as far *out* of the nest as dependences allow. This is not a general
optimization — it exists specifically so that bounds inference will see the
guards at outer positions and compute tight bounds. (A telling detail: one
pass placing statements *so that another pass's analysis works* is exactly the
kind of hidden coupling a redesign should make structural.)

### 5.4 Placing each function in its consumer: injection

With per-stage nests buildable, the driver assembles the whole program
(ScheduleFunctions.cpp:2565–2630). It starts from a synthetic outermost
loop that runs exactly once, named so that `LoopLevel::root()` matches it —
making compute_root just a special case of compute_at. Then it processes
functions in **reverse** realization order — consumers first — so that when a
producer is placed, its consumer's loops already exist:

For each function (or compute_with group):

1. **Validate the placement.** Walk the statement built so far, find every use
   of this function, record the stack of enclosing loops at each use, and
   intersect those stacks. The requested compute/store levels must appear in
   that common stack, in the right order, with no parallel loop between store
   and compute (that would be a race). On failure, the error message lists the
   legal placements — this is where "Func f is computed at an invalid location"
   errors come from.
2. **Inline, if scheduled inlined** (and pure): substitute f's expression into
   every `Call` to f, binding argument expressions with `let`s to avoid
   duplicating work (Inline.cpp). The function then simply doesn't exist in
   the imperative program. Note the asymmetry that Section 10 cares about:
   inlining happens *instead of* building loops, decided before any loops for
   f exist, on the functional representation.
3. **Otherwise, inject.** Walk the statement; at the loop matching f's
   *compute* level, replace the loop body with:

   ```
   produce f { <f's loop nests, one per stage, in order> }
   consume f { <the original body, which reads f> }
   ```

   and at the (equal or outer) loop matching f's *store* level, wrap the body
   in `Realize f(<symbolic bounds>)`. When store and compute levels differ,
   the Realize lands further out than the produce — that separation is what
   enables the sliding-window reuse pattern (§6.5). Outputs get no Realize
   (they live in caller-provided buffers). `compute_with` grafting — placing a
   sibling's loops *inside* another sibling's loop and rewriting the shared
   loop's bounds to the union of the two — happens here too, and is easily
   the most intricate code in the file.

### 5.5 What the program looks like now

After `schedule_functions`, for the pipeline `f(x) = 2*x; g(x) = f(x) +
f(x+1);` with `f.compute_at(g, x)`, the program is (tidied):

```
produce g {
  let g.s0.x.loop_min = g.s0.x.min          // g.s0.x.min: DANGLING — awaits
  let g.s0.x.loop_max = g.s0.x.max          //   bounds inference
  for (g.s0.x from g.s0.x.loop_min to g.s0.x.loop_max) {
    realize f([f.x.min_realized, f.x.extent_realized]) {    // sizes: dangling
      produce f {
        let f.s0.x.loop_min = f.s0.x.min    // dangling
        let f.s0.x.loop_max = f.s0.x.max
        for (f.s0.x from f.s0.x.loop_min to f.s0.x.loop_max) {
          f(f.s0.x) = 2 * f.s0.x                       // Provide
        }
      }
      consume f {
        g(g.s0.x) = f(g.s0.x) + f(1 + g.s0.x)          // Provide + 2 Calls
      }
    }
  }
}
```

Loops exist, producer-consumer structure exists, but every size is a symbol.

---

## 6. Phase 1b: computing sizes (bounds inference)

### 6.1 Interval arithmetic from first principles

The question bounds inference answers, over and over: *given that x ranges over
[a, b], what range can expression e(x) take?* The technique is interval
arithmetic — evaluate the expression over intervals instead of numbers:

- [1,3] + [10,20] = [11,23]
- [1,3] · [−2,2] = [−6,6] (take min/max over the corner combinations)
- min([a,b],[c,d]) = [min(a,c), min(b,d)], and so on per operation.

Two things make Halide's version more than a textbook exercise
(Bounds.cpp:1826, `bounds_of_expr_in_scope`):

- The interval endpoints are themselves **symbolic expressions**, not numbers
  — "x ranges over [g.min.0, g.min.0 + g.extent.0 − 1]" — and every endpoint
  computation goes through the simplifier. Bounds can also be infinite (a
  missing endpoint), and analysis must stay *conservative*: when in doubt,
  widen. This is also exactly why Halide's unusual arithmetic semantics exist:
  Euclidean division and no-overflow 32-bit ints make symbolic interval
  endpoints vastly simpler.
- Naive interval arithmetic is blind to correlation: if y = x+3, it bounds
  y − x as [span of y] − [span of x] instead of the exact 3. A dedicated
  helper pass (`simplify_correlated_differences`) exists just to cancel such
  terms before they poison loop bounds and allocation sizes.

On top of expression bounds sits the **box** machinery: a box is a vector of
intervals, one per dimension — a symbolic rectangle. `boxes_required(stmt)`
computes, for each function, the box covering every coordinate at which the
statement *reads* it (walking all the `Call(Halide)` nodes, with loop variables
bound to their ranges); `boxes_provided` does the same for writes;
`boxes_touched` unions both. Boxes from multiple uses are merged by
dimension-wise interval union.

### 6.2 The pass

`bounds_inference` (BoundsInference.cpp) fulfills the contract from §5.2. In
outline:

**Static phase.** For each stage of each function, compute — once — the box of
each of its producers that its expressions require, in terms of the *consumer's
own* symbolic bounds. ("g.s0 requires f over [g.s0.x.min, g.s0.x.max + 1]".)
Functions scheduled inline have no loops, so the pass substitutes their
expressions into consumers before analyzing (yes: inlining logic exists twice —
once in phase 1a for the program, once here for the analysis).

**Seeding.** Output functions get their bounds from the output buffer's
runtime shape: `g.s0.x` ranges over `[g.min.0, g.min.0 + g.extent.0 − 1]`,
where `g.min.0`/`g.extent.0` are fields of the buffer argument the caller
passes in.

**Mutation phase.** Walk the loop nest from the outside in; just inside each
loop, insert `let` statements defining the `.min`/`.max` symbols that stages
computed inside that loop need. The subtle and beautiful part is that the same
names get **redefined at each loop depth**, shadowing the outer definition: at
any point in the program, `f.s0.x.min ... f.s0.x.max` means "the region of f
needed *by the current iterations of all enclosing loops*". Producers nested
deeper automatically consume the narrower, iteration-specific definitions.
(Consequence: while these deliberate shadowings exist, whole-program
simplification is unsound — variable names don't uniquely identify values —
so lowering runs `uniquify_variable_names` before the first global simplify;
Lower.cpp:207–209.)

For the §5.5 example, the result is (tidied):

```
let g.s0.x.min = g.min.0                    // from the output buffer
let g.s0.x.max = g.min.0 + g.extent.0 - 1
produce g {
  for (g.s0.x from g.s0.x.min to g.s0.x.max) {
    let g.s0.x.min = g.s0.x                 // SHADOW: this iteration's point
    let g.s0.x.max = g.s0.x
    let f.s0.x.min = g.s0.x.min             // f needed over [x, x+1]
    let f.s0.x.max = g.s0.x.max + 1
    realize f([...]) {
      produce f {
        for (f.s0.x from f.s0.x.min to f.s0.x.max) {   // 2 iterations
          f(f.s0.x) = 2 * f.s0.x
        }
      }
      consume f {
        g(g.s0.x) = f(g.s0.x) + f(1 + g.s0.x)
      }
    }
  }
}
```

Each iteration of g computes the two values of f it needs — the classic
compute_at trade of redundant work for locality, now visible as arithmetic.

Reduction loops get their bounds here too (straight from the RDom's min/extent
— that's how RDom bounds enter the imperative program), and extern stages run
their bounds-query protocol.

### 6.3 Allocation sizes

A separate, simpler pass (`allocation_bounds_inference`,
AllocationBoundsInference.cpp) fills the other half of the contract: for each
`Realize`, compute `boxes_touched` of its body and define the
`min_realized`/`extent_realized` symbols just outside it. User `bound()`
declarations override the inferred values, with a runtime assertion that the
declared region really covers the touched one.

### 6.4 Checks on the pipeline's edges

Two related passes make the pipeline safe at its boundary. One asserts scalar
parameters satisfy their declared constraints. The other
(`add_image_checks`) compares each input/output buffer's *required* box
against the actual buffer the caller passed, emitting the out-of-bounds
errors Halide users know; it also substitutes any *declared* buffer
constraints (e.g. "stride 1 in x") into the program as facts the simplifier
can exploit, and implements bounds-query mode: calling the pipeline with
null data pointers fills the buffers' shape fields with what the pipeline
would need, instead of running.

### 6.5 Two follow-on optimizations that rewrite bounds

Immediately after bounds inference come two passes that exploit the now-explicit
region arithmetic. Both matter enormously for stencil pipelines (where each
output reads a small window of a producer):

- **Sliding window** (SlidingWindow.cpp): if f is *stored* outside a serial
  loop but *computed* inside it, consecutive iterations need overlapping
  regions of f. Since the storage persists across iterations, each iteration
  can skip the overlap and compute only the new part: the pass rewrites f's
  per-iteration bounds to `max(needed_min, previous_iteration_max + 1)`.
  Redundant recompute drops from window-size× to ~1×.
- **Storage folding** (StorageFolding.cpp): after sliding, only a small
  rolling window of f is ever *live* at once. If that window provably fits in
  k rows, all accesses along that dimension can be rewritten modulo k and the
  allocation shrunk to k rows — a circular buffer. Together the two passes
  turn "compute everything" schedules into classic line-buffered pipelines.

Note for Section 10: both passes work by *rewriting the region bounds of
already-placed loop nests* — precisely the quantities a reified mid-level IR
would expose as explicit parameters.

---

## 7. Phase 2: from coordinates to memory, and on to the back end

After bounds inference the program still speaks in multi-dimensional
coordinates. The rest of lowering (~50 more passes in Lower.cpp:178–606, each a
`Stmt → Stmt` function, logged and re-simplified along the way) grinds this
down to flat memory and machine-shaped loops. The pass list groups into phases;
the load-bearing ones are explained below, the rest summarized.

### 7.1 The phase transition: storage flattening

`storage_flattening` (StorageFlattening.cpp) eliminates the mid-level nodes.
First, the idea from first principles: a multi-dimensional array in flat memory
is a *convention* — element (x, y) of a W×H array lives at address
`x·stride_x + y·stride_y` for chosen strides (row-major: stride_x = 1,
stride_y = W). Choosing strides *is* choosing the memory layout.

The pass does exactly this:

- **`Realize f` → `Allocate f`** with a one-dimensional size, plus `let`s
  defining `f.min.d`, `f.extent.d`, and `f.stride.d` per dimension. The stride
  chain follows the schedule's `storage_dims` order (innermost stored
  dimension gets stride 1) — this is the moment `reorder_storage` and
  `align_storage` actually change anything.
- **`Provide f(x, y) = v` → `Store`** at index
  `(x − f.min.0)·f.stride.0 + (y − f.min.1)·f.stride.1`.
- **`Call f(x, y)` (Halide/Image kind) → `Load`** at the same index form. For
  external buffers the algebra is rearranged so the runtime-dependent base
  offset is a single loop-invariant term that hoists out of loops.
- Tuple-valued functions were already split (by an earlier pass,
  `split_tuples`) into one buffer per element, named `f.0`, `f.1`, ....

Input and output buffers get no Allocate — their min/stride/extent symbols
are later defined from the `halide_buffer_t` argument fields by
`unpack_buffers`, which is also what finally pins down the pipeline's
argument list: after it, the only free names in the program are scalar
parameters and `<name>.buffer` handles.

### 7.2 Making loops machine-shaped: unroll and vectorize

- **Unrolling** is textual: a loop marked unrolled (its extent by now a
  constant) becomes N pasted copies of the body with the loop variable
  substituted.
- **Vectorization** (VectorizeLoops.cpp) is a *type-driven rewrite*, not a
  dependence analysis: the loop variable of a vectorized loop (constant extent
  k) is replaced by the vector `Ramp(min, 1, k)`, and the substitution is
  pushed through the body — any operation with a vector operand becomes a
  vector operation, scalars are broadcast, loads/stores get vector indices (a
  contiguous index becomes a dense vector load; anything else a
  gather/scatter). Halide can vectorize *anything* this way because the
  schedule already guaranteed lockstep semantics. Control flow inside a
  vectorized body is handled by a fallback ladder: push the condition into
  load/store predicates if possible; if the condition came from loop
  partitioning, test "all lanes true" and branch between a fast vector body
  and a guarded one; failing all else, *scalarize* (re-wrap the body in a
  serial loop over lanes).

### 7.3 Getting rid of the boundary tax: loop partitioning

GuardWithIf tails, `ShiftInwards` overlaps, and user boundary conditions all
put per-iteration `if`s into loop bodies. `partition_loops`
(PartitionLoops.cpp) removes them from the common case: conditions marked with
the `likely` intrinsic are solved for the loop variable to find the sub-range
where they all hold; the loop is emitted as up to three copies — prologue
(original body), a *steady state* over that sub-range with every likely
condition replaced by its likely value (no branches, dense vector code), and
epilogue. This is why Halide boundary conditions are effectively free in the
interior of an image.

### 7.4 Parallelism becomes function calls

A parallel loop survives as a mere loop attribute until nearly the end. Then
`lower_parallel_tasks` (LowerParallelTasks.cpp) performs *closure conversion*,
the standard technique for shipping a code block to another thread: collect
every variable and buffer the loop body references (the closure), pack them
into a struct, move the body into a new top-level function taking (loop index,
closure pointer), and replace the loop with a call to the runtime:
`halide_do_par_for(task_function, min, extent, &closure)`. The thread pool
lives in the runtime library, swappable by the user. Asynchronous
producer-consumer pipelines (`async()`, from `Fork`/`Acquire` nodes) lower
similarly into task-list calls with semaphores. Consequently the LLVM backend
flatly refuses to see a parallel For — by codegen, parallelism is just calls.

GPU offload is handled analogously but earlier: loops marked as GPU
blocks/threads are compiled — during lowering — by a device code generator
into a device module (PTX, SPIR-V, ...) embedded in the binary, and replaced on
the host side with runtime launch calls plus automatically inserted
host↔device copies driven by dirty-bit tracking.

### 7.5 The rest of the pass roster

In rough order, the remaining work (each one file, each a sentence):
memoization and tracing instrumentation; `skip_stages` (guard producers whose
consumers are conditionally never run); tightening passes (`trim_no_ops`,
`rebase_loops_to_zero`, loop-invariant code motion, `remove_dead_allocations`);
`bound_small_allocations` (prove small allocations constant-size so they go on
the stack); atomics → hardware atomics or mutexes; a late single
common-subexpression-elimination pass; `find_intrinsics` (pattern-match
arithmetic into target-friendly ops like `widening_add` — deliberately *after*
the last simplifier run, which would undo them); assertion stripping under
`NoAsserts`; and user-registered custom passes. Then argument inference, and
the statement is wrapped into a `LoweredFunc` inside a `Module`.

### 7.6 What the back end receives

The final statement contains only: serial `For` loops (parallel/vector/unrolled
all dissolved), `LetStmt`s everywhere, `IfThenElse`/`AssertStmt`, flat
(possibly vector) `Load`/`Store`, `Allocate`/`Free` for internal scratch,
inert `ProducerConsumer` labels, and `Call`s to runtime functions and
intrinsics. A `Module` (Module.h) is a set of `LoweredFunc`s (name, argument
list, body, linkage) plus embedded buffers (weights, GPU kernels). Buffer
arguments arrive as `halide_buffer_t*`; the body unpacks fields itself. Code
generation (CodeGen_LLVM.cpp, CodeGen_C.cpp) is then a straightforward walk of
the statement — every semantically interesting decision has already been made.

---

## 8. Interlude: what to take away before the proposals

Three observations set up the final two sections:

1. **The system composes through a string-named contract.** Loop nests are
   built with dangling `.min`/`.max` names; injection grafts them together;
   one global pass fulfills all the names at once, using deliberate shadowing
   to encode "the region needed by the current iterations". Semantically, each
   stage's loop nest is a *function from a requested region to a statement* —
   but that function exists only implicitly, in a naming convention.
2. **Per-stage loop building is already independent.** `build_provide_loop_nest`
   consumes one Definition plus its StageSchedule and nothing else. The
   entanglement is everything around it: placement walks the global statement,
   inlining bypasses loop-building entirely, compute_with grafts nests into
   each other, and bounds inference is global.
3. **Passes are functions.** There is no pass manager, no shared context; each
   pass is `Stmt → Stmt` in its own file. The architecture is *already*
   loosely coupled at the pass level — the coupling lives in the IR contracts
   between passes.

---

## 9. Blueprint: building "Halide lite"

A standalone recreation, close in design and expressive power, sized for
research. Rough shape: a few thousand lines for the core, dominated by the
simplifier.

### 9.1 The pieces to build, in order

**1. Types and expressions (~500 lines).** Type = {kind, bits, lanes}.
Immutable, refcounted nodes with a type tag; `Expr`/`Stmt` handles; the ~25
expression kinds you actually need (constants, arithmetic with *Euclidean*
div/mod, comparisons, logic, Select, Cast, Variable, Call-with-kind-enum, Let,
Ramp, Broadcast, Load) and ~12 statement kinds (LetStmt, For, Block,
IfThenElse, Provide, Realize, ProducerConsumer, Store, Allocate, Free,
AssertStmt, Evaluate). Keep Halide's single-Call-node design — it is what lets
one expression language span all levels. Write the visitor and
rebuild-only-on-change mutator once, generated from a macro list.

Two deliberate improvements over Halide: use interned structured symbols
({function, stage, var, role}) with a printable form instead of raw strings
with suffix matching; and make the bounds contract an explicit data structure
(§9.3) rather than dangling names.

**2. The simplifier (~the biggest single investment).** Constant folding; let
substitution and dead-let removal; the algebraic rules for min/max/div/mod
and comparisons; and bounds-aware pruning (prove branches dead from variable
ranges). Every other component leans on it — Halide's fills several
Simplify_*.cpp files for good reason, and output quality tracks simplifier
quality almost linearly. Budget accordingly.

**3. Interval arithmetic and boxes (~400 lines).** `bounds_of_expr_in_scope`
with symbolic, possibly-infinite endpoints; boxes_required/provided over
statements; interval union. Handle correlated differences at least crudely, or
allocation bounds will balloon.

**4. The front end (~500 lines).** Function = {name, args, pure Definition,
update Definitions, FuncSchedule}; Definition = {args, values, predicate,
StageSchedule}; the two purity checks (§3.2, §3.3); RDom as a list of
(name, min, extent) plus predicate. Schedule structs exactly as in §4:
directive = metadata edit; tile = two splits + reorder; vectorize(x, n) =
split + mark.

**5. Phase 1 (~600 lines).** Realization order (toposort). Inline pure
functions scheduled inline. Then per stage: Provide seed → replay splits
(support RoundUp and GuardWithIf only) → wrap Fors with symbolic bounds.
Injection: walk the consumer statement; at the compute site wrap
produce/consume; at the store site wrap Realize. Then bounds inference as in
§6.2 (or the reified version below), allocation bounds, uniquify, simplify.

**6. Phase 2 (~500 lines + backend).** Storage flattening exactly as §7.1;
unroll by substitution; vectorize by ramp substitution (require clean divides
at first — no predication ladder); emit C source as the first backend (a
direct statement walk), LLVM later if wanted.

### 9.2 What to cut, and what each cut costs

Cut without much loss for research purposes: specializations, compute_with,
async/ring buffers, memoization, extern stages, GPU, tracing/profiling,
rfactor and the associativity prover (lose parallel reductions), the exotic
tail strategies, `Func::in` wrappers. Loop partitioning can wait — boundary
branches will cost until it exists.

Keep, non-negotiably: the two-layer IR with a shared expression language;
schedule-as-data with the ordered split log and innermost-first dims list; the
Provide/Realize/Call mid-level; symbolic-then-inferred bounds; interval
arithmetic; storage flattening as a distinct phase; Euclidean division. Keep
sliding window + storage folding on the shortlist — they are compact and are
what make schedules over stencils genuinely interesting.

Pitfalls to pre-empt (all observed in the real codebase): the "no global
simplification before uniquify" trap; conservative-but-tight interval
handling of ±∞; inclusive-vs-exclusive loop bound off-by-ones; reduction
splits must never over-iterate.

### 9.3 One structural upgrade worth making from day one

Even without the full Section 10 proposal: represent each stage's loop nest as
a value with an explicit *region parameter* — "given the box of f you need,
here is the statement" — instead of dangling names. Bounds inference then
becomes visibly a fold that computes each consumer's requirement and applies
producers to it. Same algorithm, but the contract is a type instead of a
convention, and every intermediate state is printable and testable.

---

## 10. Proposal: reify the mid-level IR and make phase 1 incremental

### 10.1 The problem, restated

`schedule_functions` does six jobs in one traversal: per-stage loop synthesis;
specialization trees; compute_with grafting; placement of every function into
its consumer's nest; the decision to inline instead; and whole-pipeline
validation. Its output — the only place the mid-level world exists — is a
single fused statement. You cannot: build one function's loops and look at
them; test placement separately from synthesis; re-lower one function after a
schedule change without redoing everything; or write a new placement strategy
without editing the monolith. Inlining is decided before loops exist, on the
functional form — and bounds inference then *reimplements* inlining internally
because inlined functions left no loops to analyze.

The enabling observation (§8): each stage's nest is already, semantically, a
function from a requested region to a statement, and per-stage synthesis is
already independent code. What is missing is making that function a *value*.

### 10.2 The design

Introduce a reified mid-level pipeline:

```
MidPipeline {
  fragments: map<StageId, Fragment>       // one per (function, stage)
  order:     realization DAG
  placement: map<FuncId, {compute: Site, store: Site}>   // from the schedule
}

Fragment {
  id:       StageId
  region:   list<RegionParam>     // explicit parameters — today's dangling
                                  //   f.sN.v.min/.max, made formal
  body:     Stmt                  // the loop nest; For bounds reference the
                                  //   region params; reads are Call(Halide),
                                  //   writes are Provide
  requires: map<StageId, BoxExpr> // what this fragment needs of each callee,
                                  //   as a function of its own region params
                                  //   (computable per-fragment; cacheable)
}

Site = Root | Inlined | At(StageId, loop)   // reified LoopLevel; loops carry
                                            //   stable ids, not matched by
                                            //   string suffix
```

Lowering becomes a small set of independent, testable rewrites — each of which
exists today as a facet of the monolith:

1. **`lower_stage(function, stage) → Fragment`** — today's
   `build_provide_loop_nest`, emitting region parameters instead of dangling
   names. Pure; unit-testable; every function gets loops, including ones that
   may later be inlined.
2. **`graft(pipeline, producer, site)`** — today's injection, as an explicit
   combinator: replace the site with produce/consume blocks, place Realize at
   the store site. compute_with becomes a sibling combinator with the
   union-of-bounds rule applied locally.
3. **`bind_regions(pipeline)`** — bounds inference, now compositional: at each
   graft point, the consumer's `requires[producer]` (an expression over the
   consumer's own region params and the loop variables at that depth) *is* the
   argument bound to the producer's region parameters; multiple consumers
   union. The subtle shadowing semantics of §6.2 becomes an explicit binding
   rule. One can keep a single global pass initially — the win is that the
   contract is a type, so the pass is an instantiator of a visible interface
   rather than sole owner of undocumented semantics.
4. **`inline(pipeline, func | call-site)`** — now *optional and late*: since
   reads are explicit Calls into a still-standing fragment, inlining is a
   mid-level rewrite (substitute the producer's value expression; or — a new
   capability — merge the producer's loops into the consumer's at matching
   depth). This directly realizes the goal of "first build loops for every
   stage, with explicit calls between them; then, optionally, inline". It also
   makes *partial* inlining (inline into one consumer, materialize for
   another) a first-class operation — today that requires the `Func::in`
   wrapper workaround.
5. **`slide / fold / hoist(pipeline, func)`** — sliding window and storage
   folding become fragment-local rewrites of region arguments and Realize
   extents, instead of pattern matches over one global statement.

Storage flattening and everything after it are untouched — they already
consume exactly this level; `flatten` becomes the eliminator that folds a
MidPipeline into today's post-bounds statement.

### 10.3 What this buys

- **Incrementality**: a schedule change to one function re-runs `lower_stage`
  for its stages and re-grafts; other fragments and their cached `requires`
  boxes are unaffected.
- **Testability**: synthesis, placement, bounds binding, and inlining each get
  small unit tests; today the only observable is the whole pipeline's output.
- **A real substrate for autoschedulers**: the fragment set with explicit
  required-region expressions is essentially the structure Halide's
  autoschedulers (e.g. `src/autoschedulers/adams2019`) rebuild for themselves
  from the functional form today; reifying it deletes a shadow implementation.
- **Extensibility**: new placement/fusion strategies are new combinators, not
  monolith surgery.
- **Debuggability**: printable IR between every micro-step.

### 10.4 Cautions, learned from the current code

1. **The binding rule is the subtle core.** "A fragment grafted at depth d has
   its region parameters bound to expressions over the consumer's loop
   variables outside d" — get this exactly right first; it is today's
   shadowing-let semantics, made explicit. Everything else is engineering.
2. **Make guards structural.** Replace the sort-statements-so-analysis-sees-
   the-`likely`s dance (§5.3) with explicit predicate fields on fragments,
   consumed directly by bounds binding.
3. **Specializations multiply fragments** (one per branch, sharing region
   parameters); keep that inside `lower_stage`.
4. **A function has up to three attachment points** (hoisted storage ⊇ storage
   ⊇ compute); placement legality (all on one root-to-leaf path; no parallel
   loop between store and compute) becomes a static check on the placement
   map instead of a walk over a half-built statement.
5. **Multi-stage functions share one Realize** across their stage fragments —
   grafting a function grafts an ordered fragment sequence under one produce
   marker.
6. **compute_with is the hardest customer** (union bounds; rewriting child
   loops to single-iteration shells). Make it a first-class combinator or
   descope it initially; its bolted-on shape in today's code (derived
   FusedPairs stored on the *parent's* schedule) shows it postdates the
   architecture.

### 10.5 Precedent

TVM's TensorIR made exactly this move — its "block" construct reifies stage
boundaries with explicit read/write region annotations inside imperative IR,
so scheduling is IR-to-IR rewriting rather than a metadata interpreter. MLIR's
linalg/affine/scf stack shows progressive lowering through stable, printable
levels; Exo makes scheduling rewrites user-visible. Halide's
schedule-as-metadata design predates all of these. The proposal is essentially
to retrofit that later insight while keeping the two things Halide still does
best: the front-end ergonomics, and the interval-arithmetic bounds machinery.

---

## Appendix: file map

| Concern | Files |
|---|---|
| Expression/statement nodes | `Expr.h`, `IR.h/.cpp`, `IntrusivePtr.h`, `Type.h` |
| Traversal | `IRVisitor.h`, `IRMutator.h` |
| Front end | `Func.h/.cpp`, `Function.h/.cpp`, `FunctionPtr.h`, `Definition.h/.cpp`, `Var.h`, `RDom.h/.cpp`, `Reduction.h/.cpp` |
| Schedule data | `Schedule.h/.cpp` |
| Driver and pass order | `Lower.cpp` |
| Environment/order | `FindCalls.cpp`, `WrapCalls.cpp`, `RealizationOrder.cpp` |
| Loop building & placement | `ScheduleFunctions.cpp`, `ApplySplit.cpp`, `Inline.cpp` |
| Bounds machinery | `Bounds.cpp` (intervals, boxes), `BoundsInference.cpp`, `AllocationBoundsInference.cpp` |
| Region optimizations | `SlidingWindow.cpp`, `StorageFolding.cpp` |
| Flattening & buffers | `SplitTuples.cpp`, `StorageFlattening.cpp`, `UnpackBuffers.cpp`, `AddImageChecks.cpp` |
| Loop restructuring | `UnrollLoops.cpp`, `VectorizeLoops.cpp`, `PartitionLoops.cpp` |
| Parallel/async/GPU | `AsyncProducers.cpp`, `LowerParallelTasks.cpp`, `OffloadGPULoops.cpp` |
| Output & codegen | `Module.h`, `CodeGen_LLVM.cpp`, `CodeGen_C.cpp` |
