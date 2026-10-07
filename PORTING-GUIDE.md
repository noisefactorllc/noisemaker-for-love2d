# Noisemaker for LÖVE porting guide

## 1. Authority and import boundaries

Use [the architecture](ARCHITECTURE.md) as the proposed contract. Read current upstream GLSL and WebGL2 execution together; translating a shader without its pass state is insufficient. Preserve original source bytes and hashes. Generate definitions from upstream JavaScript with a development tool; ship data in Lua, not a JavaScript evaluator. Portable effects are the exception: they arrive at run time as definition data plus GLSL, so the definition loader, validator and GLSL adapter all ship in the runtime.

Every transformation must record input shader path/hash, adapter version, defines, generated hash, and source-line mapping. Regeneration must be deterministic and leave original shader inputs untouched. Do not copy the Qt statement that its GLSL is directly executable: LÖVE has its own shader entry points.

## 2. GLSL adaptation

Use `#pragma language glsl3` in the generated LÖVE source. Adapt the reference stage entry point and output declarations to LÖVE's `effect`/`position` contract with a token-aware transformation. Avoid regex replacement of language constructs. Multi-output fragments use the documented `void effect`/`love_Canvases` interface, with explicit reference attachment ordering. [Shader](https://love2d.org/wiki/Shader), [shader variables](https://www.love2d.org/wiki/Shader_Variables).

Preserve arithmetic, casts, uint overflow, swizzles, bit operations, modulo, texture fetch semantics, sampler dimensions, and compile-time defines. Isolate substitutions for built-ins, vertex IDs, coordinate inputs, and output names. Validate half packing/unpacking, precision and integer paths using known vectors. Unsupported constructs produce a program-specific error containing the original source location.

One catalog program uses a uniform block (`synth/remap`): prove public binding support or generate an equivalent set of uniforms with tested layout/access transformation. Do not silently discard a block. Inspect `synth/remap`, median half packing, MRT state passes and the custom vertex stages before claiming the adapter covers the catalog.

Eight effects supply their own vertex stage in a `.vert` file, paired with a `.frag`: the point deposits of `filter/wormhole`, `filter3d/flow3d`, `points/dla`, `points/lenia`, `points/physarum`, `render/pointsBillboardRender` and `render/pointsRender`, and `render/meshRender`. All eight index their work with `gl_VertexID` and fetch state with `texelFetch` in the vertex stage, and most write `gl_PointSize`. LÖVE wraps vertex code in its own `position()` entry point and keeps its own point-size state (`love.graphics.setPointSize`). Prove an N-vertex points draw, vertex-stage fetch and per-vertex point size through the public API before porting these effects.

Passes with compute conventions run as fragment-shader passes on the WebGL2 reference (`convertComputeToRender` in `webgl2.js`). Reproduce that conversion, including its output mapping, instead of introducing compute shaders.

Cache keys include source hash, complete define values, stage, attachment formats, blend/depth/primitive state, adapter version, and relevant device capabilities. A failed compile must not poison a valid cached pipeline.

## 3. Coordinates, color, and raster state

First render a four-corner RGBA marker, a one-pixel border, gradients, and alpha ramps at 257×129. Compare intermediate and presented output separately. Define one boundary transformation for each path that needs it; never scatter effect-specific Y flips through shaders.

Match reference texture filtering and wrap modes per descriptor. Set host drawing color to white and use explicit blend state. Replacement passes use `setBlendMode('replace', 'premultiplied')` so LÖVE does not multiply source RGB by alpha; the mode name describes the blend input contract, and replacement preserves the shader's RGBA values. They must not inherit normal sprite alpha blending; additive simulation deposits must preserve the reference factors and attachment contents. Define linear internal color and test host gamma-correct modes separately. Do not silently change global application gamma settings.

Restore saved graphics state on success and failure. Verify using a host draw before and after Noisemaker under non-default transform, canvas, scissor, color, blend, shader, depth and cull state. Include nested renders and a shader failure. Restore the previous target before readback or cleanup.

MRT, points, billboards, mesh depth/culling, and Portable volume textures each require an isolated microfixture before effect-level tests. If the selected API cannot reproduce an operation, retain the failure in coverage and describe the capability gap; do not present a fullscreen approximation as support.

## 4. Lua compiler semantics

Target LuaJIT 2.1: Lua 5.1 syntax plus LuaJIT's `bit` module. Plain Lua 5.1 has no bitwise operators; the capability probe records `jit.version`, and a LÖVE build without LuaJIT is unqualified. Represent JSON null and missing with distinct sentinels; keep object and array types explicit, including empty arrays. Use dense indexed arrays for pass order and explicit ordered keys where upstream ordering affects output. Lua `pairs` order is not a graph contract.

Preserve zero-based DSL step indices at the public boundary while Lua arrays remain one-based internally. Keep JavaScript numeric edge behavior explicit: floor versus round, negative modulo, truthiness, signed/unsigned conversion, finite checks, and source hashing. `bit` operations return signed 32-bit results, like JavaScript's `| 0`; convert explicitly where upstream uses `>>> 0`. Upstream `hashSource` and lexer positions count UTF-16 code units, while Lua strings are UTF-8 bytes: decode the source to code units for hashing, columns and offsets, and test with non-ASCII source. A host Lua callback is not a substitute for a reference DSL expression.

Compare every compiler stage before integrating the next one. Test aliases, defaults, enums, named and positional parameters, comments, strings, diagnostics/spans, nested chains, surfaces, step overrides, and runtime expressions. Report current reference refusals separately from candidate failures and from supported programs.

## 5. Lifetimes and inputs

The application owns media capture and device permissions. It supplies named textures, decoded image data for uploads, audio/MIDI snapshots, and mesh/text inputs through explicit adapters. Preserve `mediaSteps` and per-step binding isolation. Host texture mutation must occur at documented frame boundaries.

Use binary image files/data and GPU textures. Program save/share formats contain asset references, not images encoded in strings or JSON. Readback is a parity/export operation, never the live render loop. Treat host-owned textures as borrowed; release only resources the renderer created.

On resize, recompile, reset, and repeated load/release, verify feedback initialization, final output ownership, and bounded resource counts. Failure paths must free partial allocations and retain the previous usable graph.

## 6. Acceptance accounting

Follow architecture section 4: `scripts/test` without a GPU, `scripts/parity-summary` on the GPU host. A successfully loaded `.love` file, a passing compiler suite, or one good-looking image does not qualify the renderer. Full qualification requires independent rendered comparisons and a complete, explicit denominator on each claimed host. Capture actual LÖVE version, Lua runtime (`jit.version`), OS, graphics renderer, feature flags, formats, and limits with every GPU result.
