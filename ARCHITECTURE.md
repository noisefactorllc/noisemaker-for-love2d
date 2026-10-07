# Noisemaker for LÖVE architecture

## 1. Purpose and status

This is a planned, independent GPU port of Noisemaker's shader engine and Polymorphic DSL. The intended deliverable is an embeddable library with a native compiler, GPU render-graph executor, effect catalog, example host, and source-bound parity harness. It is not a port of the classic CPU renderer.

Status on 2026-10-07: planning documents only. There is no implementation, package, working API, measured performance, or qualified platform. All API signatures, source layouts, and commands below are proposed contracts. Repository creation does not qualify any effect or platform.

The scope is the current upstream shader engine: compiler stages, effect definitions, shader programs, resource allocation, runtime state, host inputs, and output textures. Full catalog parity is the destination; incremental milestones do not reduce that destination. Derive the denominator from the selected upstream source at each qualification run, rather than treating the inventory observed here as a permanent count.

## 2. Selected architecture and alternatives

Select a native Lua frontend and LÖVE GPU backend. Reuse upstream GLSL as immutable input to a deterministic LÖVE adapter. Use upstream WebGL2 as the rendered authority because this route retains the GLSL algorithms. LÖVE's Shader API supports a GLSL 3 dialect and its Canvas API exposes render targets; neither fact establishes that the full Noisemaker catalog works unchanged. [LÖVE Shader](https://love2d.org/wiki/Shader), [Canvas construction](https://love2d.org/wiki/love.graphics.newCanvas).

A precompiled-graph-only loader is useful for renderer bring-up but is insufficient as the finished port: applications need native DSL compilation and live parameters. Embedding the browser renderer or binding the C++ CPU port would avoid the requested Lua/GPU implementation and is outside this design.

Proposed modules:

| Module | Responsibility |
|---|---|
| `noisemaker/compiler/` | Lua lexer, parser, validation, expansion, resources, normalization |
| `noisemaker/catalog/` | Generated Lua definitions and source provenance |
| `noisemaker/runtime/` | Graph validation, capabilities, texture pool, surfaces, frame state, execution |
| `noisemaker/shaders/` | Untouched GLSL input and deterministic LÖVE adaptation metadata |
| `noisemaker/init.lua` | Small embedding API |
| `tools/` | Development-only upstream export and catalog/shader generation |
| `tests/` and `parity/` | Native tests, oracle comparison, GPU runner and result accounting |
| `examples/viewer/` | Minimal real LÖVE host, added after runtime bring-up |

### 2.1 Proposed embedding API

`nm.compile(source, options) -> graph | nil, diagnostics`; `nm.newRenderer(graph, options) -> renderer | nil, diagnostics`. Renderer methods: `render(frame) -> Canvas | nil, diagnostics`, `setParameter(stepIndex, name, value)`, `setInput(binding, texture)`, `resize(width, height)`, `reset()`, and `release()`.

`options` includes integer pixel dimensions and catalog identity. `frame` carries explicit time, delta time, frame index, and host-fed audio/MIDI state. Output is borrowed until the next render, resize, replacement, or release; a caller needing longer retention supplies a destination Canvas for an explicit GPU copy. Calls run on the LÖVE graphics thread. No hidden draw loop, window, callback replacement, or per-frame readback belongs in the library.

### 2.2 GPU execution

Allocate from graph texture descriptors; preserve format, dimensions, filtering, wrap, mip level, layers, and usage. The common intermediate is floating-point, but some effects need different formats; do not globally substitute RGBA8 or RGBA16F. Plan single-sample intermediates, graph-ordered passes, explicit blend/clear state, MRT output mapping, feedback pairs, intra-frame repeats, and state persistence.

A pass may never sample its active render target. Use hazard-aware ping-pong and retain feedback state independently of temporary-pool liveness. Resize allocates replacement resources transactionally and applies the reference's state-reset rules. Reconfiguration and release free all owned GPU objects and leave borrowed host textures owned by the host.

Bracket each render with saved graphics state and guaranteed restoration, including error exits. Neutralize host color, transform, scissor, shader, canvas, depth/cull, and blend state before drawing. Verify restoration directly; a plausible image does not prove safe embedding.

Separate linear working textures from display conversion. Establish orientation, pixel centers, premultiplication, and gamma behavior with asymmetric fixtures rather than applying a global guessed Y flip. Host input uploads and final presentation have distinct conversion boundaries.

### 2.3 Capability admission

