function love.conf(t)
  t.identity = 'noisemaker-capabilities'
  t.window.title = 'Noisemaker LÖVE capability probe'
  t.window.width = 320
  t.window.height = 180
  t.window.visible = false
  t.modules.audio = false
  t.modules.physics = false
end
