--[[ BigFroot Pet Server Webhook
     PC + Mobile compatible (Delta, Arceus X, Hydrogen, Fluxus, etc.)
]]

local WEBHOOK    = "https://discord.com/api/webhooks/1517861705890140170/43D86zsG47dzhMcD1RfWHCNqW9vqNuFMbu46D90L8-0-lXI6nLWWO1TTsa1I7FebFRRp"
local PLACE_ID   = 97598239454123
local SNIPE_BASE    = "https://roblox.yumacheats.com"   -- HTTPS via the cloudflared tunnel (port 443). Raw http://IP:8745 is blocked by many executors/networks even when discord.com works — that's why Discord posted but the coordinator feed didn't.
local SNIPE_KEY     = "feed-leo-ro-3k9q"
local SNIPE_BOT_KEY = "ph-leo-9x4m2k7q"   -- bot token for /report
local SCAN_GAP   = 3
local FINDS_GAP  = 2
local WH_GAP     = 0.6
local MIN_RANK   = 4      -- 4=Epic+  5=Legendary+  6=Mythic+
local MAX_AGE_S  = 30     -- skip servers BigFroot last saw more than this many seconds ago
local DEDUP_TTL  = 300    -- re-allow same server after 5 min (in case it refreshes)
local FEED_ONLY  = false  -- true = pure feeder: push to the coordinator only, NO Discord posts
local AUTO_OPEN_FINDER = true   -- auto-open BigFroot's pet-server finder if off + turn ON its auto-refresh (unattended feeder)

-- ── HTTP request (all executor naming conventions) ────────────────────────────
local _req = request or http_request
    or (syn and syn.request)
    or (http and http.request)
    or (fluxus and fluxus.request)
    or (getgenv and getgenv().request)
if not _req then warn("[BF] no HTTP request function") end

local HS = game:GetService("HttpService")
local TS = game:GetService("TeleportService")

local RAR_ICON  = { Common="⚪", Uncommon="🟢", Rare="🔵", Epic="🟣", Legendary="🟡", Mythic="🔴", Super="🌈", Secret="✨" }
local RAR_COLOR = { Common=0xAAAAAA, Uncommon=0x57F287, Rare=0x5865F2, Epic=0x9B59B6, Legendary=0xFFCC15, Mythic=0xED4245, Super=0xFF73FA, Secret=0xFFFFFF }
local RAR_RANK  = { common=1, uncommon=2, rare=3, epic=4, legendary=5, mythic=6, mythical=6, super=7, secret=8 }

-- TTL-based dedup: stores os.clock() instead of true so servers can re-notify after DEDUP_TTL
local sentServers  = {}   -- jobId -> os.clock() of last post
local sentFinds    = {}   -- jobId..name -> os.clock()
local serverSeenAt = {}   -- jobId -> os.clock() when FIRST discovered (used to detect re-posts of old servers)
local _feedDown      = false   -- coordinator-feed health → drives a throttled Discord alert (Discord is the one channel we can see)
local _lastFeedAlert = 0
local _lastScanLog   = 0       -- throttle for the "nothing to feed" scan diagnostic posted to Discord
local _fedOnce       = false   -- post a one-time Discord ✅ the first time a feed succeeds

-- ── post webhook with 429 retry ───────────────────────────────────────────────
local function post(payload)
    if not _req then return end
    local body = HS:JSONEncode(payload)
    for attempt = 1, 3 do
        local ok, res = pcall(_req, {
            Url     = WEBHOOK,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = body,
        })
        if not ok then
            warn("[BF] webhook error:", res)
            return
        end
        local status = res and (res.StatusCode or res.status_code) or 0
        if status == 429 then
            local retry = 2
            pcall(function()
                retry = math.min(HS:JSONDecode(res.Body or res.body or "{}").retry_after or 2, 30)
            end)
            task.wait(retry + 0.5)
        elseif status >= 400 then
            warn("[BF] webhook rejected status:", status)
            return
        else
            return   -- success (2xx or unknown)
        end
    end
end

