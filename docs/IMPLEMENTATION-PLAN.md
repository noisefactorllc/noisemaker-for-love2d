# Noisemaker for LÖVE implementation plan

## 1. Goal and execution boundary

Build the Lua compiler and LÖVE GPU runtime described in [the architecture](../ARCHITECTURE.md) and [porting guide](../PORTING-GUIDE.md). Implementation now includes the native compiler, full imported shader catalog, GPU executor, host input and parameter APIs, viewer, package checks, and source-bound parity harness. Full source-bound pixel qualification passes for macOS 14.8.3 arm64 / Apple M2 / LÖVE 11.5 against Firefox 153.0 WebGL2: 3,466 cases executed, 210 effects evidenced, zero near/deferred/skipped/failed/missing cases, and unchanged candidate source. The 79 uninformative cases do not earn effect credit. Windows and Linux support remain unqualified until their native GPU checks run.

Use failing behavioral fixtures followed by the minimal implementation and focused regression checks for each task. Review each task's evidence before expanding scope. Work in the existing default-branch checkout; publication and automation integration are separate decisions.

## 2. Review focus

| Failure condition | Expected behavior | Owning task |
|---|---|---|
| GLSL compiles but coordinates/alpha differ | Marker and alpha fixtures fail rendering gate | 1–2 |
| Unsupported MRT/format/vertex-stage requirement | Preflight names the feature and affected pass; no partial activation | 1, 3 |
| A golden with no structure is counted as parity | Grader reports the case uninformative | 2, 5 |
| Host graphics state or borrowed texture leaks | State restored and ownership preserved on error too | 2, 6 |
| JS null/ordering/index/UTF-16 semantics change in Lua | Stage comparison detects exact divergence | 4 |
| Feedback survives incorrectly or outputs are reused early | Sequence and lifetime tests fail | 3, 6 |

## 3. Ordered tasks

### Task 1. Establish reference export and capability probes

**Proposed files:** `parity/reference.json`, `scripts/test`, `tools/export-reference.mjs`, `tools/import-catalog.mjs`, `tests/fixtures/manifest.json`, `parity/capabilities/{conf,main}.lua`, `noisemaker/runtime/capabilities.lua`.

**Interface:** exporter consumes the locked authority (`NM_REFERENCE_ROOT` at the commit in `parity/reference.json`, or a clone of that commit) and fixture descriptors, and emits normalized graphs, stage dumps, source inventory, and capture specifications. Capability probe emits actual host identity, Lua runtime, feature values, format combinations, and render/readback results.

- [x] Pin the authority in `parity/reference.json`; export directly from that commit and assert catalog inventory is independent of candidate data.
- [x] Create solid, asymmetric texture, float target, MRT, half packing, uniform-block (`synth/remap`), `gl_VertexID` points draw, vertex-stage `texelFetch`, per-vertex `gl_PointSize`, and volume-texture capability cases.
- [x] Generate the feature-to-effect inventory from the locked catalog, counting `.glsl`, `.vert` and `.frag` sources; fail when it finds a requirement (compute, storage, integer sampler, cube texture) that the architecture says the authority does not use.
- [x] Probe with `love parity/capabilities`; require correct pixels, not only object construction.
- [x] Establish whether desktop LÖVE 11.5 can cover the catalog with public GPU APIs. Record any exact lowering needed and its proving fixture before implementing it.
- [x] Start `scripts/test` with the GPU-free checks available so far: catalog freshness against the lock and inventory consistency.

**Acceptance:** repeatable graph export plus actual GPU capability evidence; unresolved capabilities remain explicit full-port blockers. No capability result is claimed by this plan.

### Task 2. Render one golden graph safely

**Proposed files:** `noisemaker/init.lua`, `noisemaker/runtime/{graph,renderer,state_guard}.lua`, `noisemaker/shaders/adapter.lua`, `parity/runner/{conf,main}.lua`, `parity/batch-golden.mjs`, `parity/compare.py`, `tests/gpu/solid.lua`.

**Interface:** `nm.newRenderer(graph, options)` and `renderer:render(frame)` as defined in architecture section 2.1; runner consumes graph/size/frame/input descriptors and writes binary RGBA8 plus a metadata-only result; golden minting renders the same case on upstream WebGL2 with the backend asserted in the page.

- [x] First prove the comparator rejects a wrong solid color, vertically flipped marker, missing output, and invalid dimensions, and reports a pass on a structureless golden as uninformative.
- [x] Adapt solid GLSL as a smoke test, render to the graph-declared Canvas, and read back.
- [x] Add 257×129 markers and alpha ramps as the first parity gate against same-run WebGL2 goldens; document texture versus presented orientation and quantization.
- [x] Surround rendering with non-default host graphics state, inject a shader error, and assert exact restoration in both cases.
- [x] Run `scripts/parity-summary` through its same-run WebGL2 and native LÖVE runners.

**Acceptance:** marker and alpha fixtures pass exact or strict comparison on informative goldens; the solid smoke test runs but is not parity evidence; deliberate corruption fails; host rendering remains correct.

### Task 3. Complete render-graph resource and pass behavior

**Proposed files:** `noisemaker/runtime/{textures,surfaces,uniforms,passes,frame_state}.lua`, `tests/gpu/{multipass,feedback,mrt,compute_conversion,vertex_stage,geometry,volume}.lua`.

**Interface:** renderer consumes ordered passes and descriptor-keyed resources; exported upstream graphs remain its producer until task 4.