Query LÖVE shader support, available Canvas formats/texture types, and system limits, then test the required render/sample combinations. Admit a graph only after validating attachment count, renderability, float blending, texture sampling in the vertex stage, points/instancing, depth, volume/cubemap access, and shader features it uses. Use a feature-to-effect inventory: catalog requirements can exceed what basic GLSL 3 support proves.

Compute/storage-buffer passes and uniform-block binding are early feasibility questions for the selected public LÖVE API. Do not assume they are exposed or silently lower them to CPU. Investigate an exact GPU lowering only where its semantics can be verified; otherwise report the affected effects as unqualified and revisit the baseline before a full-port claim. The initial baseline is a capability probe target, not permission to drop difficult effects.

## 3. Compiler and graph contract

The implementation seam is upstream `shaders/src/runtime/compiler.js::compileGraph`: DSL → lexer → parser → validator → expander → resource allocation → render graph → GPU execution. A development-only JavaScript exporter supplies golden graphs before the native compiler exists. The shipping library must compile DSL without Node.js, a browser, a subprocess, or a remote service.

Preserve graph `id`, `source`, ordered `passes`, `programs`, `allocations`, `textures`, `renderSurface`, and `mediaSteps`. Maps need an explicit portable encoding. Normalize only specified representation differences and `compiledAt`; never discard semantically relevant fields to obtain equality. Record the normalizer version. The Qt normalized graph schema is a starting reference, not a substitute for inspecting current upstream fields.

Preserve pass inputs/outputs, shader identity, defines, uniform layouts and values, dimensions, repeat counts, blend factors, clear behavior, draw mode, attachment order, step indices, uniform aliases, and scoped parameters. Unknown fields with execution meaning must fail validation rather than disappear. Preserve stable diagnostic codes and source spans where upstream supplies them.

Use explicit tagged values for missing, null, booleans, numbers, strings, arrays, objects, enums, and expressions. Preserve reference numeric semantics, object iteration requirements, and source hashing. Export reference results separately for lexing, parsing, validation, expansion, allocation, and graph normalization. Never execute DSL text with a host-language evaluator. Dynamic expressions need a dedicated implementation of the reference-supported semantics; an unimplemented expression is an explicit compatibility failure.

A malformed replacement program must not destroy the last working graph. Compile, validate capabilities, and prepare new resources before activation. A failure returns a diagnostic containing its stage, effect/program, source location where available, and original backend error.

## 4. Source and parity method

Use the upstream Noisemaker checkout through `NM_REFERENCE_ROOT` as read-only behavioral authority. Record its revision, dirty status, relevant content hashes, browser build, selected reference backend, adapter, capture configuration, fixture manifest, and candidate source identity. A revision without content verification is insufficient when local changes exist. The hashes in section 7 identify files read for this plan; they are neither dependency pins nor a qualification run.

The oracle and candidate must not both consume a stale candidate-generated catalog. Export the oracle directly from upstream, regenerate the candidate catalog independently, and compare inventories and definitions before comparing output. Source changes invalidate affected evidence. A saved oracle revision may reproduce a test but must not hide drift from current upstream or route around a failing product gate.

Each case fixes DSL, effect parameters and defines, seed, dimensions, time, delta time, frame count, reset state, input assets and hashes, and capture orientation/color conversion. Stateful effects require sequential frame traces and declared warm-up/sample frames; a single attractive still is insufficient. Use asymmetric corner markers and odd dimensions to detect orientation and row-stride errors. Use raw float samples for internal texture checks and lossless PNGs for comparable final output.

Report expected cases, executed cases, exact passes, strict tolerance passes, mismatches, errors, timeouts, unsupported cases, skips, and missing fixtures separately. Unsupported cases, unavailable runners, both engines refusing a claimed-supported case, and skipped cases never count as passes or shrink the denominator. Compiler equivalence, native shader compilation, finite output, package integrity, rendered parity, and platform qualification are separate results.

For the first rendered gate, propose the existing Qt strict comparison bar: maximum absolute channel error ≤ 2.001 in 8-bit units and SSIM ≥ 0.98, plus dimensions and alpha checks. Verify the comparator and its metric definition against current family tooling before adoption. Report byte equality separately. This is a proposed initial numerical contract, not evidence that either new port meets it. Keep diagnostic relaxed/chaotic categories out of full-parity pass totals; never widen tolerances to make a port pass.

