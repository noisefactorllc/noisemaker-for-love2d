# {{NM_PROGRAM_NAME}}

This folder is a [LÖVE](https://love2d.org) game that plays your Noisedeck program on the GPU. `noisemaker/` is the Lua library of [Noisemaker for LÖVE](https://github.com/noisefactorllc/noisemaker-for-love2d): the Noisemaker DSL compiler, the effect catalog with its GLSL shaders, and a render-graph runtime built on `love.graphics` canvases. `main.lua` is the library's standalone viewer, set up to play `program.dsl`.

## Requirements

- **LÖVE 11.5** for desktop, on LuaJIT 2.1, with a GPU and driver that support GLSL 3. <https://love2d.org> has installers for macOS, Windows and Linux.
- The port's pixel-parity tests run on macOS with Apple silicon, where its renders match the reference engine. Windows and Linux have not been qualified yet, so renders there have not been compared with the reference.

Nothing else is needed: the library is plain Lua and GLSL, and it never uses the network.

## Run it

Unzip this folder and open a terminal in it:

```sh
love .
```

On macOS, when `love` is not on your `PATH`, run `/Applications/love.app/Contents/MacOS/love .` instead. On Windows, run `"C:\Program Files\LOVE\love.exe" .` or drag this folder onto `love.exe`.

A window opens and plays the program at the window's size. The keys:

- **F5** reloads `program.dsl`, so you can edit it and see the change.
- **R** resets the program's state.
- **Space** pauses and resumes.
- **[** and **]** select a numeric parameter, and **+** and **-** change it.

You can also drop another `.dsl` file onto the window to play it. The status line at the bottom shows the controls, or the error when a program does not compile.

## Inputs

Noisedeck exports the program, not the media or devices it ran with.

- **Media and textures.** In your own game, pass any LÖVE `Image` or `Canvas` to the renderer as an input. The viewer has none to give.
- **MIDI and audio.** There is no live MIDI or audio input. Your game can supply MIDI and audio snapshots each frame through the library's API.

## Use it in your own game

Copy the `noisemaker/` folder into the root of your game and require it:

```lua
local nm = require('noisemaker')
local renderer, canvas, elapsed = nil, nil, 0

function love.load()
  local graph, errors = nm.compile(love.filesystem.read('program.dsl'))
  assert(graph, errors and errors[1] and errors[1].message)
  local w, h = love.graphics.getDimensions()
  renderer, errors = nm.newRenderer(graph, {width = w, height = h})
  assert(renderer, errors and errors[1] and errors[1].message)
end

function love.update(dt)
  elapsed = elapsed + dt
  local errors
  canvas, errors = renderer:render({time = elapsed})
  assert(canvas, errors and errors[1] and errors[1].message)
end

function love.draw()
  if canvas then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0)
  end
end
```

`renderer:render()` returns a Canvas that stays on the GPU. Draw it, or use it as a texture in your own shaders. <https://github.com/noisefactorllc/noisemaker-for-love2d> documents the rest of the API: resizing, parameter updates, textures, MIDI and audio snapshots, and your own effects in the Portable format.

## What's inside

| Path | What it is |
| --- | --- |
| `program.dsl` | Your program's source, exactly as it was in Noisedeck. |
| `main.lua`, `conf.lua` | The standalone viewer, which plays `program.dsl`. |
| `examples/viewer/session.lua` | The viewer's renderer session. |
| `noisemaker/` | The library: compiler, effect catalog, GLSL shaders and runtime. |
| `noisedeck-export.json` | What was exported, when, and from which port commit. |
| `LICENSES/` | Licenses for everything shipped here. |

## Effects used by this program

{{NM_EFFECT_LIST}}

## Editing it

Edit `program.dsl`, or replace it with another Noisemaker program, and press F5 in the viewer.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The library here is a separate implementation, tested for pixel parity against the reference engine revision it pins. An effect added to Noisemaker after that revision is not in its catalog.

## License

The Noisemaker engine and this port are MIT licensed: `LICENSES/noisemaker-MIT.txt` and `LICENSES/noisemaker-for-love2d-LICENSE.txt`. Some shader and runtime sources carry their own notices in their file headers, among them Skia (BSD 3-Clause), the PCG random number generator, the Ashima simplex noise functions and Oklab. Your program and the imagery it renders are yours.
