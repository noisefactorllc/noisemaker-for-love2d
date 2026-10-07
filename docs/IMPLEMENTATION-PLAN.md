# Noisemaker for LÖVE implementation plan

## 1. Goal and execution boundary

Build the Lua compiler and LÖVE GPU runtime described in [the architecture](../ARCHITECTURE.md) and [porting guide](../PORTING-GUIDE.md). This document is an implementation proposal; no tasks have been executed. All paths and commands below are planned and do not currently exist. Implement only after the operator requests implementation.

Use failing behavioral fixtures followed by the minimal implementation and focused regression checks for each task. Review each task's evidence before expanding scope. Work in the existing default-branch checkout; publication and automation integration are separate decisions.

## 2. Review focus

| Failure condition | Expected behavior | Owning task |
|---|---|---|
| GLSL compiles but coordinates/alpha differ | Marker and alpha fixtures fail rendering gate | 1–2 |
| Unsupported MRT/format/compute requirement | Preflight names the feature and affected pass; no partial activation | 1, 3 |
| Host graphics state or borrowed texture leaks | State restored and ownership preserved on error too | 2, 6 |
| JS null/ordering/index semantics change in Lua | Stage comparison detects exact divergence | 4 |
| Feedback survives incorrectly or outputs are reused early | Sequence and lifetime tests fail | 3, 6 |

## 3. Ordered tasks

### Task 1. Establish reference export and capability probes

**Proposed files:** `tools/export-reference.mjs`, `tools/import-catalog.mjs`, `tests/fixtures/manifest.json`, `parity/capabilities/{conf,main}.lua`, `noisemaker/runtime/capabilities.lua`.

**Interface:** exporter consumes `NM_REFERENCE_ROOT` and fixture descriptors, emits normalized graphs, stage dumps, source inventory, and capture specifications. Capability probe emits actual host identity, feature values, format combinations, and render/readback results.

- [ ] Create solid, asymmetric texture, float target, MRT, integer/half, vertex-texture, uniform-block, and volume capability cases; list compute/storage requirements found in the current catalog.
- [ ] Export directly from upstream and assert catalog inventory is independent of candidate data.
- [ ] Probe with `love parity/capabilities`; require correct pixels, not only object construction.
- [ ] Establish whether desktop LÖVE 11.5 can cover the catalog with public GPU APIs. Record any exact lowering needed and its proving fixture before implementing it.

**Acceptance:** repeatable graph export plus actual GPU capability evidence; unresolved capabilities remain explicit full-port blockers. No capability result is claimed by this plan.

### Task 2. Render one golden graph safely

**Proposed files:** `noisemaker/init.lua`, `noisemaker/runtime/{graph,renderer,state_guard}.lua`, `noisemaker/shaders/adapter.lua`, `parity/runner/{conf,main}.lua`, `parity/compare.py`, `tests/gpu/solid.lua`.

**Interface:** `nm.newRenderer(graph, options)` and `renderer:render(frame)` as defined in architecture section 2.1; runner consumes graph/size/frame/input descriptors and writes binary PNG plus a metadata-only result.

- [ ] First prove the comparator rejects a wrong solid color, vertically flipped marker, missing output, and invalid dimensions.
- [ ] Adapt solid GLSL, render to the graph-declared Canvas, read back, and compare against upstream WebGL2.
- [ ] Add 257×129 markers and alpha ramps; document texture versus presented orientation and quantization.
- [ ] Surround rendering with non-default host graphics state, inject a shader error, and assert exact restoration in both cases.
- [ ] Run `love parity/runner --fixture solid` and `python3 parity/compare.py --manifest parity/out/manifest.json` after implementing these entry points.

**Acceptance:** solid and coordinate/alpha fixtures pass strict comparison; deliberate corruption fails; host rendering remains correct.

### Task 3. Complete render-graph resource and pass behavior

**Proposed files:** `noisemaker/runtime/{textures,surfaces,uniforms,passes,frame_state}.lua`, `tests/gpu/{multipass,feedback,mrt,geometry,volume}.lua`.

**Interface:** renderer consumes ordered passes and descriptor-keyed resources; exported upstream graphs remain its producer until task 4.

- [ ] Write a blur-chain fixture, two distinguishable MRT outputs, sampled feedback sequence, repeated solver pass, and dimension/format reuse regression.
- [ ] Implement liveness pooling, hazard-aware ping-pong, clear/load rules, explicit blend, uniform/define variants, and state persistence.
- [ ] Implement points, billboards, mesh depth/culling, volume/cubemap paths, and any exact GPU lowering established in task 1, each behind its proving fixture.
- [ ] Exercise resize, reset, zero/invalid dimensions, oversize targets, allocation failure, and mismatched input formats.
- [ ] Run `love tests/gpu --suite runtime`; inspect per-pass intermediates when final output diverges.

