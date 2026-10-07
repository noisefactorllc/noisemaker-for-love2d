# Noisemaker for LÖVE

## 1. Status

Planned GPU port of Noisemaker for Lua applications using LÖVE. This repository currently contains guiding documents only. No renderer, Lua module, demo, or release exists yet.

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

Private development repository under `noisefactorllc`, with default branch `main`. This repository remains private until the port is ready to use and the operator explicitly authorizes a public release. It currently contains planning documents only; no implementation or release is qualified. The existing scheduled port audits discover live `noisemaker-for-*` repositories, including private repositories they can access. This repository has no CI, release, or deployment workflows. There are no installed dependencies or usable build/test commands yet. Commands in the plan describe future deliverables. License and third-party notice review precede importing source or distributing a package.

## 6. Contributing

See the Noise Factor [contributing policy](https://github.com/noisefactorllc/.github/blob/main/CONTRIBUTING.md) and [Code of Conduct](https://github.com/noisefactorllc/.github/blob/main/CODE_OF_CONDUCT.md).

## 7. License and trademark

MIT (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
