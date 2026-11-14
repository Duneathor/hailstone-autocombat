-- NPC faction consideration via Hailstone's OP_Consider packet, not chat text.
-- A server reply includes the target spawn ID and the faction tier, so it can
-- be attributed without changing the player's current target or parsing chat.
local M = {}

M.OPCODE = 0x742b -- RoF2 OP_Consider (Hailstone src/net/opcodes_rof2.inc)
M.CACHE_MS = 10 * 60 * 1000
M.MAX_ENTRIES = 128
M.REPLY_MS = 2000

M.TIERS = { "Scowling", "Threateningly", "Dubious", "Apprehensive", "Indifferent",
  "Amiably", "Kindly", "Warmly", "Ally" }

-- OP_Consider's faction field is 1=ally, 9=scowling (eqstr 12212..12220).
local WIRE_TIERS = { "Ally", "Warmly", "Kindly", "Amiably", "Indifferent",
  "Apprehensive", "Dubious", "Threateningly", "Scowling" }

local function normal(name)
  return (name or ""):lower():gsub("_", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.new() return { zone = nil, entries = {}, pending = nil, issued = {} } end

function M.set_zone(c, zone)
  if zone ~= c.zone then
    c.zone, c.entries, c.pending, c.issued = zone, {}, nil, {}
  end
end

-- NPC IDs are recycled. Match both the spawn ID and name, expire old results,
-- and keep the cache bounded so exploring a large zone cannot grow it forever.
function M.lookup(c, id, now, name)
  local entry = c.entries[id]
  if entry and now - entry.at >= 0 and now - entry.at < M.CACHE_MS
      and (not name or entry.name == normal(name)) then
    return entry.tier
  end
  c.entries[id] = nil
  return nil
end

local function store(c, id, name, tier, now)
  if not c.entries[id] then
    local count, oldest_id, oldest_at = 0, nil, math.huge
    for key, entry in pairs(c.entries) do
      if now - entry.at >= M.CACHE_MS then
        c.entries[key] = nil
      else
        count = count + 1
        if entry.at < oldest_at then oldest_id, oldest_at = key, entry.at end
      end
    end
    if count >= M.MAX_ENTRIES then c.entries[oldest_id] = nil end
  end
  c.entries[id] = { tier = tier, name = normal(name), at = now }
end

-- Request the server's faction for a specific NPC directly. No /target or
-- /consider command is needed. The 20-byte RoF2 request is five LE dwords:
-- player ID, target ID, faction=0, level=0, pvp_con+padding=0.
function M.request(c, id, name, now, player_id)
  for key, entry in pairs(c.issued) do
    if now - entry.at > M.REPLY_MS + 1000 then c.issued[key] = nil end
  end
  if type(id) ~= "number" or id <= 0 or type(player_id) ~= "number" or player_id <= 0 then return nil end
  c.pending = { id = id, name = name, player_id = player_id, at = now }
  c.issued[id] = { player_id = player_id, at = now }
  return string.pack("<I4I4I4I4I4", player_id, id, 0, 0, 0)
end

-- Called from hailstone.on_packet('zone', 'in', OP_Consider, fn). Only swallow
-- replies to OUR requests; manually issued /consider keeps its normal chat
-- output. Returns true to suppress the client's chat line for our packet.
function M.record_packet(c, opcode, data, now)
  if opcode ~= M.OPCODE or type(data) ~= "string" or #data < 20 then return false end
  local player_id, target_id, faction = string.unpack("<I4I4I4", data)
  local sent = c.issued[target_id]
  -- Some EQEmu derivatives zero the player field in the reply. The target
  -- spawn ID plus an outstanding recent request still identify OUR response.
  -- Do not accept an unrelated nonzero player ID.
  if not sent or (player_id ~= 0 and sent.player_id ~= player_id) then return false end
  local elapsed = now - sent.at
  if elapsed < 0 or elapsed > M.REPLY_MS + 1000 then
    c.issued[target_id] = nil
    return false
  end
  c.issued[target_id] = nil
  local p = c.pending
  if p and p.id == target_id and (player_id == 0 or p.player_id == player_id) then
    c.pending = nil
    if elapsed <= M.REPLY_MS then
      local tier = WIRE_TIERS[faction]
      if tier then store(c, target_id, p.name, tier, now) end
    end
  end
  return true
end

function M.cancel(c, discard)
  -- Keep an in-flight reply marker briefly on normal cancellation. If sending
  -- the request itself failed, nothing was sent, so remove the marker too.
  if discard and c.pending then c.issued[c.pending.id] = nil end
  c.pending = nil
end

-- All allowed is the compatibility default: there is no need to query mobs.
function M.none_enabled(filters)
  for _, tier in ipairs(M.TIERS) do
    if filters[tier] ~= false then return false end
  end
  return true
end

function M.restricted(filters)
  for _, tier in ipairs(M.TIERS) do
    if filters[tier] == false then return true end
  end
  return false
end

return M