The fixture matrix includes every effect and declared mode, parameter boundaries, compile-time variants, chains, external inputs, resize, repeat, feedback, MRT, points/billboards, mesh/depth, volume/cubemap behavior, deterministic automation, and errors. Where reference backends disagree, preserve both outputs and explain the selected authority; do not choose whichever makes a candidate pass.

GPU qualification uses actual compatible hardware and the actual target runtime. CPU-only CI may validate syntax, catalog generation, graph equivalence, and reports; it cannot qualify rendering. Scheduled graphics work must use a capability-matched host broker. A job container's missing graphics device is not evidence that fleet GPU access is absent. No fleet jobs, intake recipes, or scheduling are created by this planning task.

## 5. Qualification sequence and risks

1. Desktop graphics capability and shader interface probes.
2. Exported graphs: solid, asymmetric input, multipass blur, MRT and feedback.
3. Full Lua compiler against independent upstream stage dumps.
4. Full catalog, host inputs, simulation traces, volume and geometry paths.
5. Embedding recovery, package integrity, and Windows/macOS/Linux GPU matrix.

The highest risks are LÖVE shader entry-point adaptation, unsupported buffer/compute access, float-format/MRT limits, host gamma state, GPU point and mesh semantics, Lua versus JavaScript value behavior, and graphics state leakage. Each has a named acceptance task in the implementation plan.

LÖVE mobile builds, editor UI, new effects, network services, export-site integration, and automated fleet enrollment are outside the initial implementation scope. Existing upstream-supported host data semantics remain in scope even when capture UI/device access stays with the application.

## 6. Performance and distribution

Benchmark 256×256, 512×512, 1920×1080, and an odd-sized target on identified GPUs. Measure shader warm-up separately from steady-state CPU submission, frame throughput, GPU timing where available, allocation growth, and readback costs. Include simple generators, multipass filters, and stateful/geometry workloads. No frame-rate target is a measured result until this runs.

Distribute a Lua module and its catalog/shader assets, with a small `.love` example and parity runner as separate tools. Ship no Node/browser dependency in the runtime. A clean consumer must load from an extracted package without sibling repositories, source-tree-relative paths, or runtime network fetches. Preserve upstream licensing and document compiler/tooling notices before packaging.

## 7. Evidence and source references

The local planning review on 2026-10-07 observed 210 `definition.js` files, 301 GLSL files, and 309 WGSL files under upstream `shaders/effects`. These are file inventory counts, not rendered coverage or a count of runnable pass variants. They can change before implementation.

| Upstream file | SHA-256 of inspected local bytes |
|---|---|
| `shaders/src/runtime/compiler.js` | `9a66ca9b7871450b8d3d6776bfb2d38e5ca00925e04270b48b82a92bb96cc3da` |
| `shaders/src/runtime/pipeline.js` | `f71ef923a404a9aca6df39f1fd3a916ef0ade5efbcc0ec076228a1b57d08898d` |
| `shaders/src/runtime/backends/webgl2.js` | `951ce0245fefaa29dda4dffe3e6fe0835773aa2a6f0e6889825676c772da894c` |
| `shaders/src/runtime/backends/webgpu.js` | `238faf45ea76e1b5f424ac11ea998cb1ca9a510b3d309abb71d19f4d003d4a11` |

Read upstream `shaders/src/lang/`, `shaders/src/runtime/{compiler,expander,resources,pipeline,external-input}.js`, the selected backend, and `shaders/effects/**/definition.js` before translating a subsystem. Relative links below assume sibling checkouts; they are engineering references, not shipping package dependencies.

- [Upstream graph compiler](../noisemaker/shaders/src/runtime/compiler.js)
- [Upstream pipeline](../noisemaker/shaders/src/runtime/pipeline.js)
- [Qt architecture](../noisemaker-for-qt/ARCHITECTURE.md)
- [Qt graph normalization contract](../noisemaker-for-qt/docs/GRAPH-JSON-SCHEMA.md)
- [Godot implementation plan](../noisemaker-for-godot/docs/IMPLEMENTATION-PLAN.md)

Sibling documentation records its own historical decisions. Reconfirm them against current source; do not inherit old completion claims, hard-coded catalog counts, blanket texture formats, or host assumptions.


Additional platform references:

- [LÖVE 11.5 release notes](https://love2d.org/wiki/11.5)
- [Shader interface and built-in variables](https://www.love2d.org/wiki/Shader_Variables)
- [Graphics API and capability queries](https://www.love2d.org/wiki/love.graphics)