- [x] Write a blur-chain fixture, two distinguishable MRT outputs, sampled feedback sequence, repeated solver pass, and dimension/format reuse regression.
- [x] Implement liveness pooling, hazard-aware ping-pong, clear/load rules, explicit blend, uniform/define variants, and state persistence.
- [x] Port upstream's compute-to-render pass conversion (`convertComputeToRender` in `webgl2.js`), proven with a definition that declares a compute pass.
- [x] Implement the custom vertex stages (points, billboards, mesh depth/culling) and Portable volume textures, each behind its proving fixture, plus any exact GPU lowering established in task 1.
- [x] Exercise resize, reset, zero/invalid dimensions, oversize targets, allocation failure, and mismatched input formats.
- [x] Run `scripts/test-gpu`; inspect per-pass intermediates when final output diverges.

**Acceptance:** all runtime microfixtures pass; no sampling/writing alias, resource-format collision, or silently ignored capability remains in claimed support.

### Task 4. Port the DSL frontend to Lua

**Proposed files:** `noisemaker/compiler/{values,lexer,parser,validator,expander,resources,normalize,expressions}.lua`, `noisemaker/catalog/`, `tests/compiler/{main,stages}.lua`, `tools/check-stages.mjs`.

**Interface:** `nm.compile(source, options)` emits the same normalized graph accepted by task 3, or ordered diagnostics. No runtime dependency on JavaScript.

- [x] Establish explicit value tags, null/missing sentinels, ordered iteration, and step-index conversion tests.
- [x] Test UTF-16 code-unit lines, columns and offsets, and `hashSource` (signed 32-bit, base 36) on ASCII and non-ASCII source.
- [x] Port one stage at a time; compare each stage with independent reference dumps before proceeding.
- [x] Cover aliases/defaults/enums, nested chains, surfaces, defines, scoped parameters, `mediaSteps`, expressions, invalid input and current reference refusal behavior.
- [x] Test malformed replacements while a valid graph is active; keep the old graph usable.
- [x] Add `love tests/compiler`, `tools/check-frontend.mjs`, `tools/check-graph.mjs`, and the automation/input/hook differential tools to `scripts/test`; execute native-produced graphs through the GPU fixtures.

**Acceptance:** native compiler matches the reference corpus structurally and diagnostically; matching refusals are separately reported and never counted as supported renders.

### Task 5. Import and qualify the full effect catalog

**Proposed files:** `tools/import-shaders.mjs`, `tools/generate-coverage.mjs`, `tests/catalog/manifest.lua`, `scripts/parity-summary`, `parity/sweep.sh`, `parity/{programs,coverage,portable,timed,curated}/`, generated catalog and shader trees.

**Interface:** generators consume the locked authority and emit deterministic assets with provenance; `scripts/parity-summary` mints WebGL2 goldens and renders candidates in the same run and prints the family `PARITY-SUMMARY` line.

- [x] Import the shared corpus (shared programs, curated programs, timed tier, Portable cases) and upstream `parity-case.json` programs; generate the coverage corpus from the locked definitions and add its freshness check to `scripts/test`.
- [x] Regenerate catalog and shaders twice and require identical hashes, full source inventory, and independent definition parity.
- [x] Port effect families in dependency order: solid/input and basic filters, noise/mixers, iterative/stateful effects, points/meshes, then remaining specialized paths.
- [x] Render every case through the real LÖVE runner, including timed traces, inputs, boundaries and chains.
- [x] Run `scripts/parity-summary`; absent files, skips, timeouts, unsupported and uninformative cases stay visible, and the exit status fails until every effect has informative evidence.

**Acceptance:** `PARITY-SUMMARY` reports zero near, fail, skip and missing cases, and `effects_evidenced` equals `effects`, at the locked authority. A partial milestone remains labelled partial.

### Task 6. Host inputs, Portable effects, embedding, and recovery

**Proposed files:** `noisemaker/runtime/{inputs,parameters,text,mesh,portable}.lua`, `examples/viewer/{conf,main}.lua`, `tests/gpu/{embedding,inputs,portable,lifetime}.lua`.

**Interface:** `setParameter`, `setInput`, `resize`, `reset`, and `release`; `nm.registerEffect` for Portable effects; explicit host snapshots for automation and audio/MIDI, borrowed output lifetime as in architecture.

- [x] Verify per-step input isolation, media orientation, fixed-font text, mesh normals/UVs, and deterministic audio/MIDI snapshots against upstream behavior.
- [x] Register Portable effects at run time, render them through the adapter, and refuse one without a GLSL program with a diagnostic.
- [x] Add minimal viewer controls for load, error display, resize, reset and live parameters; exercise real interactions.
- [x] Run 100 compile/render/resize/release cycles; assert owned object counts return to baseline and memory growth is bounded after warm-up.
- [x] Verify failure recovery, no per-frame readback, and drawing before/after the library under changed host graphics state.

**Acceptance:** host API works without taking over application callbacks or corrupting graphics state, and every public failure path recovers.

### Task 7. Package and qualify supported hosts

**Proposed files:** `tools/package.mjs`, `tests/package-consumer/{conf,main}.lua`, packaging exclusions and license notices when source is imported.

- [x] Build the module and `.love` example from a clean source tree, then install into a separate consumer without sibling checkouts or network access.
- [ ] Run `scripts/test` and `scripts/parity-summary` on identified Windows, macOS and Linux GPU hosts before claiming each platform. macOS Apple M2 passes; Windows and Linux remain unqualified.
- [x] Benchmark the architecture's sizes/workloads, recording warm-up, steady-state CPU/GPU costs, throughput and memory separately.
- [x] Verify binary inputs stay binary and no private paths, credentials, generated run output, or development dependencies enter the package.

**Acceptance:** reproducible package, explicit tested platform matrix, complete source-bound parity and host evidence. Release/publication remains outside this plan's execution authority.