**Acceptance:** all runtime microfixtures pass; no sampling/writing alias, resource-format collision, or silently ignored capability remains in claimed support.

### Task 4. Port the DSL frontend to Lua

**Proposed files:** `noisemaker/compiler/{values,lexer,parser,validator,expander,resources,normalize,expressions}.lua`, `noisemaker/catalog/`, `tests/compiler/{main,stages}.lua`, `tools/check-stages.mjs`.

**Interface:** `nm.compile(source, options)` emits the same normalized graph accepted by task 3, or ordered diagnostics. No runtime dependency on JavaScript.

- [ ] Establish explicit value tags, null/missing sentinels, source spans, uint32 hashing, ordered iteration, and step-index conversion tests.
- [ ] Port one stage at a time; compare each stage with independent reference dumps before proceeding.
- [ ] Cover aliases/defaults/enums, nested chains, surfaces, defines, scoped parameters, `mediaSteps`, expressions, invalid input and current reference refusal behavior.
- [ ] Test malformed replacements while a valid graph is active; keep the old graph usable.
- [ ] Run `love tests/compiler` then `node tools/check-stages.mjs --reference "$NM_REFERENCE_ROOT"`; execute native-produced graphs through task 3's GPU fixtures.

**Acceptance:** native compiler matches the reference corpus structurally and diagnostically; matching refusals are separately reported and never counted as supported renders.

### Task 5. Import and qualify the full effect catalog

**Proposed files:** `tools/import-shaders.mjs`, `tests/catalog/manifest.lua`, `parity/{cases.json,run.mjs,report.py}`, generated catalog and shader trees.

**Interface:** generators consume upstream source and emit deterministic assets with provenance; harness consumes independent oracle and candidate results.

- [ ] Derive effect/mode/define/parameter coverage from current upstream definitions; include every declared shader stage and special runtime path.
- [ ] Regenerate twice and require identical hashes, full source inventory, and independent definition parity.
- [ ] Port effect families in dependency order: solid/input and basic filters, noise/mixers, iterative/stateful effects, points/meshes, then volumes and remaining specialized paths.
- [ ] Render every fixture through the real LÖVE runner, including frame traces, inputs, boundaries and chains.
- [ ] Run `node parity/run.mjs --all` and `python3 parity/report.py --require-complete`; make absent files, skips, timeouts and unsupported cases fail completeness.

**Acceptance:** full current inventory accounted for, with zero hidden exclusions. A partial milestone remains labelled partial.

### Task 6. Host inputs, embedding, and recovery

**Proposed files:** `noisemaker/runtime/{inputs,parameters,text,mesh}.lua`, `examples/viewer/{conf,main}.lua`, `tests/gpu/{embedding,inputs,lifetime}.lua`.

**Interface:** `setParameter`, `setInput`, `resize`, `reset`, and `release`; explicit host snapshots for automation and audio/MIDI, borrowed output lifetime as in architecture.

- [ ] Verify per-step input isolation, media orientation, fixed-font text, mesh normals/UVs, and deterministic audio/MIDI snapshots against upstream behavior.
- [ ] Add minimal viewer controls for load, error display, resize, reset and live parameters; exercise real interactions.
- [ ] Run 100 compile/render/resize/release cycles; assert owned object counts return to baseline and memory growth is bounded after warm-up.
- [ ] Verify failure recovery, no per-frame readback, and drawing before/after the library under changed host graphics state.

**Acceptance:** host API works without taking over application callbacks or corrupting graphics state, and every public failure path recovers.

### Task 7. Package and qualify supported hosts

**Proposed files:** `tools/package.mjs`, `tests/package-consumer/{conf,main}.lua`, packaging exclusions and license notices when source is imported.

- [ ] Build the module and `.love` example from a clean source tree, then install into a separate consumer without sibling checkouts or network access.
- [ ] Run compiler, package and full rendered gates on identified Windows, macOS and Linux GPU hosts before claiming each platform.
- [ ] Benchmark the architecture's sizes/workloads, recording warm-up, steady-state CPU/GPU costs, throughput and memory separately.
- [ ] Verify binary inputs stay binary and no private paths, credentials, generated run output, or development dependencies enter the package.

**Acceptance:** reproducible package, explicit tested platform matrix, complete source-bound parity and host evidence. Release/publication remains outside this plan's execution authority.
