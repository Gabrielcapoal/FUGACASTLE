--[[
  FUGA AUTOMÁTICA DO CASTLE — Holiday OTCv8
  ------------------------------------------------------------------
  Detecta o anúncio de invasão do Castle24H no Server Log, desliga a
  hunt e leva o personagem por uma rota de fuga até o ponto seguro.

  Usa somente a API padrão do bot do OTCv8 (macro, onTextMessage,
  UI.*, storage, CaveBot/TargetBot.setOn/setOff/isOn, CaveBot.walkTo,
  autoWalk, say, useWith, g_game, g_map). Cada função é protegida com
  pcall e há um diagnóstico no console ao carregar: se algo faltar no
  cliente Holiday, o script avisa em vez de quebrar.

  CONFIGURAÇÃO: edite a tabela CFG e (opcional) ROTA_FUGA abaixo,
  ou grave a rota pelos botões da aba Cave.
]]

---------------------------------------------------------------------
-- CONFIGURAÇÃO
---------------------------------------------------------------------
local CFG = {
  -- Detecção
  GUILDS_PADRAO     = "united front",
  PALAVRAS_INVASAO  = { "castle", "invad", "invas" }, -- precisa conter UMA delas (ajuste com a mensagem real)
  EXIGIR_PALAVRA    = true,
  JANELA_MSG_MS     = 4000,    -- junta mensagens divididas dentro deste intervalo
  REARME_MS         = 30000,   -- ignora a MESMA invasão por este tempo após disparar
  OUVIR_ONTALK      = false,   -- true = também escuta chat/broadcast (risco de falso positivo)

  -- Sobrevivência durante a fuga (cura/energy ring existentes NÃO são tocados)
  HASTE_MAGIA       = "utani hur",   -- "utani gran hur" (knight/paladin), "" para desligar
  HASTE_MANA        = 60,

  -- Fuga
  RAIO_SEGURO       = 2,       -- distância do último waypoint para considerar seguro
  MAX_DIST          = 60,      -- distância máxima por trecho (mantenha waypoints a menos de ~40 sqm)
  STUCK_MS          = 2500,    -- sem se mover por este tempo = travado
  PULOS_MAX         = 2,       -- quantos waypoints intermediários pode pular se travar
  TEMPO_MAX_MS      = 0,       -- limite total da fuga em ms (0 = sem limite: nunca desiste)

  -- Quando trava (sem andar por STUCK_MS) a fuga NÃO para: sobe de nível a cada travada
  SPELL_FUGA             = "utana vid", -- "" para não usar
  SPELL_FUGA_MANA        = 440,
  SPELL_FUGA_COOLDOWN_MS = 30000,
  SPELL_A_PARTIR         = 2,    -- tentativa em que usa a magia
  ATACAR_BLOQUEIO        = true, -- ataca o monstro que está na frente
  ATACAR_A_PARTIR        = 3,    -- tentativa em que começa a atacar
  PULAR_APOS             = 5,    -- tentativa em que pode pular um waypoint intermediário

  CANCELAR_ATAQUE       = true,
  RESTAURAR_AO_CANCELAR = true,
  DEBUG_LOG             = true,

  -- Fim da invasão: quando esta guild dominar o Castle de novo, religa CaveBot/TargetBot sozinho
  LIGAR_AO_DOMINIO      = true,
  DOMINIO_GUILD         = "pvp covarde",
  DOMINIO_PALAVRAS      = { "domin", "conquist" }, -- a mensagem precisa conter UMA delas (ajuste com a mensagem real)
  DOMINIO_EXCLUIR       = { "invad", "invas" },    -- se conter qualquer uma, NÃO conta como domínio

  -- Proteção contra morrer de novo: se morrer durante a invasão (fuga) ou até JANELA_MORTE_S segundos
  -- depois de a hunt ter sido religada sozinha, o religar automático fica BLOQUEADO até você clicar em "Liberar hunt".
  JANELA_MORTE_S        = 600,

  -- Auto-recarga: recarrega este script sozinho quando o arquivo for salvo (só com a fuga em HUNT NORMAL)
  AUTO_RECARGA          = false, -- só para o desenvolvedor testando o arquivo local; usuários usam o loader
  ARQUIVO               = "fuga_castle.lua", -- nome do arquivo dentro da pasta da config do bot
}

