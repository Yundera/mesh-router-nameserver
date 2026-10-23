-- IP-encoded names (sslip.io / nip.io parity) for a LUA wildcard in ip.<zone>:
--   *.ip.<zone> LUA A    ";return ipname4()"
--   *.ip.<zone> LUA AAAA ";return ipname6()"
-- The leftmost IP wins. No IP in the name → empty answer (NOERROR, no data).
-- Only IPs the backend has registered are answered: it writes one allow record per
-- IP, <key>.allow.<zone>.invalid (A for IPv4, AAAA for IPv6), in a plain zone the
-- secondaries receive by transfer (Lua stays local, never transferred); key = the
-- dashed IPv4 ("1-2-3-4") or the 32-digit expanded IPv6 ("20010db8…0001").

-- Labels left of the zone, lowercased: "app-1-2-3-4.ip.nsl.sh." → "app-1-2-3-4"
local function prefix()
  local name = qname:toStringNoDot():lower()
  local zone = zone and zone:toStringNoDot():lower() or ""
  if #name > #zone and name:sub(-#zone - 1) == "." .. zone then
    return name:sub(1, -#zone - 2)
  end
  return name
end

local function zonename()
  return zone and zone:toStringNoDot():lower() or ""
end

local function allowed(key, qtype)
  local r = dblookup(key .. ".allow." .. zonename() .. ".invalid", qtype)
  return r ~= nil and #r > 0
end

local function octet(t)
  if not t:match("^%d%d?%d?$") then return nil end
  if #t > 1 and t:sub(1, 1) == "0" then return nil end
  local n = tonumber(t)
  if n > 255 then return nil end
  return n
end

-- Same rule as sslip.io: four octets joined by "-" (leftmost), else joined by "."
-- (leftmost), else one 8-digit hex token. Separators never mix inside one IP.
function ipname4()
  local tok, sep = {}, {}
  for t, s in (prefix() .. "."):gmatch("([^.-]+)([.-])") do
    tok[#tok + 1] = t
    sep[#sep + 1] = s
  end
  for _, want in ipairs({ "-", "." }) do
    for i = 1, #tok - 3 do
      if sep[i] == want and sep[i + 1] == want and sep[i + 2] == want
          and octet(tok[i]) and octet(tok[i + 1]) and octet(tok[i + 2]) and octet(tok[i + 3]) then
        local ip = tok[i] .. "." .. tok[i + 1] .. "." .. tok[i + 2] .. "." .. tok[i + 3]
        if allowed(ip:gsub("%.", "-"), pdns.A) then return ip end
        return {}
      end
    end
  end
  for i = 1, #tok do
    local h = tok[i]
    if #h == 8 and h:match("^%x+$") then
      local ip = tonumber(h:sub(1, 2), 16) .. "." .. tonumber(h:sub(3, 4), 16) .. "." ..
                 tonumber(h:sub(5, 6), 16) .. "." .. tonumber(h:sub(7, 8), 16)
      if allowed(ip:gsub("%.", "-"), pdns.A) then return ip end
      return {}
    end
  end
  return {}
end

-- "2001-bc8-3021--1" → "2001:bc8:3021::1" if it is a valid IPv6, else nil
local function v6(s)
  local text = s:gsub("-", ":")
  local head, tail = text:match("^(.-)::(.*)$")
  local groups = 0
  local function count(part)
    if part == "" then return true end
    for g in (part .. ":"):gmatch("(.-):") do
      if not g:match("^%x%x?%x?%x?$") then return false end
      groups = groups + 1
    end
    return true
  end
  if head then
    if tail:find("::", 1, true) then return nil end
    if not (count(head) and count(tail)) or groups > 7 then return nil end
  else
    if not count(text) or groups ~= 8 then return nil end
  end
  -- expanded key: 8 groups of 4 digits, "::" filled with zero groups
  local parts = {}
  local function add(part)
    if part == "" then return end
    for g in (part .. ":"):gmatch("(.-):") do parts[#parts + 1] = ("0000" .. g):sub(-4) end
  end
  if head then
    add(head)
    for _ = 1, 8 - groups do parts[#parts + 1] = "0000" end
    local tailparts = parts
    parts = {}
    add(tail)
    for _, g in ipairs(parts) do tailparts[#tailparts + 1] = g end
    parts = tailparts
  else
    add(text)
  end
  return text, table.concat(parts)
end

function ipname6()
  local p = prefix()
  -- an IPv6 sits inside one label; try every dash-boundary start, leftmost first,
  -- and every dash-boundary end, longest first
  for label in p:gmatch("[^.]+") do
    local starts = { 1 }
    for pos in label:gmatch("()%-") do starts[#starts + 1] = pos + 1 end
    for _, s in ipairs(starts) do
      local rest = label:sub(s)
      local ends = { #rest }
      for pos in rest:gmatch("()%-[^-]") do table.insert(ends, 2, pos - 1) end
      for _, e in ipairs(ends) do
        local ip, key = v6(rest:sub(1, e))
        if ip then
          if allowed(key, pdns.AAAA) then return ip end
          return {}
        end
      end
    end
  end
  return {}
end
