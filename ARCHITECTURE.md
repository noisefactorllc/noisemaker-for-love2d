# Noisemaker for LÖVE architecture

## 1. Purpose and status

This is a planned, independent GPU port of Noisemaker's shader engine and Polymorphic DSL. The intended deliverable is an embeddable library with a native compiler, GPU render-graph executor, effect catalog, example host, and source-bound parity harness. It is not a port of the classic CPU renderer.

Status: planning documents only. There is no implementation, package, working API, measured performance, or qualified platform. All API signatures, source layouts, and commands below are proposed contracts. Repository creation does not qualify any effect or platform.

The scope is the current upstream shader engine: compiler stages, effect definitions, shader programs, resource allocation, runtime state, host inputs, user-defined Portable effects, and output textures. Full catalog parity is the destination; incremental milestones do not reduce that destination. Derive the denominator from the upstream commit in the authority lock (section 4) at each qualification run, never from a count written into a document.

## 2. Selected architecture and alternatives

Select a native Lua frontend and LÖVE GPU backend. Reuse upstream GLSL as immutable input to a deterministic LÖVE adapter. Use upstream WebGL2 as the rendered authority: this route retains the GLSL algorithms, and WebGL2 is Noisemaker's reference backend, which upstream WebGPU must match. LÖVE's Shader API supports a GLSL 3 dialect and its Canvas API exposes render targets; neither fact establishes that the full Noisemaker catalog works unchanged. [LÖVE Shader](https://love2d.org/wiki/Shader), [Canvas construction](https://love2d.org/wiki/love.graphics.newCanvas).

A precompiled-graph-only loader is useful for renderer bring-up but is insufficient as the finished port: applications need native DSL compilation and live parameters. Embedding the browser renderer or binding the C++ CPU port would avoid the requested Lua/GPU implementation and is outside this design.

Proposed modules:

| Module | Responsibility |
|---|---|
| `noisemaker/compiler/` | Lua lexer, parser, validation, expansion, resources, normalization |
| `noisemaker/catalog/` | Generated Lua definitions and source provenance |
| `noisemaker/runtime/` | Graph validation, capabilities, texture pool, surfaces, frame state, execution |
| `noisemaker/shaders/` | Untouched GLSL input and the LÖVE adapter, which also runs on Portable effects at run time |
| `noisemaker/init.lua` | Small embedding API |
| `tools/` | Development-only upstream export and catalog/shader generation |
| `scripts/test`, `scripts/parity-summary` | Family check entrypoints (section 4) |
| `tests/` and `parity/` | Native tests, shared corpus, golden minting, GPU runner and grading |
| `examples/viewer/` | Minimal real LÖVE host, added after runtime bring-up |

### 2.1 Proposed embedding API

`nm.compile(source, options) -> graph | nil, diagnostics`; `nm.newRenderer(graph, options) -> renderer | nil, diagnostics`; `nm.registerEffect(definition) -> true | nil, diagnostics` registers a user-defined Portable effect (definition plus GLSL programs), validated as upstream `effect-validator.js` validates it. Renderer methods: `render(frame) -> Canvas | nil, diagnostics`, `setParameter(stepIndex, name, value)`, `setInput(binding, texture)`, `resize(width, height)`, `reset()`, and `release()`.

`options` includes integer pixel dimensions and catalog identity. `frame` carries explicit time, delta time, frame index, and host-fed audio/MIDI state. Output is borrowed until the next render, resize, replacement, or release; a caller needing longer retention supplies a destination Canvas for an explicit GPU copy. Calls run on the LÖVE graphics thread. No hidden draw loop, window, callback replacement, or per-frame readback belongs in the library.

### 2.2 GPU execution

Allocate from graph texture descriptors; preserve format, dimensions, filtering, wrap, mip level, layers, and usage. The common intermediate is floating-point, but some effects need different formats; do not globally substitute RGBA8 or RGBA16F. Plan single-sample intermediates, graph-ordered passes, explicit blend/clear state, MRT output mapping, feedback pairs, intra-frame repeats, and state persistence.

A pass may never sample its active render target. Use hazard-aware ping-pong and retain feedback state independently of temporary-pool liveness. Resize allocates replacement resources transactionally and applies the reference's state-reset rules. Reconfiguration and release free all owned GPU objects and leave borrowed host textures owned by the host.

Bracket each render with saved graphics state and guaranteed restoration, including error exits. Neutralize host color, transform, scissor, shader, canvas, depth/cull, and blend state before drawing. Verify restoration directly; a plausible image does not prove safe embedding.

Separate linear working textures from display conversion. Establish orientation, pixel centers, premultiplication, and gamma behavior with asymmetric fixtures rather than applying a global guessed Y flip. Host input uploads and final presentation have distinct conversion boundaries.

### 2.3 Capability admission

Query LÖVE shader support, available Canvas formats/texture types, and system limits, then test the required render/sample combinations. Admit a graph only after validating attachment count, renderability, float blending, vertex-stage texture fetch, `gl_VertexID` point draws, per-vertex point size, depth, and the shader features it uses. Use a feature-to-effect inventory generated from the locked catalog: catalog requirements can exceed what basic GLSL 3 support proves.

The GLSL authority needs no compute shaders or storage buffers, because WebGL2 has neither. Upstream `webgl2.js` converts every pass with compute conventions (`storageTextures`, or an `outputBuffer` output) into a fragment-shader render pass (`convertComputeToRender`); the definitions that declare compute passes already run that way on the reference. Port that conversion rather than probing for compute. Other requirements are narrower than a generic GLSL 3 survey suggests: one catalog program uses a uniform block (`synth/remap`); effect GLSL declares no `sampler3D`, `samplerCube` or integer samplers; no catalog definition sets `is3D`; and only the backends themselves create cube textures. Volume textures enter scope through Portable effects, which may declare `is3D` textures. Cube textures stay out of scope until the authority uses them. The inventory tool rederives these facts at each lock change, so a new requirement fails the inventory check instead of slipping past it.

## 3. Compiler and graph contract

The implementation seam is upstream `shaders/src/runtime/compiler.js::compileGraph`: DSL → lexer → parser → validator → expander → resource allocation → render graph → GPU execution. A development-only JavaScript exporter supplies golden graphs before the native compiler exists. The shipping library must compile DSL without Node.js, a browser, a subprocess, or a remote service.

Preserve graph `id`, `source`, ordered `passes`, `programs`, `allocations`, `textures`, `renderSurface`, and `mediaSteps`. Maps need an explicit portable encoding. Normalize only specified representation differences and `compiledAt`; never discard semantically relevant fields to obtain equality. Record the normalizer version. The Qt normalized graph schema is a starting reference, not a substitute for inspecting current upstream fields.

Preserve pass inputs/outputs, shader identity, defines, uniform layouts and values, dimensions, repeat counts, blend factors, clear behavior, draw mode, attachment order, step indices, uniform aliases, and scoped parameters. Unknown fields with execution meaning must fail validation rather than disappear. Preserve stable diagnostic codes and source spans where upstream supplies them.

Use explicit tagged values for missing, null, booleans, numbers, strings, arrays, objects, enums, and expressions. Preserve reference numeric semantics and object iteration requirements. Upstream counts source positions in UTF-16 code units: lexer lines, columns and offsets index the JavaScript string, and `hashSource` (the graph `id`) folds `charCodeAt` values into a signed 32-bit integer printed in base 36, sign included. Lua strings are UTF-8 bytes, so decode the source to code units before hashing or computing positions, and test with non-ASCII source. Export reference results separately for lexing, parsing, validation, expansion, allocation, and graph normalization. Never execute DSL text with a host-language evaluator. Dynamic expressions need a dedicated implementation of the reference-supported semantics; an unimplemented expression is an explicit compatibility failure.

A malformed replacement program must not destroy the last working graph. Compile, validate capabilities, and prepare new resources before activation. A failure returns a diagnostic containing its stage, effect/program, source location where available, and original backend error. A Portable effect that supplies no GLSL program is unsupported on this port and fails registration with a diagnostic.

## 4. Source and parity method

The authority is the upstream Noisemaker commit pinned in `parity/reference.json` (repository and commit), as in the sibling ports. `NM_REFERENCE_ROOT` may name a checkout at that commit; otherwise the tools clone the pinned commit. Record the revision, dirty status, relevant content hashes, browser build, reference backend, adapter, capture configuration, case list, and candidate source identity with each result. A revision without content verification is insufficient when local changes exist. Move the lock forward deliberately, with fresh evidence; the scheduled port audits report the distance between the lock and upstream head.

The oracle and candidate must not both consume a stale candidate-generated catalog. Export the oracle directly from the locked commit, regenerate the candidate catalog independently, and compare inventories and definitions before comparing output. Source changes invalidate affected evidence. The lock must not hide drift from current upstream or route around a failing product gate.

Use the family entrypoints. `scripts/test` runs every check that needs no GPU against the locked authority: catalog and corpus freshness, compiler stage parity, Portable registration and the harness unit tests. `scripts/parity-summary` runs the sweep fresh (goldens minted by the reference engine in the same run, candidates rendered from DSL by this port's own compiler, every case graded) and prints one `PARITY-SUMMARY` JSON line with `expected`, `executed`, `exact`, `strict`, `near`, `defer`, `skip`, `fail`, `missing`, `uninformative`, `effects` and `effects_evidenced`. It exits 0 only when no case is near, failing, skipped or missing and every catalog effect has informative exact or strict evidence of its own. Automated gap closure reads this line, so do not substitute a differently shaped report. [Reference definition](../noisemaker-for-rust-gpu/scripts/parity-summary).

Mint goldens on the upstream WebGL2 backend, as the Qt port does (`parity/batch-golden.mjs --backend webgl2`). Assert the active backend inside the page before each capture: a Shade `BrowserSession` renders WebGL2 until `setBackend()` changes it, so the backend a tool was asked for is not proof of the backend it ran. Grade presented output.

Start from the corpus the sibling ports share rather than a new fixture set: the shared fixture programs (`parity/programs`), the generated coverage corpus of every effect with its defaults, each value of each choice parameter and each flipped boolean (`parity/coverage`), user Portable effects (`parity/portable`), the timed tier for every effect that evolves across frames (`parity/timed`), and the sibling ports' curated programs (`parity/curated`). Include upstream's per-effect `parity-case.json` programs. Port-specific microfixtures (markers, state restoration, MRT, vertex stages) sit beside the shared corpus, not in place of it.

Each case fixes DSL, effect parameters and defines, seed, dimensions, time, delta time, frame count, reset state, input assets and hashes, and capture orientation/color conversion. Stateful effects require sequential frame traces and declared warm-up/sample frames; a single attractive still is insufficient. Use asymmetric corner markers and odd dimensions to detect orientation and row-stride errors. Use raw float samples for internal texture checks and lossless PNGs for comparable final output.

Each case lands in exactly one family bucket. Exact means identical pixels. Strict means maximum absolute channel difference ≤ 2.001 in 8-bit units and global SSIM ≥ 0.98, with matching dimensions and alpha. A pass on a golden with no structure (one colour over more than 99% of the pixels, or luminance standard deviation below one 8-bit level) is uninformative and never parity evidence. Unsupported cases, unavailable runners, both engines refusing a claimed-supported case, and skipped cases never count as passes or shrink the denominator. Keep near and other relaxed categories out of full-parity totals; never widen tolerances to make a port pass. Compiler equivalence, native shader compilation, finite output, package integrity, rendered parity, and platform qualification are separate results.

The fixture matrix covers every effect and declared mode, parameter boundaries, compile-time variants, chains, external inputs, resize, repeat, feedback, MRT, points/billboards, mesh/depth, Portable effects including volume textures, deterministic automation, and errors. Where upstream WebGPU disagrees with WebGL2, the divergence is an upstream WebGPU defect; it does not change this port's golden.

GPU qualification uses actual compatible hardware and the actual target runtime. CPU-only CI may validate syntax, catalog generation, graph equivalence, and reports; it cannot qualify rendering. Scheduled graphics work must use a capability-matched host broker. A job container's missing graphics device is not evidence that fleet GPU access is absent. No fleet jobs, intake recipes, or scheduling are created by this planning task.

## 5. Qualification sequence and risks

1. Desktop graphics capability and shader interface probes, including the custom vertex stages.
2. Exported graphs: solid smoke test, then asymmetric markers, multipass blur, MRT and feedback.
3. Full Lua compiler against independent upstream stage dumps.
4. Full catalog, Portable effects, host inputs, timed traces and geometry paths.
5. Embedding recovery, package integrity, and Windows/macOS/Linux GPU matrix.

The highest risks are LÖVE shader entry-point adaptation, custom vertex stages (`gl_VertexID`, vertex-stage `texelFetch`, `gl_PointSize`), float-format/MRT limits, host gamma state, GPU point and mesh semantics, Lua versus JavaScript value behavior (including UTF-16 source positions), and graphics state leakage. Each has a named acceptance task in the implementation plan.

LÖVE mobile builds, editor UI, new effects, network services, export-site integration, and automated fleet enrollment are outside the initial implementation scope. Existing upstream-supported host data semantics remain in scope even when capture UI/device access stays with the application.

## 6. Performance and distribution

Benchmark 256×256, 512×512, 1920×1080, and an odd-sized target on identified GPUs. Measure shader warm-up separately from steady-state CPU submission, frame throughput, GPU timing where available, allocation growth, and readback costs. Include simple generators, multipass filters, and stateful/geometry workloads. No frame-rate target is a measured result until this runs.

Distribute a Lua module and its catalog/shader assets, with a small `.love` example and parity runner as separate tools. Ship no Node/browser dependency in the runtime. A clean consumer must load from an extracted package without sibling repositories, source-tree-relative paths, or runtime network fetches. Preserve upstream licensing and document compiler/tooling notices before packaging.

## 7. Source references

Read upstream `shaders/src/lang/`, `shaders/src/runtime/{compiler,expander,resources,pipeline,external-input,effect-validator,registry}.js`, `shaders/src/runtime/backends/webgl2.js`, and each effect's `definition.js` and `glsl/` directory before translating a subsystem. Effect shader sources are `.glsl`, `.vert` and `.frag` files; an inventory of `*.glsl` alone misses the custom stages. Relative links below assume sibling checkouts; they are engineering references, not shipping package dependencies.

- [Upstream graph compiler](../noisemaker/shaders/src/runtime/compiler.js)
- [Upstream pipeline](../noisemaker/shaders/src/runtime/pipeline.js)
- [Upstream WebGL2 backend](../noisemaker/shaders/src/runtime/backends/webgl2.js)
- [Family parity entrypoint and buckets](../noisemaker-for-rust-gpu/scripts/parity-summary)
- [Coverage corpus generator](../noisemaker-for-rust-gpu/tools/generate-coverage.mjs)
- [Qt WebGL2 golden sweep](../noisemaker-for-qt/parity/sweep.sh)
- [Qt architecture](../noisemaker-for-qt/ARCHITECTURE.md)
- [Qt graph normalization contract](../noisemaker-for-qt/docs/GRAPH-JSON-SCHEMA.md)
- [Godot implementation plan](../noisemaker-for-godot/docs/IMPLEMENTATION-PLAN.md)

Sibling documentation records its own historical decisions. Reconfirm them against current source; do not inherit old completion claims, hard-coded catalog counts, blanket texture formats, or host assumptions.

Additional platform references:

- [LÖVE 11.5 release notes](https://love2d.org/wiki/11.5)
- [Shader interface and built-in variables](https://www.love2d.org/wiki/Shader_Variables)
- [Graphics API and capability queries](https://www.love2d.org/wiki/love.graphics)
