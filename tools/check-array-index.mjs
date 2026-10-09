#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { firefox } from 'playwright'
import { resolveReference } from './reference.mjs'

const root = resolve(import.meta.dirname, '..')
const fixture = JSON.parse(readFileSync(join(root, 'parity/array-index.json'), 'utf8'))
if (fixture.version !== 1 || fixture.cases.length !== 6 ||
    new Set(fixture.cases.map(item => item.id)).size !== 6) {
  throw Error('Invalid array-index differential fixture')
}
const { sourceIdentity } = await resolveReference({ projectRoot: root })
const directory = mkdtempSync(join(tmpdir(), 'nm-love-array-index-'))
try {
  const nativePath = join(directory, 'native.json')
  execFileSync(process.env.LOVE_BIN || 'love', ['tests/shaders/array_index'], {
    cwd: root,
    env: { ...process.env, NM_ARRAY_INDEX_OUTPUT: nativePath },
    stdio: 'inherit'
  })
  const native = JSON.parse(readFileSync(nativePath, 'utf8'))
  const browser = await firefox.launch({
    headless: true,
    firefoxUserPrefs: { 'webgl.sanitize-unmasked-renderer': false }
  })
  let oracle
  const browserVersion = browser.version()
  try {
    const page = await browser.newPage()
    oracle = await page.evaluate(fixtureValue => {
      const canvas = document.createElement('canvas')
      canvas.width = 8
      canvas.height = 8
      const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false })
      if (!gl) throw Error('Firefox WebGL2 context unavailable')
      const compile = (type, source) => {
        const shader = gl.createShader(type)
        gl.shaderSource(shader, source)
        gl.compileShader(shader)
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
          throw Error(gl.getShaderInfoLog(shader))
        }
        return shader
      }
      const vertex = compile(gl.VERTEX_SHADER,
        '#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID << 1) & 2,gl_VertexID & 2);gl_Position=vec4(p*2.0-1.0,0,1);}')
      gl.bindVertexArray(gl.createVertexArray())
      gl.viewport(0, 0, 8, 8)
      gl.disable(gl.DITHER)
      const cases = []
      for (const extent of ['literal', 'macro']) {
        const fragment = compile(gl.FRAGMENT_SHADER, fixtureValue.shaders[extent])
        const program = gl.createProgram()
        gl.attachShader(program, vertex)
        gl.attachShader(program, fragment)
        gl.linkProgram(program)
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
          throw Error(gl.getProgramInfoLog(program))
        }
        gl.useProgram(program)
        const lookup = gl.getUniformLocation(program, 'lookup')
        if (lookup === null) throw Error('Missing lookup uniform')
        for (const item of fixtureValue.cases.filter(entry => entry.extent === extent)) {
          gl.uniform1i(lookup, item.lookup)
          gl.clearColor(0, 0, 0, 0)
          gl.clear(gl.COLOR_BUFFER_BIT)
          gl.drawArrays(gl.TRIANGLES, 0, 3)
          const pixel = new Uint8Array(4)
          gl.readPixels(4, 4, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel)
          if (gl.getError() !== gl.NO_ERROR) throw Error('WebGL2 pixel readback failed')
          cases.push({ id: item.id, rgba: [...pixel] })
        }
        gl.deleteProgram(program)
        gl.deleteShader(fragment)
      }
      gl.deleteShader(vertex)
      const debug = gl.getExtension('WEBGL_debug_renderer_info')
      const gpu = debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)
      return { gpu, cases }
    }, fixture)
    await page.close()
  } finally {
    await browser.close()
  }
  if (/swiftshader|llvmpipe|software rasterizer/i.test(oracle.gpu)) {
    throw Error(`Hardware Firefox WebGL2 required, got ${oracle.gpu}`)
  }
  const nativeById = new Map(native.cases.map(item => [item.id, item.rgba]))
  const oracleById = new Map(oracle.cases.map(item => [item.id, item.rgba]))
  let errors = 0
  if (nativeById.size !== 6 || oracleById.size !== 6) {
    console.error('ARRAY-INDEX-DIFFERENTIAL missing or duplicate cases')
    errors++
  }
  for (const item of fixture.cases) {
    const expected = item.rgba && JSON.stringify(item.rgba)
    const reference = JSON.stringify(oracleById.get(item.id))
    const candidate = JSON.stringify(nativeById.get(item.id))
    if ((expected && reference !== expected) || candidate !== reference) {
      console.error('ARRAY-INDEX-DIFFERENTIAL-FAIL ' +
        JSON.stringify({ id: item.id, expected: item.rgba, reference: oracleById.get(item.id), candidate: nativeById.get(item.id) }))
      errors++
    }
  }
  console.log('ARRAY-INDEX-DIFFERENTIAL ' +
    JSON.stringify({ authority: sourceIdentity.revision, browser: browserVersion, gpu: oracle.gpu, cases: fixture.cases.length, errors }))
  if (errors) process.exitCode = 1
} finally {
  rmSync(directory, { recursive: true, force: true })
}