-- Cada usuário pode sobrescrever qualquer opção acima SEM editar este arquivo:
-- defina a tabela global FugaCastleUserCfg no loader (ex.: { HASTE_MAGIA = "utani gran hur" }).
if type(FugaCastleUserCfg) == "table" then
  for k, v in pairs(FugaCastleUserCfg) do CFG[k] = v end
end

local VERSAO = "1.3.0" -- aumente a cada atualização publicada

-- Rota manual (opcional). Se você gravar waypoints pelos botões, a rota gravada tem prioridade.
-- Campos: x, y, z | raio (tolerância, padrão 1) | tipo = "andar" (padrão) ou "usar" | item (id, para useWith)
-- Para escada/teleporte/buraco aberto: coloque a coordenada do TILE em que se pisa (andar do qual você sai)
-- e, logo depois, o primeiro waypoint do andar seguinte.
local ROTA_FUGA = {
  -- { x = 0, y = 0, z = 7 },
  -- { x = 0, y = 0, z = 7, raio = 0 },                         -- tile da escada (pisar)
  -- { x = 0, y = 0, z = 6 },                                   -- 1º waypoint do andar de cima
  -- { x = 0, y = 0, z = 6, tipo = "usar", raio = 1, item = 0 }, -- corda/pá/alavanca
}

---------------------------------------------------------------------
-- BASE
---------------------------------------------------------------------
-- Cada carga incrementa a geração; instâncias antigas ficam inertes (evita macros/handlers duplicados)
FugaCastleGen = (FugaCastleGen or 0) + 1
local GEN = FugaCastleGen
local function vivo() return FugaCastleGen == GEN end

if FugaCastle and FugaCastle.destruirUI then pcall(FugaCastle.destruirUI) end

local FC = {}
FugaCastle = FC

storage.fugaCastle = storage.fugaCastle or {}
local S = storage.fugaCastle
if S.ligado == nil then S.ligado = true end
S.guilds = S.guilds or CFG.GUILDS_PADRAO
S.rota = S.rota or {}
if S.religarSeg == nil then S.religarSeg = 0 end -- segundos em segurança até religar sozinho (0 = manual)

local function agora() return g_clock.millis() end

local function log(msg)
  pcall(print, "[FugaCastle] " .. tostring(msg))
end

local function anunciar(msg)
  log(msg)
  pcall(function() modules.game_textmessage.displayGameMessage(msg) end)
end

local function posicao()
  local ok, p = pcall(function() return player:getPosition() end)
  if ok and p then return p end
  if pos then
    local ok2, p2 = pcall(pos)
    if ok2 and p2 then return p2 end
  end
  return nil
end

local function dist(a, b)
  return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

local function norm(s)
  s = string.lower(tostring(s or ""))
  s = string.gsub(s, "%s+", "")
  return s
end

