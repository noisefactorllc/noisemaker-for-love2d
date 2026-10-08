function love.conf(t)
  t.window.title='Noisemaker for LÖVE'
  t.window.width=800
  t.window.height=600
  t.window.resizable=true
  if os.getenv('NM_VIEWER_SMOKE')=='1' then t.window.visible=false end
  t.modules.audio=false
end
