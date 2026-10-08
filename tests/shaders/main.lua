local root = love.filesystem.getSource() .. '/../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local function contains(s, needle) assert(s:find(needle, 1, true), 'missing ' .. needle) end
local function absent(s, needle) assert(not s:find(needle, 1, true), 'unexpected ' .. needle) end
local ok, err = xpcall(function()
  local lexer = require('noisemaker.shaders.lexer')
  local tokens = lexer.lex('/* out vec4 fake; */\nout vec4 fragColor;\nvoid main() { fragColor = vec4(1.0); }')
  assert(tokens[1].kind == 'comment' and tokens[1].line == 1)
  local adapter = require('noisemaker.shaders.adapter')
  local source = '#version 300 es\nprecision highp float;\n// gl_FragCoord in comment\nout vec4 fragColor;\nuniform sampler2D inputTex;\nvoid main() { fragColor = texture(inputTex, vec2(0.5)) + vec4(gl_FragCoord.xy,0,0); }'
  local result, diagnostic = adapter.adapt{pixel = source, path = 'test/basic.glsl', defines = {MODE = 2}}
  assert(result, tostring(diagnostic))
  contains(result.pixel, '#pragma language glsl3')
  contains(result.pixel, 'vec4 effect(')
  contains(result.pixel, 'return fragColor;')
  contains(result.pixel, 'texture(inputTex')
  contains(result.pixel, 'gl_FragCoord.xy')
  absent(result.pixel, 'love_ScreenSize.y - gl_FragCoord.y')
  contains(result.vertex, 'VertexTexCoord.xy * 2.0 - 1.0')
  contains(result.pixel, '// gl_FragCoord in comment')
  contains(result.pixel, '#define MODE 2')
  absent(result.pixel, '#version 300 es')
  absent(result.pixel, 'precision highp float;')
  assert(result.uniforms.inputTex.type == 'sampler2D')
  assert(result.provenance and result.provenance.path == 'test/basic.glsl')
  local mrt = adapter.adapt{pixel = 'layout(location=0) out vec4 a; layout(location=1) out vec4 b; void main(){a=vec4(1);b=vec4(0);}', outputs = {'a','b'}}
  assert(mrt and mrt.pixel)
  contains(mrt.pixel, 'void effect()')
  contains(mrt.pixel, 'love_Canvases[0]')
  contains(mrt.pixel, 'love_Canvases[1]')
  local vertex = adapter.adapt{pixel = 'in vec4 vColor; out vec4 fragColor; void main(){fragColor=vColor;}', vertex = 'out vec4 vColor; void main(){vColor=vec4(1);gl_Position=vec4(0);}', outputs={'fragColor'}}
  assert(vertex and vertex.vertex)
  contains(vertex.vertex, 'vec4 position(')
  contains(vertex.vertex, 'varying vec4 vColor;')
  contains(vertex.pixel, 'varying vec4 vColor;')
  local remap = adapter.adapt{pixel = 'layout(std140) uniform RemapUniforms { vec4 data[275]; }; out vec4 fragColor; void main(){fragColor=data[0]+data[274];}', path='synth/remap/glsl/remap.glsl'}
  assert(remap and remap.pixel)
  contains(remap.pixel, 'texelFetch(')
  absent(remap.pixel, 'layout(std140)')
  assert(remap.uniforms.nmRemapDataTexture.type == 'sampler2D')
  local point = adapter.adapt{
    pixel = 'in vec4 vColor; out vec4 fragColor; void main(){fragColor=vColor;}',
    vertex = 'out vec4 vColor; void main(){ int index=gl_VertexID; gl_PointSize=float(index+1); gl_Position=vec4(0,0,0,1); vColor=vec4(1); }',
    drawMode = 'points',
  }
  assert(point and point.drawMode == 'point_quads')
  contains(point.vertex, 'love_InstanceID')
  contains(point.vertex, 'nmPointClip')
  absent(point.vertex, 'gl_PointSize')
  local billboard = adapter.adapt{pixel='out vec4 fragColor; void main(){fragColor=vec4(1);}', vertex='void main(){int id=gl_VertexID;gl_Position=vec4(float(id),0,0,1);}', drawMode='billboards'}
  assert(billboard and billboard.drawMode == 'custom')
  contains(billboard.vertex, 'love_InstanceID * 6 + gl_VertexID')
  local trig = adapter.adapt{pixel=[[
#define PI 3.14159265359
#define HALF_PI (PI * 0.5)
uniform float angle;
out vec4 fragColor;
void main() {
  fragColor = vec4(cos(HALF_PI), sin(PI * 0.5 + 2.0 * PI / 3.0),
                   cos(angle), sin(angle + PI));
}]]}
  assert(trig and trig.pixel)
  contains(trig.pixel, '-4.37113883e-08')
  contains(trig.pixel, '-0.500000179')
  contains(trig.pixel, 'cos(angle)')
  contains(trig.pixel, 'sin(angle + PI)')
  absent(trig.pixel, 'cos(HALF_PI)')
  local noFold = adapter.adapt{pixel=[[
#define PI 3.14159265359
#undef PI
uniform float PI;
out vec4 fragColor;
void main() { fragColor = vec4(cos(PI)); }
]]}
  assert(noFold and noFold.pixel)
  contains(noFold.pixel, 'cos(PI)')
  local conditionalMacro = adapter.adapt{pixel=[[
#define ANGLE 1.57079632679
#if defined(USE_NEW_ANGLE)
#define ANGLE 3.14159265359
#endif
out vec4 fragColor;
void main() { fragColor = vec4(cos(ANGLE)); }
]]}
  assert(conditionalMacro and conditionalMacro.pixel)
  contains(conditionalMacro.pixel, 'cos(ANGLE)')
  local macroPrecedence = adapter.adapt{pixel=[[
#define A 1.0 + 2.0
out vec4 fragColor;
void main() { fragColor = vec4(cos(A * 2.0)); }
]]}
  assert(macroPrecedence and macroPrecedence.pixel)
  contains(macroPrecedence.pixel, 'cos(A * 2.0)')
  local macroOverride = adapter.adapt{pixel=[[
#define cos(x) ((x) * 0.0)
#define sin cos
out vec4 fragColor;
void main() { fragColor = vec4(cos(1.0), sin(1.0), 0.0, 1.0); }
]]}
  assert(macroOverride and macroOverride.pixel)
  contains(macroOverride.pixel, 'cos(1.0)')
  contains(macroOverride.pixel, 'sin(1.0)')
  local externalOverride = adapter.adapt{
    pixel='out vec4 fragColor;void main(){fragColor=vec4(cos(1.0));}',
    defines={cos='0.0'},
  }
  assert(externalOverride and externalOverride.pixel)
  contains(externalOverride.pixel, 'cos(1.0)')
  local functionOverride = adapter.adapt{pixel=[[
float cos(float angle) { return angle; }
out vec4 fragColor;
void main() { fragColor = vec4(cos(1.0)); }
]]}
  assert(functionOverride and functionOverride.pixel)
  contains(functionOverride.pixel, 'cos(1.0)')
  local functionAfterUndef = adapter.adapt{pixel=[[
float cos(float angle) { return angle; }
#undef cos
out vec4 fragColor;
void main() { fragColor = vec4(cos(1.0)); }
]]}
  assert(functionAfterUndef and functionAfterUndef.pixel)
  contains(functionAfterUndef.pixel, 'cos(1.0)')
  local remapTrig = adapter.adapt{pixel=[[
layout(std140) uniform RemapUniforms { vec4 data[275]; };
out vec4 fragColor;
void main() { fragColor = data[int(cos(0.0))]; }
]]}
  assert(remapTrig and remapTrig.pixel)
  contains(remapTrig.pixel, 'nmRemapData(int(cos(0.0)))')
  local renamedTrig = adapter.adapt{pixel=[[
#define number 0.0
out vec4 fragColor;
void main() { fragColor = vec4(cos(number)); }
]]}
  assert(renamedTrig and renamedTrig.pixel)
  contains(renamedTrig.pixel, 'cos(nmNumberValue)')
  print('shader adapter CPU tests passed')
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. '\n') end
os.exit(ok and 0 or 1)