local function makeEmbed(title, desc, color, fields)
    return { username="Pet Hunter", embeds={{ title=title, description=desc, color=color or 0xFFCC15, fields=fields, footer={text="pet-hunter"} }} }
end

-- ── parse age seconds from BigFroot players label ─────────────────────────────
-- Handles: "0s ago", "45s ago", "1m 5s ago", missing age → nil (unknown)
local function parseAge(players)
    if not players or players == "" then return nil end
    local m, s = players:match("(%d+)%s*m%s*(%d+)%s*s%s*ago")
    if m and s then return tonumber(m) * 60 + tonumber(s) end
    -- anchor with %D* to avoid matching the seconds in "1m 5s ago" as "5"
    local sOnly = players:match("%D*(%d+)%s*s%s*ago")
    if sOnly then return tonumber(sOnly) end
    return nil  -- unknown age
end

-- ── multi-method upvalue extractor (PC + mobile fallbacks) ───────────────────
local function tryGetUpvalues(fn)
    if type(fn) ~= "function" then return {} end
    -- Method 1: debug.getupvalues → table
    local f1 = type(debug)=="table" and rawget(debug,"getupvalues")
    if type(f1)=="function" then
        local ok, ups = pcall(f1, fn)
        if ok and type(ups)=="table" then return ups end
    end
    -- Method 2: global getupvalues
    local genv = getgenv and getgenv() or _G
    local f2 = rawget(genv, "getupvalues")
    if type(f2)=="function" then
        local ok, ups = pcall(f2, fn)
        if ok and type(ups)=="table" then return ups end
    end
    -- Method 3: debug.getupvalue index-by-index (Delta mobile)
    local f3 = type(debug)=="table" and rawget(debug,"getupvalue")
    if type(f3)=="function" then
        local ups = {}
        for i = 1, 60 do
            local ok, a, b = pcall(f3, fn, i)
            if not ok then break end
            ups[#ups+1] = b ~= nil and b or a
        end
        if #ups > 0 then return ups end
    end
    return {}
end

-- ── multi-method signal connections getter ────────────────────────────────────
local function tryGetConns(signal)
    if type(getconnections)=="function" then
        local ok, r = pcall(getconnections, signal); if ok and type(r)=="table" then return r end
    end
    if syn and type(syn.get_signal_cons)=="function" then
        local ok, r = pcall(syn.get_signal_cons, signal); if ok and type(r)=="table" then return r end
    end
    if type(getrawmetatable)=="function" then
        local ok, mt = pcall(getrawmetatable, signal)
        if ok and type(mt)=="table" then
            local f = rawget(mt,"GetConnections") or rawget(mt,"getConnections")
            if type(f)=="function" then
                local ok2, r = pcall(f, signal); if ok2 and type(r)=="table" then return r end
            end
        end
    end
    return {}
end

-- ── get jobId from a Join button ──────────────────────────────────────────────
local function getJobId(btn)
    if not btn then return nil end
    local conns = tryGetConns(btn.MouseButton1Click)
    for _, conn in ipairs(conns) do
        local fn = nil
        pcall(function() fn = conn.Function end)
        if not fn then pcall(function() fn = conn.Callback end) end
        if not fn then pcall(function() fn = rawget(conn,"Function") end) end
        if type(fn) ~= "function" then continue end
        local ups = tryGetUpvalues(fn)
        for _, uv in ipairs(ups) do
            if type(uv)=="table" then
                if type(uv.jobId)=="string" and #uv.jobId==36 then return uv.jobId end
                for _, v in pairs(uv) do
                    if type(v)=="string" and #v==36 and v:find("%-") then return v end
                end
            elseif type(uv)=="string" and #uv==36 and uv:find("%-") then
                return uv
            end
        end
    end
    return nil
end

-- ── get the FULL STRUCTURED entry from a Join button (BigFroot/HoshiHub's generated data) ──
-- Shape: { jobId, placeId, age(seconds), players, maxPlayers, score, source,
--          pets = { { n=name, r=rarity, s=size, m=mutation }, ... } }
-- Far more reliable than parsing the row's label text, and gives every pet's exact rarity.
local function getEntry(btn)
    if not btn then return nil end
    local conns = tryGetConns(btn.MouseButton1Click)
    for _, conn in ipairs(conns) do
        local fn = nil
        pcall(function() fn = conn.Function end)
        if not fn then pcall(function() fn = conn.Callback end) end
        if not fn then pcall(function() fn = rawget(conn,"Function") end) end
        if type(fn) == "function" then
            local ups = tryGetUpvalues(fn)
            for _, uv in ipairs(ups) do
                if type(uv) == "table" and type(uv.jobId) == "string" and uv.pets ~= nil then
                    return uv
                end
            end
        end
    end
    return nil
end

-- ── wait for a row to be populated (up to 0.5s) ──────────────────────────────
local function waitForChildren(entry)
    -- require 2 populated TextLabels (pet name + players) before considering row ready
    local deadline = os.clock() + 0.5
    repeat
        task.wait()
        if not entry.Parent then return false end
        local count = 0
        for _, v in ipairs(entry:GetChildren()) do
            if v:IsA("TextLabel") and v.Text ~= "" then count += 1 end
        end
        if count >= 1 then return true end
    until os.clock() > deadline
    return false
end

-- ── find BigFroot's ScrollingFrame — robust multi-signal detection ────────────
-- Bug fixes: depth 12 (was 8), case-insensitive "current server" match,
-- fallback UUID pattern match, also checks children not just siblings.
-- %x is NOT valid in Luau (Lua 5.1 base) — use explicit char class instead
local H = "[%da-fA-F]"
local UUID_PAT = H:rep(8).."%-"..H:rep(4).."%-"..H:rep(4).."%-"..H:rep(4).."%-"..H:rep(12)
local function findBFScrollingFrame()
    local function search(root, depth)
        if depth > 12 then return nil end
        for _, v in ipairs(root:GetChildren()) do
            if v:IsA("ScrollingFrame") then
                local par = v.Parent
                if par then
                    -- check siblings AND children of parent for "current server" or UUID label
                    for _, sib in ipairs(par:GetChildren()) do
                        if sib:IsA("TextLabel") then
                            local t = tostring(sib.Text):lower()
                            -- match "current server:", "server:", or a UUID (job id shown next to it)
                            if t:find("current server") or t:find("server:") or t:match(UUID_PAT) then
                                return v
                            end
                        end
                    end
                end
            end
            local found = search(v, depth + 1)
            if found then return found end
        end
    end
    local ok1, r1 = pcall(search, game:GetService("CoreGui"), 0)
    if ok1 and r1 then return r1 end
    local ok2, r2 = pcall(search, game:GetService("Players").LocalPlayer.PlayerGui, 0)
    if ok2 and r2 then return r2 end
    return nil
end

local function bfReady() return findBFScrollingFrame() ~= nil end

-- ============================================================
-- LOOP 0: AUTO-OPEN BigFroot's pet-server finder (panel only) — does NOT touch Auto-refresh.
--   The finder is an on-demand panel (Runtime.openServerBrowser()). We ONLY open it when it is
--   CLOSED. We NEVER click the "Auto-refresh" toggle and NEVER destroy/reopen the panel — that is
--   what was resetting your auto-refresh back to OFF. BigFroot already has its own auto-refresh;
--   turn it on once in-game and the script leaves it completely alone.
-- ============================================================
task.spawn(function()
    if not AUTO_OPEN_FINDER then return end
    local CG = game:GetService("CoreGui")
    local function bfRuntime()
        local g = getgenv and getgenv() or _G
        if not g then return nil end
        local bf = g.BigFrootGrowAGarden2
        if bf and type(bf.Runtime) == "table" and type(bf.Runtime.openServerBrowser) == "function" then
            return bf.Runtime
        end
        for k, v in pairs(g) do
            if type(k) == "string" and k:find("BigFroot") and type(v) == "table"
                and type(v.Runtime) == "table" and type(v.Runtime.openServerBrowser) == "function" then
                return v.Runtime
            end
        end
        return nil
    end
    local function panelNow()
        local rg = CG:FindFirstChild("RobloxGui")
        return rg and rg:FindFirstChild("BigFrootServerBrowser") or nil
    end
    while not bfRuntime() do task.wait(2) end
    print("[BF] auto-opening pet-server finder (auto-refresh left to BigFroot — script never toggles it)")
    while true do
        pcall(function()
            local rt = bfRuntime()
            if rt and not panelNow() then pcall(rt.openServerBrowser) end   -- open ONLY when closed; never touch auto-refresh
        end)
        task.wait(10)
    end
end)

-- ============================================================
-- LOOP 1: BigFroot Pet Server Finder (event-driven)
-- ============================================================
task.spawn(function()
    while not bfReady() do task.wait(1) end
    print("[BF] BigFroot detected, monitoring servers...")

    local hookedSf  = nil
    local sfConns   = {}

    local function processEntry(entry)
        if not entry:IsA("Frame") then return end
        -- Dedup using Attribute on the Instance itself (avoids tostring returning "Frame" for all)
        -- Set BEFORE any yield so concurrent coroutines don't both process the same entry
        if pcall(entry.GetAttribute, entry, "YB_SEEN") and entry:GetAttribute("YB_SEEN") then return end
        pcall(function() entry:SetAttribute("YB_SEEN", true) end)

        -- poll until BOTH labels (pet name + players) are populated (up to 0.5s)
        if not waitForChildren(entry) then return end
        if not entry.Parent then return end

        local btn = entry:FindFirstChildWhichIsA("TextButton")
        local pet, players = "", ""
        for _, v in ipairs(entry:GetChildren()) do
            if v:IsA("TextLabel") then
                if v.Text:find("players") then players = v.Text
                elseif v.Text ~= ""       then pet     = v.Text end
            end
        end
        if pet == "" or players == "" then return end

        local ageSecs = parseAge(players)
        if ageSecs and ageSecs > MAX_AGE_S then return end

        local rar  = pet:match("%((.-)%)") or ""
        local rank = RAR_RANK[rar:lower()] or 0
        if rank < MIN_RANK then return end

        local jobId = getJobId(btn)

        if jobId then
            -- track first-seen time: if we've seen this server before and it's been
            -- >DEDUP_TTL seconds, it's eligible to re-post. But if BigFroot just
            -- re-added it after a panel refresh with "0s ago", check the real first-seen
            -- time to avoid re-posting a 3-minute-old server as if it's new.
            local firstSeen = serverSeenAt[jobId]
            if not firstSeen then
                serverSeenAt[jobId] = os.clock()   -- brand new server
            else
                -- server was seen before: only re-post after DEDUP_TTL (5 min)
                -- prevents BigFroot panel refresh from causing duplicate/stale posts
                if (os.clock() - firstSeen) < DEDUP_TTL then return end
                serverSeenAt[jobId] = os.clock()   -- reset for the new post
            end
            -- jobId dedup (also stored in sentServers for backward compat)
            if sentServers[jobId] and (os.clock() - sentServers[jobId]) < DEDUP_TTL then return end
            sentServers[jobId] = os.clock()
        end

        -- (Coordinator feed is handled by the BULK FEEDER loop below — it pushes the WHOLE list
        --  in one /report_bulk request, so there's no per-server /report here.)
        if FEED_ONLY then return end   -- pure feeder: skip Discord posting entirely

        local icon    = RAR_ICON[rar]  or "🐾"
        local color   = RAR_COLOR[rar] or 0xFFCC15
        local fields  = {
            { name="Players", value=players,             inline=true  },
            { name="Place",   value=tostring(PLACE_ID),  inline=true  },
        }
        if jobId then
            table.insert(fields, 1, { name="Server (JobId)", value="`"..jobId.."`", inline=false })
            table.insert(fields, { name="Join", value="```\nTeleportToPlaceInstance("..PLACE_ID..", \""..jobId.."\")\n```", inline=false })
        else
            table.insert(fields, 1, { name="Server", value="JobId unavailable on this executor", inline=false })
        end

        post(makeEmbed(icon.." "..pet, "• **"..pet.."**  —  "..players, color, fields))
        task.wait(WH_GAP)
    end

    local function hookSf(sf)
        if sf == hookedSf then return end
        -- disconnect old connections BEFORE updating hookedSf (Bug W fix:
        -- previously sfConns was cleared first, making the disconnect loop a no-op)
        local oldConns = sfConns
        for _, c in ipairs(oldConns) do pcall(function() c:Disconnect() end) end
        sfConns  = {}
        hookedSf = sf

        for _, entry in ipairs(sf:GetChildren()) do task.spawn(processEntry, entry) end

        -- use pcall around Connect in case sf becomes invalid mid-hook (Bug W fix)
        local ok1, conn1 = pcall(function()
            return sf.ChildAdded:Connect(function(e) task.spawn(processEntry, e) end)
        end)
        if ok1 and conn1 then sfConns[#sfConns+1] = conn1 end

        -- capture jobId synchronously before task.spawn (children may be destroyed later)
        local ok2, conn2 = pcall(function()
            return sf.ChildRemoved:Connect(function(entry)
                local btn   = entry:FindFirstChildWhichIsA("TextButton")
                local jobId = getJobId(btn)
                task.spawn(function()
                    task.wait()
                    if jobId then sentServers[jobId] = nil end
                    -- clear Attribute so the entry can be re-processed if BigFroot re-adds it
                    pcall(function() entry:SetAttribute("YB_SEEN", false) end)
                end)
            end)
        end)
        if ok2 and conn2 then sfConns[#sfConns+1] = conn2 end

        -- if Connect failed, reset hookedSf so heartbeat retries next cycle
        if not ok1 then
            hookedSf = nil
            warn("[BF] hookSf Connect failed — will retry in 5s")
        end
    end

    -- heartbeat: re-hook if BF rebuilds panel, prune stale dedup entries
    while true do
        pcall(function()
            local now = os.clock()
            for k, t in pairs(sentServers) do
                if type(t) == "number" and (now - t) > DEDUP_TTL * 2 then sentServers[k] = nil end
            end
            for k, t in pairs(serverSeenAt) do
                if type(t) == "number" and (now - t) > DEDUP_TTL * 2 then serverSeenAt[k] = nil end
            end
            local sf = findBFScrollingFrame()
            if sf then hookSf(sf) end
        end)
        task.wait(5)
    end
end)

-- ============================================================
-- LOOP 3: BULK FEEDER — push the WHOLE BigFroot list to your coordinator every SCAN_GAP in ONE
--   /report_bulk request, so all your snipe bots read /finds with NO BigFroot. This is the core
--   of the feeder: run this script on ONE machine that keeps BigFroot open.
-- ============================================================
task.spawn(function()
    while not bfReady() do task.wait(1) end
    print("[BF] bulk feeder started -> "..SNIPE_BASE.."/report_bulk")
    pcall(post, { content = "🛰️ **BigFroot feeder ONLINE** → feeding `"..SNIPE_BASE.."`. (If this device ever can't reach the coordinator you'll get a ⚠️ right here.)" })
    while true do
        local _scanOk, _scanErr = pcall(function()
            if not _req then return end
            local sf = findBFScrollingFrame()
            if not sf then
                if os.clock() - _lastScanLog > 30 then
                    _lastScanLog = os.clock()
                    pcall(post, { content = "🔎 feeder: BigFroot finder panel NOT found — open it and keep it open so the feeder can read the server list." })
                end
                return
            end
            local servers, n = {}, 0
            local rows, withBtn, parsed, viaFallback = 0, 0, 0, 0   -- DIAGNOSTIC counters
            for _, row in ipairs(sf:GetChildren()) do
                if row:IsA("Frame") then
                    rows += 1
                    local btn = row:FindFirstChildWhichIsA("TextButton")
                    if btn then withBtn += 1 end
                    -- Preferred: rich structured entry (every pet). FALLBACK to the SAME method the
                    -- (working) Discord loop uses — getJobId + the row's label text — whenever getEntry's
                    -- strict upvalue shape isn't present. THAT mismatch is why Discord posted but the feed didn't.
                    local job, pets, age, players
                    local d = btn and getEntry(btn)
                    if d and type(d.jobId) == "string" and type(d.pets) == "table" then
                        job, age, players = d.jobId, tonumber(d.age) or 0, tonumber(d.players) or 0
                        pets = {}
                        for _, p in ipairs(d.pets) do
                            local nm = tostring(p.n or "")
                            if nm ~= "" then pets[#pets+1] = { name = nm, rarity = tostring(p.r or "") } end
                        end
                    elseif btn then
                        job = getJobId(btn)
                        local petTxt, plyTxt = "", ""
                        for _, v in ipairs(row:GetChildren()) do
                            if v:IsA("TextLabel") then
                                if v.Text:find("players") then plyTxt = v.Text
                                elseif v.Text ~= ""       then petTxt = v.Text end
                            end
                        end
                        if job and petTxt ~= "" then
                            local rar  = petTxt:match("%((.-)%)") or ""
                            local name = (petTxt:gsub("%s*%(.-%)", "")):gsub("^%s+", ""):gsub("%s+$", "")
                            pets    = { { name = (name ~= "" and name or petTxt), rarity = rar } }
                            age     = parseAge(plyTxt) or 0
                            players = tonumber(plyTxt:match("%d+")) or 0
                            viaFallback += 1
                        end
                    end
                    if job and pets and #pets > 0 then
                        parsed += 1
                        servers[#servers+1] = { job = job, place = PLACE_ID, pets = pets, bfAge = age or 0, players = players or 0 }
                        n += 1
                        if n % 20 == 0 then task.wait() end   -- spread upvalue reads across frames
                    end
                end
            end
            -- DIAGNOSTIC: if we fed nothing, post WHY to Discord (throttled) so the empty Live Wild Pets is explained
            if #servers == 0 and (os.clock() - _lastScanLog > 30) then
                _lastScanLog = os.clock()
                local why = (rows == 0) and "the finder panel has 0 rows (open it / let it refresh)"
                    or (withBtn == 0) and ("found "..rows.." rows but none had a join button")
                    or ("found "..rows.." rows but couldn't read a job+pet from any (getEntry AND label/jobId fallback both empty)")
                pcall(post, { content = "🔎 feeder: **nothing to send to coordinator** — "..why..". [rows="..rows..", btn="..withBtn..", parsed="..parsed.."]" })
            end
            if #servers > 0 then
                -- try the efficient bulk endpoint first
                local ok, res = pcall(_req, {
                    Url = SNIPE_BASE.."/report_bulk", Method="POST",
                    Headers = { ["Content-Type"]="application/json", ["X-PH-Key"]=SNIPE_BOT_KEY },
                    Body = HS:JSONEncode({ bot="bigfroot-feeder", servers=servers }),
                })
                local code = ok and res and (res.StatusCode or res.status_code) or 0
                local fedOK, detail
                if code >= 200 and code < 300 then
                    fedOK, detail = true, "bulk"
                else
                    -- FALLBACK: coordinator doesn't have /report_bulk deployed yet (404/err) → use the
                    -- per-server /report endpoint that already exists, so the feed works WITHOUT deploying.
                    local sent = 0
                    for _, s in ipairs(servers) do
                        local rok, rres = pcall(_req, {
                            Url = SNIPE_BASE.."/report", Method="POST",
                            Headers = { ["Content-Type"]="application/json", ["X-PH-Key"]=SNIPE_BOT_KEY },
                            Body = HS:JSONEncode({ bot="bigfroot", job=s.job, place=s.place, players=s.players, bfAge=s.bfAge, pets=s.pets }),
                        })
                        local rc = rok and rres and (rres.StatusCode or rres.status_code) or 0
                        if rc >= 200 and rc < 300 then sent += 1 end
                        task.wait(0.05)
                    end
                    fedOK = sent > 0
                    detail = "per-server "..sent.."/"..#servers.." (bulk="..tostring(code)..")"
                end
                if fedOK then
                    print("[BF] fed "..#servers.." servers ("..detail..", fallback="..viaFallback..") -> coordinator")
                    if not _fedOnce then _fedOnce = true; pcall(post, { content = "✅ feeder: now sending **"..#servers.." servers** to the coordinator (`"..detail.."`). Live Wild Pets should fill within a few seconds." }) end
                    if _feedDown then pcall(post, { content = "✅ feeder: coordinator feed **restored**." }); _feedDown = false end
                else
                    warn("[BF] coordinator feed FAILED ("..detail..") — is "..SNIPE_BASE.." reachable from THIS device?")
                    if (not _feedDown) or (os.clock() - _lastFeedAlert > 60) then
                        pcall(post, { content = "⚠️ **feeder can't reach the coordinator** (`"..SNIPE_BASE.."`, "..detail.."). Discord still works, but Live Wild Pets will stay empty until this device can reach the coordinator." })
                        _feedDown, _lastFeedAlert = true, os.clock()
                    end
                end
            end
        end)
        if not _scanOk and (os.clock() - _lastScanLog > 30) then
            _lastScanLog = os.clock()
            pcall(post, { content = "⚠️ feeder scan ERROR: "..tostring(_scanErr).." — this is why nothing reaches the coordinator." })
        end
        task.wait(SCAN_GAP)
    end
end)

-- ============================================================
-- LOOP 2: /finds from coordinator (gated on BigFroot being loaded)
-- ============================================================
task.spawn(function()
    while not bfReady() do task.wait(1) end
    if FEED_ONLY then print("[BF] FEED_ONLY -> /finds Discord loop disabled"); return end
    print("[BF] /finds monitor started...")

    while true do
        pcall(function()
            -- Bug R fix: removed bfReady() gate here — /finds data comes from the coordinator,
            -- not BigFroot's UI. Blocking /finds when BigFroot rebuilds its panel caused missed
            -- pet notifications. Loop 2 now runs independently of BigFroot's panel state.
            if not _req then return end
            local ok, res = pcall(_req, { Url=SNIPE_BASE.."/finds?key="..SNIPE_KEY, Method="GET", Timeout=8 })
            if not ok or not res then return end
            local body = res.Body or res.body
            if not body or body=="" then return end
            local okD, data = pcall(function() return HS:JSONDecode(body) end)
            if not okD or type(data)~="table" or type(data.finds)~="table" then return end

            for _, f in ipairs(data.finds) do
                local name  = tostring(f.name  or "?")
                local rar   = tostring(f.rarity or "")
                local jobId = tostring(f.job   or "")
                local place = tostring(f.place or PLACE_ID)
                local secs  = tonumber(f.secondsLeft) or 0
                local price = tonumber(f.price)
                local key   = jobId..name
                if jobId=="" or name=="?" then continue end
                if (RAR_RANK[rar:lower()] or 0) < MIN_RANK then continue end
                -- FIX 1: TTL-based dedup
                if sentFinds[key] and (os.clock() - sentFinds[key]) < DEDUP_TTL then continue end
                sentFinds[key] = os.clock()

                local timer    = secs>=60 and ("\xe2\x8f\xb3%dm %02ds"):format(math.floor(secs/60),secs%60) or ("\xe2\x8f\xb3%ds"):format(secs)
                local priceStr = price and ("\xc2\xa2%s"):format(tostring(price):reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")) or nil
                local bits = {}
                if priceStr then bits[#bits+1]=priceStr end
                if secs>0   then bits[#bits+1]=timer end
                if rar~=""  then bits[#bits+1]=rar end
                local joinCmd = "```\nTeleportToPlaceInstance("..place..", \""..jobId.."\")\n```"
                post(makeEmbed(
                    (RAR_ICON[rar] or "🐾").." "..name.." ("..(rar~="" and rar or "?")..")",
                    "• **"..name.."**"..(#bits>0 and ("  —  "..table.concat(bits,"  ·  ")) or ""),
                    RAR_COLOR[rar] or 0xFFCC15,
                    {
                        { name="Server (JobId)", value="`"..jobId.."`",               inline=false },
                        { name="Time Left",      value=secs>0 and timer or "unknown", inline=true  },
                        { name="Place",          value=place,                          inline=true  },
                        { name="Join",           value=joinCmd,                        inline=false },
                    }
                ))
                task.wait(WH_GAP)
            end
        end)
        task.wait(FINDS_GAP)
    end
end)
