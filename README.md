# Noisemaker for LÖVE

## 1. Status

GPU port of Noisemaker for Lua applications using LÖVE, in early implementation. The repository has locked-reference export, generated catalog data, and a native GPU capability probe. No render-graph executor, native DSL compiler, demo, or release exists yet.

## 2. Intended result

An idiomatic Lua library will compile the Polymorphic DSL and run the resulting render graph with `love.graphics` shaders and canvases. The output will be a GPU-resident Canvas usable in an existing LÖVE application. CPU work covers compilation and orchestration; effect rendering stays on the GPU.

The initial qualification target is desktop LÖVE 11.5 on LuaJIT 2.1 (Lua 5.1 syntax plus LuaJIT's `bit` module) with GLSL 3 support. Treat that as a proposed API baseline, not a claim that it is the newest release or that all 11.5 devices can run the catalog. Windows, macOS, and Linux each require actual host qualification. Mobile support is a later qualification stage, not an initial support claim.

## 3. Documents

- [Architecture](ARCHITECTURE.md): scope, runtime design, compatibility, evidence, and unresolved capability gates.
- [Porting guide](PORTING-GUIDE.md): GLSL adaptation, Lua semantics, graphics state, and validation rules.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md): ordered work packages, proposed files, interfaces, and acceptance checks.

## 4. First milestone

Execute upstream-exported graphs through a real LÖVE Shader and floating-point Canvas: a solid color as a smoke test, then the 257×129 asymmetric marker and alpha ramps as the first parity gate. Read back each frame, compare it against an upstream WebGL2 golden minted in the same run, and restore the embedding application's graphics state. A solid color is not parity evidence: the family grader counts a golden with no structure as uninformative. This establishes the runtime before the compiler port expands the scope.

## 5. Repository state

Private development repository under `noisefactorllc`, with default branch `main`. This repository remains private until the port is ready to use and the operator explicitly authorizes a public release. The initial tooling is implemented; no renderer or release is qualified. The existing scheduled port audits discover live `noisemaker-for-*` repositories, including private repositories they can access. This repository has no CI, release, or deployment workflows. Development tools use Node.js built-ins. CPU Lua tests require LuaJIT or LÖVE; GPU probes require a real LÖVE graphics context. Most commands in the plan remain future deliverables. License and third-party notice review precede importing source or distributing a package.

## 6. Development checks

Set `NM_REFERENCE_ROOT` to a clean upstream Noisemaker checkout at the commit in `parity/reference.json`. Without it, the tools obtain an immutable source archive from the locked repository. The lock identifies the comparison authority, not a product build version.

```sh
NM_REFERENCE_ROOT=/path/to/noisemaker LOVE_BIN=/path/to/love scripts/test
NM_REFERENCE_ROOT=/path/to/noisemaker node tools/export-reference.mjs --out /tmp/love-reference.json
NM_REFERENCE_ROOT=/path/to/noisemaker node tools/import-catalog.mjs --check
love parity/capabilities
```

The CPU test entrypoint checks reference identity, compiler-stage export, catalog freshness, and Lua probe accounting with graphics disabled. `LUAJIT_BIN` can replace `LOVE_BIN`. To regenerate catalog data after a deliberate authority update, omit `--check` from the import command.

The GPU command prints `CAPABILITIES-RESULT` with host identity, pixel checks, and separate pass, fail, and unsupported counts. Set `NM_CAPABILITIES_RESULT` to save that line outside the source tree. It exits nonzero when any required probe fails or is unsupported. The probes include raw replacement RGBA, float targets, MRT, half packing, the remap data-texture lowering, custom vertex behavior, volume textures, and graphics-state recovery. Capability passes do not establish reference-versus-port parity or platform support. Generated catalog data records JavaScript lifecycle hooks for later native implementation; it does not implement those hooks.

## 7. Contributing

See the Noise Factor [contributing policy](https://github.com/noisefactorllc/.github/blob/main/CONTRIBUTING.md) and [Code of Conduct](https://github.com/noisefactorllc/.github/blob/main/CODE_OF_CONDUCT.md).

## 8. License and trademark

MIT (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
