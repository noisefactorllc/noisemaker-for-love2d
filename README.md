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

Created as a local repository with default branch `main`. Planning does not authorize implementation, remote creation, publication, release automation, or Worker Elves enrollment. Creating the `noisefactorllc` remote enrolls the port: the scheduled port audits select every live repository named `noisemaker-for-*` and record one missing from their rotation as an inventory blocker. Create the remote only when the operator decides the port enters that rotation. There are no installed dependencies or usable build/test commands yet. Commands in the plan describe future deliverables. License and third-party notice review precede importing source or distributing a package.