local function listaGuilds()
  local out = {}
  for g in string.gmatch(S.guilds or "", "[^,;]+") do
    local n = norm(g)
    if n ~= "" then out[#out + 1] = n end
  end
  return out
end

---------------------------------------------------------------------
-- ESTADO
---------------------------------------------------------------------
local TXT = {
  NORMAL   = "HUNT NORMAL",
  DETECTADA = "INVASÃO DETECTADA",
  FUGINDO  = "FUGINDO",
  SEGURO   = "EM SEGURANÇA",
  FALHA    = "FUGA TRAVADA (assuma o controle)",
  MORTO    = "MORREU — hunt automática BLOQUEADA",
}
local COR = {
  NORMAL = "#9be29b", DETECTADA = "#ffd24d", FUGINDO = "#ff8c42",
  SEGURO = "#4dc3ff", FALHA = "#ff4d4d", MORTO = "#ff4d4d",
}

local estado = "NORMAL"
if S.bloqueado then estado = "MORTO" end -- morreu antes: continua bloqueado após relogar
local R = {}          -- dados da fuga em andamento
local snap = {}       -- estado do CaveBot/TargetBot antes da fuga
local lblEstado, lblRota, btnLigar

local function rotaAtiva()
  if S.rota and #S.rota > 0 then return S.rota end
  local r = {}
  for _, w in ipairs(ROTA_FUGA) do
    if w.x and w.x > 0 then r[#r + 1] = w end
  end
  return r
end

local function atualizarUI()
  if btnLigar then
    pcall(function() btnLigar:setText("Fuga automática: " .. (S.ligado and "ON" or "OFF")) end)
  end
  if lblEstado then
    pcall(function()
      lblEstado:setText("Estado: " .. TXT[estado])
      lblEstado:setColor(COR[estado])
    end)
  end
  if lblRota then
    pcall(function() lblRota:setText("Rota: " .. #rotaAtiva() .. " waypoints" .. (#S.rota > 0 and " (gravada)" or " (arquivo)")) end)
  end
end

local function ativa()
  return estado == "DETECTADA" or estado == "FUGINDO" or estado == "SEGURO" or estado == "FALHA" or estado == "MORTO"
end
function FC.ativa() return ativa() end
function FC.estado() return estado end

---------------------------------------------------------------------
-- CONTROLE DA HUNT
---------------------------------------------------------------------
local macrosReg, macrosPausadas = {}, {}

-- Registre aqui macros suas que atrapalham a fuga (lure, revide PvP, etc.):
--   local m = macro(...); FugaCastle.registrarMacro(m)
function FC.registrarMacro(m) macrosReg[#macrosReg + 1] = m end

local function macroLigada(m)
  local ok, on = pcall(function() return m.isOn() end)
  return ok and on
end

local function pausarMacros()
  macrosPausadas = {}
  for _, m in ipairs(macrosReg) do
    if macroLigada(m) then
      macrosPausadas[#macrosPausadas + 1] = m
      pcall(function() m.setOff() end)
    end
  end
end

local function religarMacros()
  for _, m in ipairs(macrosPausadas) do pcall(function() m.setOn() end) end
  macrosPausadas = {}
end

local function botLigado(obj)
  if not obj or not obj.isOn then return false end
  local ok, r = pcall(function() return obj.isOn() end)
  return ok and r and true or false
end

local function botDesligar(obj)
  if obj and obj.setOff then pcall(function() obj.setOff() end) end
end

local function guarda()
  if botLigado(CaveBot) then botDesligar(CaveBot) end
  if botLigado(TargetBot) then botDesligar(TargetBot) end
  for _, m in ipairs(macrosReg) do
    if macroLigada(m) then pcall(function() m.setOff() end) end
  end
  if CFG.CANCELAR_ATAQUE and not (R.atacandoAte and g_clock.millis() < R.atacandoAte) then
    pcall(function() if g_game.isAttacking() then g_game.cancelAttack() end end)
  end
end

local function pararHunt()
  snap.cave = botLigado(CaveBot)
  snap.target = botLigado(TargetBot)
  guarda()
  pausarMacros()
end

-- Segunda camada: ignora tentativas de OUTROS scripts ligarem CaveBot/TargetBot durante a fuga.
local protegido = false
local function proteger(obj, nome)
  if not obj or not obj.setOn then return false end
  if not obj.__fugaOrigSetOn then obj.__fugaOrigSetOn = obj.setOn end
  local orig = obj.__fugaOrigSetOn
  obj.setOn = function(val, ...)
    if val ~= false and ativa() then
      log("bloqueado " .. nome .. ".setOn() durante a fuga")
      return
    end
    return orig(val, ...)
  end
  return true
end

macro(1000, function()
  if not vivo() or protegido then return end
  local a = proteger(CaveBot, "CaveBot")
  local b = proteger(TargetBot, "TargetBot")
  if a and b then protegido = true end
end)

---------------------------------------------------------------------
-- HASTE / MORTE
---------------------------------------------------------------------
local ultimoHaste = 0
local function hasted()
  local ok, r = pcall(function()
    local band = (bit32 and bit32.band) or (bit and bit.band)
    return band(player:getStates(), PlayerStates.Haste) ~= 0
  end)
  return ok and r
end

local function hasteTick(t)
  if not CFG.HASTE_MAGIA or CFG.HASTE_MAGIA == "" then return end
  if t - ultimoHaste < 2500 then return end
  if hasted() then return end
  local ok, mana = pcall(function() return player:getMana() end)
  if ok and mana and mana < CFG.HASTE_MANA then return end
  ultimoHaste = t
  pcall(say, CFG.HASTE_MAGIA)
end

local function morto()
  local ok, r = pcall(function() return player:getHealth() <= 0 end)
  return ok and r
end

local function religouRecente()
  return S.religouEm and (os.time() - S.religouEm) <= CFG.JANELA_MORTE_S
end

-- Só conta como "morte da invasão" se ocorreu durante a fuga/segurança OU logo após a hunt ser religada sozinha.
local function morreu()
  if estado == "MORTO" then return end
  if not (ativa() or religouRecente()) then return end
  S.bloqueado = true
  estado = "MORTO"
  anunciar("PERSONAGEM MORREU — hunt automática BLOQUEADA. Clique em 'Liberar hunt' quando quiser voltar.")
  atualizarUI()
end

local function falha(motivo)
  estado = "FALHA"
  anunciar("FUGA TRAVADA: " .. tostring(motivo) .. " — assuma o controle manualmente")
  atualizarUI()
end

local function concluir()
  estado = "SEGURO"
  R.seguroEm = agora()
  anunciar("FUGA CONCLUÍDA — PERSONAGEM EM SEGURANÇA")
  atualizarUI()
end

---------------------------------------------------------------------
-- ROTA / NAVEGAÇÃO
---------------------------------------------------------------------
local function escolherInicio(r)
  local p = posicao()
  if not p then return nil end
  local best, bd
  for i, w in ipairs(r) do
    if w.z == p.z then
      local d = dist(p, w)
      if not bd or d < bd then best, bd = i, d end
    end
  end
  if not best then return nil end
  -- se já passou do waypoint mais próximo (está mais perto do próximo que o trecho inteiro), começa no próximo
  local nx = r[best + 1]
  if nx and nx.z == p.z and dist(p, nx) < dist(r[best], nx) then best = best + 1 end
  return best
end

local function caminhar(w, raio)
  local dest = { x = w.x, y = w.y, z = w.z }
  local params = { ignoreNonPathable = true, precision = raio }
  if CaveBot and CaveBot.walkTo then
    pcall(CaveBot.walkTo, dest, CFG.MAX_DIST, params)
  elseif autoWalk then
    pcall(autoWalk, dest, CFG.MAX_DIST, params)
  else
    falha("nenhuma função de caminhada (CaveBot.walkTo/autoWalk) disponível")
  end
end

local function usarTile(w)
  pcall(function()
    local tile = g_map.getTile({ x = w.x, y = w.y, z = w.z })
    if not tile then return end
    local thing = tile:getTopUseThing()
    if not thing then return end
    if w.item and w.item > 0 and useWith then
      useWith(w.item, thing)
    else
      g_game.use(thing)
    end
  end)
end

local function sinal(n)
  if n > 0 then return 1 elseif n < 0 then return -1 end
  return 0
end

local ultimoSpellFuga = -999999999
local function usarSpellFuga(t)
  local sp = CFG.SPELL_FUGA
  if not sp or sp == "" then return end
  if t - ultimoSpellFuga < CFG.SPELL_FUGA_COOLDOWN_MS then return end
  local ok, mana = pcall(function() return player:getMana() end)
  if ok and mana and mana < CFG.SPELL_FUGA_MANA then return end
  ultimoSpellFuga = t
  pcall(say, sp)
  log("usando '" .. sp .. "' para passar")
end

-- Ataca o monstro mais próximo do tile à frente (na direção do waypoint)
local function atacarBloqueio(w, p, t)
  if not CFG.ATACAR_BLOQUEIO then return end
  local frente = { x = p.x + sinal(w.x - p.x), y = p.y + sinal(w.y - p.y), z = p.z }
  local okL, lista = pcall(function() return g_map.getSpectators(p, false) end)
  if not okL or not lista then return end
  local melhor, md
  for _, c in ipairs(lista) do
    pcall(function()
      if c:isMonster() then
        local cp = c:getPosition()
        if cp and cp.z == p.z and dist(p, cp) <= 2 then
          local d = dist(cp, frente) * 10 + dist(p, cp)
          if not md or d < md then melhor, md = c, d end
        end
      end
    end)
  end
  if melhor then
    R.atacandoAte = t + 4000
    pcall(function() g_game.attack(melhor) end)
    log("atacando o monstro que bloqueia a passagem")
  end
end

local function desbloquear(w, p, t)
  if R.tent >= CFG.SPELL_A_PARTIR then usarSpellFuga(t) end
  if R.tent >= CFG.ATACAR_A_PARTIR then atacarBloqueio(w, p, t) end
end

local function resetWp(t, p)
  R.tent, R.usos = 0, 0
  R.ultimaPos, R.ultimoMov = p, t
end

local function tick()
  if estado ~= "FUGINDO" then return end
  local t = agora()
  if morto() then morreu() return end
  guarda()
  if CFG.TEMPO_MAX_MS > 0 and t - R.inicio > CFG.TEMPO_MAX_MS then falha("tempo máximo excedido") return end
  hasteTick(t)

  local r = rotaAtiva()
  local p = posicao()
  if not p or not r[R.idx] then return end
  local w = r[R.idx]

  -- mudou de andar: segue para o primeiro waypoint à frente neste andar
  if p.z ~= w.z then
    local novo
    for i = R.idx + 1, #r do
      if r[i].z == p.z then novo = i; break end
    end
    if not novo then novo = escolherInicio(r) end
    if not novo then falha("andar fora da rota de fuga") return end
    R.idx = novo
    resetWp(t, p)
    w = r[R.idx]
  end

  local ultimo = (R.idx == #r)
  local prox = r[R.idx + 1]
  local muda = (prox ~= nil) and (prox.z ~= w.z)
  local raio
  if w.tipo == "usar" then
    raio = w.raio or 1
  elseif ultimo then
    raio = CFG.RAIO_SEGURO
  elseif muda then
    raio = 0
  else
    raio = w.raio or 1
  end

  if dist(p, w) <= raio then
    if w.tipo == "usar" then
      if t - R.ultimoUso >= 700 then
        R.ultimoUso = t
        R.usos = R.usos + 1
        usarTile(w)
      end
      if R.usos >= 1 and not muda then
        if ultimo then concluir() return end
        R.idx = R.idx + 1
        resetWp(t, p)
      end
      return
    end
    if ultimo then concluir() return end
    if not muda then
      R.idx = R.idx + 1
      resetWp(t, p)
      return
    end
    -- muda == true e já está no tile, mas o andar não mudou: cai na lógica de travamento
  end

  -- detecção de travamento: nunca desiste, só aumenta a insistência
  local u = R.ultimaPos
  if p.x ~= u.x or p.y ~= u.y or p.z ~= u.z then
    R.ultimaPos, R.ultimoMov = p, t
    if R.posTravou and (p.z ~= R.posTravou.z or dist(p, R.posTravou) >= 3) then
      R.tent, R.posTravou = 0, nil -- andou de verdade: recomeça a escada de tentativas
    end
  elseif t - R.ultimoMov > CFG.STUCK_MS then
    R.ultimoMov = t
    R.tent = R.tent + 1
    R.posTravou = p
    log("sem progresso no waypoint " .. R.idx .. " (tentativa " .. R.tent .. ")")
    desbloquear(w, p, t)
    if R.tent >= CFG.PULAR_APOS and prox and not muda and w.tipo ~= "usar"
       and prox.z == w.z and R.pulos < CFG.PULOS_MAX then
      R.pulos = R.pulos + 1
      R.idx = R.idx + 1
      resetWp(t, p)
      log("waypoint pulado (" .. R.pulos .. "/" .. CFG.PULOS_MAX .. ")")
      return
    end
  end

  caminhar(w, raio)
end

macro(100, function() if vivo() then tick() end end)

macro(50, function()
  if vivo() and ativa() then guarda() end
end)

macro(250, function()
  if vivo() and morto() then morreu() end
end)

---------------------------------------------------------------------
-- INÍCIO DA FUGA
---------------------------------------------------------------------
local function iniciarFuga(motivo)
  estado = "DETECTADA"
  atualizarUI()
  anunciar("INVASÃO DETECTADA (" .. tostring(motivo) .. ") — INICIANDO FUGA DE EMERGÊNCIA")
  pararHunt()

  local r = rotaAtiva()
  if #r == 0 then falha("rota de fuga vazia (grave ou configure os waypoints)") return end
  local idx = escolherInicio(r)
  if not idx then falha("nenhum waypoint da rota neste andar") return end

  local t = agora()
  R = { idx = idx, inicio = t, ultimaPos = posicao(), ultimoMov = t, tent = 0, usos = 0, pulos = 0, ultimoUso = 0 }
  estado = "FUGINDO"
  atualizarUI()
  log("fugindo a partir do waypoint " .. idx .. " de " .. #r)
end

---------------------------------------------------------------------
-- DETECÇÃO
---------------------------------------------------------------------
local buf = {}
local ultimoGatilho = -999999999
local ultimoAviso = -999999999

local function achar(junto)
  local palavras = {}
  for _, k in ipairs(CFG.PALAVRAS_INVASAO) do palavras[#palavras + 1] = norm(k) end
  for _, g in ipairs(listaGuilds()) do
    if string.find(junto, "daguild:[" .. g .. "]", 1, true) then
      local okPalavra = not CFG.EXIGIR_PALAVRA or #palavras == 0
      if not okPalavra then
        for _, k in ipairs(palavras) do
          if string.find(junto, k, 1, true) then okPalavra = true; break end
        end
      end
      if okPalavra then return g end
    end
  end
  return nil
end

local function achouDominio(junto)
  if not CFG.LIGAR_AO_DOMINIO then return false end
  local g = norm(CFG.DOMINIO_GUILD)
  if g == "" or not string.find(junto, "guild:[" .. g .. "]", 1, true) then return false end
  for _, k in ipairs(CFG.DOMINIO_EXCLUIR) do
    if string.find(junto, norm(k), 1, true) then return false end
  end
  for _, k in ipairs(CFG.DOMINIO_PALAVRAS) do
    if string.find(junto, norm(k), 1, true) then return true end
  end
  return false
end

local function processar(texto, teste)
  local t = agora()
  local n = norm(texto)
  buf[#buf + 1] = { t = t, s = n }
  while #buf > 0 and t - buf[1].t > CFG.JANELA_MSG_MS do table.remove(buf, 1) end

  if CFG.DEBUG_LOG and string.find(n, "guild:[", 1, true) then
    log("msg com guild: " .. tostring(texto))
  end

  local partes = {}
  for _, b in ipairs(buf) do partes[#partes + 1] = b.s end
  local junto = table.concat(partes)

  -- A guild do domínio retomou o Castle: encerra a fuga e religa a hunt
  if ativa() and achouDominio(junto) then
    buf = {}
    FC.liberar(true, "dominio")
    return
  end

  local g = achar(junto)
  if not g then return end

  local function ignorar(motivo)
    if t - ultimoAviso > 5000 then
      ultimoAviso = t
      anunciar("Invasão detectada mas IGNORADA: " .. motivo)
    end
  end

  if not teste then
    if not S.ligado then ignorar("fuga automática está OFF") return end
    if t - ultimoGatilho < CFG.REARME_MS then
      ignorar("mesma invasão já tratada há menos de " .. math.floor(CFG.REARME_MS / 1000) .. "s")
      return
    end
  end
  if estado ~= "NORMAL" then
    ignorar("estado atual é '" .. TXT[estado] .. "' — clique em Liberar hunt ou Cancelar fuga para rearmar")
    return
  end

  if not teste then ultimoGatilho = t end
  buf = {}
  iniciarFuga(g)
end

onTextMessage(function(mode, text)
  if vivo() and text and text ~= "" then processar(text, false) end
end)

if CFG.OUVIR_ONTALK and onTalk then
  onTalk(function(name, level, mode, text)
    if vivo() and text and text ~= "" then processar(text, false) end
  end)
end

if onPlayerHealthChange then
  onPlayerHealthChange(function(pct)
    if vivo() and pct and pct <= 0 then morreu() end
  end)
end

---------------------------------------------------------------------
-- API PÚBLICA / BOTÕES
---------------------------------------------------------------------
function FC.simular()
  if estado ~= "NORMAL" then log("já existe uma fuga em andamento/estado ativo; cancele ou libere primeiro") return end
  local g = listaGuilds()[1] or "united front"
  processar("[Castle24H] TESTE: invasão do Castle iniciada da guild:[" .. g .. "]", true)
end

function FC.cancelar()
  if estado == "NORMAL" and not S.bloqueado then return end
  S.bloqueado = false
  S.religouEm = nil
  estado = "NORMAL"
  ultimoGatilho = -999999999
  religarMacros()
  if CFG.RESTAURAR_AO_CANCELAR then
    if snap.cave and CaveBot and CaveBot.setOn then pcall(CaveBot.setOn) end
    if snap.target and TargetBot and TargetBot.setOn then pcall(TargetBot.setOn) end
  end
  anunciar("Fuga cancelada — voltou ao estado anterior")
  atualizarUI()
end

function FC.liberar(religar, motivo)
  if religar and S.bloqueado then
    log("religar automático BLOQUEADO (personagem morreu); use 'Liberar hunt' manualmente")
    return
  end
  if estado == "NORMAL" and not S.bloqueado then return end
  if not religar then
    S.bloqueado = false
    S.religouEm = nil
  end
  estado = "NORMAL"
  ultimoGatilho = -999999999
  religarMacros()
  if religar then
    S.religouEm = os.time()
    if snap.cave and CaveBot and CaveBot.setOn then pcall(CaveBot.setOn) end
    if snap.target and TargetBot and TargetBot.setOn then pcall(TargetBot.setOn) end
    if motivo == "dominio" then
      anunciar("Castle dominado de novo pela " .. tostring(CFG.DOMINIO_GUILD) .. " — CaveBot/TargetBot religados")
    else
      anunciar("Tempo em segurança concluído — CaveBot/TargetBot religados")
    end
  else
    anunciar("Hunt liberada manualmente — ligue o CaveBot/TargetBot quando quiser")
  end
  atualizarUI()
end

-- Timer: depois de X segundos em segurança, religa CaveBot/TargetBot (os que estavam ligados antes da fuga).
-- Útil para ataque falso. Não religa se o personagem morreu (S.bloqueado).
macro(500, function()
  if not vivo() or estado ~= "SEGURO" or not R.seguroEm or S.bloqueado then return end
  local seg = tonumber(S.religarSeg) or 0
  if seg <= 0 then return end
  local falta = math.ceil((seg * 1000 - (agora() - R.seguroEm)) / 1000)
  if falta <= 0 then FC.liberar(true, "timer") return end
  if lblEstado then
    pcall(function() lblEstado:setText("Estado: EM SEGURANÇA (religa em " .. falta .. "s)") end)
  end
end)

function FC.gravarWP()
  local p = posicao()
  if not p then return end
  S.rota[#S.rota + 1] = { x = p.x, y = p.y, z = p.z }
  log("WP gravado: " .. p.x .. "," .. p.y .. "," .. p.z)
  atualizarUI()
end

-- Fique ao lado da escada/teleporte/buraco, olhando para ele, e clique: grava o tile à frente.
function FC.gravarDegrau()
  local p = posicao()
  if not p then return end
  local ok, dir = pcall(function() return player:getDirection() end)
  local dx, dy = 0, 0
  if not ok then log("não foi possível ler a direção") return end
  if dir == 0 then dy = -1
  elseif dir == 1 then dx = 1
  elseif dir == 2 then dy = 1
  elseif dir == 3 then dx = -1
  else log("direção diagonal: ande/vire para N, L, S ou O e tente de novo") return end
  S.rota[#S.rota + 1] = { x = p.x + dx, y = p.y + dy, z = p.z, raio = 0 }
  log("degrau gravado: " .. (p.x + dx) .. "," .. (p.y + dy) .. "," .. p.z)
  atualizarUI()
end

function FC.limparRota()
  S.rota = {}
  log("rota gravada apagada")
  atualizarUI()
end

---------------------------------------------------------------------
-- INTERFACE (aba Cave, sem criar abas novas)
---------------------------------------------------------------------
local widgets = {}
local function reg(w) widgets[#widgets + 1] = w return w end
function FC.destruirUI()
  for _, w in ipairs(widgets) do pcall(function() w:destroy() end) end
  widgets = {}
end

local function montarUI()
  local tab = getTab and getTab("Cave") or nil
  if tab then
    setDefaultTab("Cave")
  else
    log("aba Cave não encontrada; a interface ficará na aba atual")
  end
  reg(UI.Separator())
  reg(UI.Label("FUGA CASTLE v" .. VERSAO))
  btnLigar = reg(UI.Button("", function() S.ligado = not S.ligado; atualizarUI() end))
  lblEstado = reg(UI.Label(""))
  reg(UI.Label("Guilds monitoradas (separe por vírgula):"))
  reg(UI.TextEdit(S.guilds, function(_, texto) S.guilds = texto end))
  reg(UI.Label("Religar hunt após X seg em segurança (0 = manual):"))
  reg(UI.TextEdit(tostring(S.religarSeg), function(_, texto) S.religarSeg = tonumber(texto) or 0 end))
  reg(UI.Button("Testar fuga (simular invasão)", function() FC.simular() end))
  reg(UI.Button("Cancelar fuga", function() FC.cancelar() end))
  reg(UI.Button("Liberar hunt (manual)", function() FC.liberar() end))
  lblRota = reg(UI.Label(""))
  reg(UI.Button("Gravar WP aqui", function() FC.gravarWP() end))
  reg(UI.Button("Gravar degrau à frente", function() FC.gravarDegrau() end))
  reg(UI.Button("Limpar rota gravada", function() FC.limparRota() end))
  reg(UI.Separator())
  atualizarUI()
end

---------------------------------------------------------------------
-- AUTO-RECARGA: detecta o arquivo salvo e recarrega a si mesmo
---------------------------------------------------------------------
local baseArquivo, avisoRecarga, avisoPath = nil, -999999999, false

local function caminhoScript()
  local ok, nome = pcall(function() return modules.game_bot.contentsPanel.config:getCurrentOption().text end)
  if ok and nome then return "/bot/" .. nome .. "/" .. CFG.ARQUIVO end
  return nil
end

macro(2000, function()
  if not vivo() or not CFG.AUTO_RECARGA then return end
  local path = caminhoScript()
  if not path then return end
  local ok, c = pcall(g_resources.readFileContents, path)
  if not ok or not c or c == "" then
    if not avisoPath then
      avisoPath = true
      log("auto-recarga: não consegui ler " .. path .. " (ajuste CFG.ARQUIVO ou desligue AUTO_RECARGA)")
    end
    return
  end
  if not baseArquivo then baseArquivo = c return end
  if c == baseArquivo then return end

  local t = agora()
  if estado ~= "NORMAL" then
    if t - avisoRecarga > 30000 then
      avisoRecarga = t
      log("arquivo alterado; recarrego quando a fuga voltar ao HUNT NORMAL")
    end
    return
  end

  baseArquivo = c
  local f, err = loadstring(c, "fuga_castle.lua")
  if not f then
    anunciar("Auto-recarga: ERRO DE SINTAXE, mantendo a versão anterior: " .. tostring(err))
    return
  end
  pcall(setfenv, f, getfenv(1))
  local ok2, err2 = pcall(f)
  if ok2 then
    log("script recarregado automaticamente")
  else
    anunciar("Auto-recarga: erro ao executar a nova versão: " .. tostring(err2))
  end
end)

local okUI, errUI = pcall(montarUI)
if not okUI then log("falha ao montar a interface: " .. tostring(errUI)) end

if S.bloqueado then
  anunciar("Você morreu na última invasão — hunt automática BLOQUEADA. Clique em 'Liberar hunt (manual)' para reativar.")
end

---------------------------------------------------------------------
-- DIAGNÓSTICO (cole este bloco do console se algo não funcionar)
---------------------------------------------------------------------
do
  local itens = {
    { "CaveBot", CaveBot }, { "CaveBot.setOff", CaveBot and CaveBot.setOff },
    { "CaveBot.isOn", CaveBot and CaveBot.isOn }, { "CaveBot.walkTo", CaveBot and CaveBot.walkTo },
    { "TargetBot", TargetBot }, { "TargetBot.setOff", TargetBot and TargetBot.setOff },
    { "autoWalk", autoWalk }, { "say", say }, { "useWith", useWith },
    { "getTab", getTab }, { "UI.TextEdit", UI and UI.TextEdit }, { "onTextMessage", onTextMessage },
    { "storage", storage }, { "g_game.cancelAttack", g_game and g_game.cancelAttack },
  }
  local faltam = {}
  for _, it in ipairs(itens) do
    if not it[2] then faltam[#faltam + 1] = it[1] end
  end
  if #faltam == 0 then
    log("versão " .. VERSAO .. " — diagnóstico: todas as funções necessárias encontradas")
  else
    log("versão " .. VERSAO .. " — diagnóstico: FALTAM -> " .. table.concat(faltam, ", "))
  end
  if #rotaAtiva() == 0 then
    log("ATENÇÃO: rota de fuga vazia. Grave os waypoints na aba Cave antes de depender do sistema.")
  end
end

--[[FUGA_CASTLE_FIM]]
