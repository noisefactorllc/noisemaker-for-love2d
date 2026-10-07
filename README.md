# Noisemaker for LÖVE

## 1. Status

Planned GPU port of Noisemaker for Lua applications using LÖVE. This repository currently contains guiding documents only. No renderer, Lua module, demo, or release exists yet.

## 2. Intended result

An idiomatic Lua library will compile the Polymorphic DSL and run the resulting render graph with `love.graphics` shaders and canvases. The output will be a GPU-resident Canvas usable in an existing LÖVE application. CPU work covers compilation and orchestration; effect rendering stays on the GPU.

The initial qualification target is desktop LÖVE 11.5 with Lua 5.1-compatible code and GLSL 3 support. Treat that as a proposed API baseline, not a claim that it is the newest release or that all 11.5 devices can run the catalog. Windows, macOS, and Linux each require actual host qualification. Mobile support is a later qualification stage, not an initial support claim.

## 3. Documents

- [Architecture](ARCHITECTURE.md): scope, runtime design, compatibility, evidence, and unresolved capability gates.
- [Porting guide](PORTING-GUIDE.md): GLSL adaptation, Lua semantics, graphics state, and validation rules.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md): ordered work packages, proposed files, interfaces, and acceptance checks.

## 4. First milestone

Execute an upstream-exported solid-color graph through a real LÖVE Shader and floating-point Canvas, read back a diagnostic frame, compare it against the upstream WebGL2 renderer, and restore the embedding application's graphics state. This establishes the runtime before the compiler port expands the scope.

## 5. Repository state

Created as a local repository with default branch `main`. Planning does not authorize implementation, remote creation, publication, release automation, or Worker Elves enrollment. There are no installed dependencies or usable build/test commands yet. Commands in the plan describe future deliverables. License and third-party notice review precede importing source or distributing a package.
