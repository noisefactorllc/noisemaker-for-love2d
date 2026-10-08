function love.conf(t)
  t.identity = 'noisemaker-shader-sweep'
  t.window.width, t.window.height, t.window.visible = 64, 64, false
  t.modules.audio = false
  t.modules.physics = false
end
