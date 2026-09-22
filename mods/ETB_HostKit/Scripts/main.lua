--[[
    ETB_HostKit - Escape The Backrooms 房主工具包 / UE4SS Lua

    仅需安装在房主所在机器上，其他玩家无需安装任何内容。

    功能：
      1. 12 人（可配置至 32 人）联机：改写建房会话槽位，并放宽游戏内人数上限与大厅滑块
      2. 全员同时过关：一键集合 / 一键将所有人送进出口区域 / 自动护送掉队玩家
      3. 选关与跳关：上一关 / 下一关、直接跳转至指定关卡（ServerTravel 携带全队）、
         跳过当前关卡（走游戏原有的出口结算流程，全员计为过关）
      4. 所有操作均提供屏幕提示（PrintString），并可通过桌面端的房主控制台点击执行

    稳定性要点（均为实测结论）：
      * 本作为定制版 UE4.27，UE4SS 默认开启的 HookProcessLocalScriptFunction /
        HookInitGameState / HookBeginPlay / HookLocalPlayerExec 会破坏堆内存并导致闪退，
        必须在 UE4SS-settings.ini 中关闭（安装脚本已自动写入），仅保留
        HookProcessInternal 与 HookCallFunctionByNameWithArguments。
      * 定时器回调复用固定的函数对象，不在循环内新建闭包。
      * 不执行 ForEachUObject 全对象遍历与逐对象属性试探：实测该做法会使 UE4SS
        读到非法内存，并在数十秒后以 EXCEPTION_ACCESS_VIOLATION 崩溃。
        查找出口区域仅按类名使用 FindAllOf。
      * 读取游戏对象的代码一律只在游戏线程（帧钩子）中执行，后台线程仅访问文件。
]]

local MOD_NAME = "ETB_HostKit"

-- ============================ 配置区 ============================
local CONFIG = {
    max_players = 12,               -- 目标人数（含房主），2-32
    public_connections_param = 4,   -- CreateAdvancedSession 里 PublicConnections 的位置
    enforce_gamestate_max = true,   -- 强制 Lobby_GS / MP_GameState 的 MaxPlayers
    patch_ui_slider = true,         -- 把大厅人数滑块上限抬到 max_players
    slider_default_value = 12,
    screen_notify = true,           -- 屏幕提示（已实测安全）
    assist = {
        enabled = false,
        grace_seconds = 15,         -- 掉队持续多久后拉回（检查间隔见 ASSIST_INTERVAL）
    },

    -- 关卡顺序（战役推进顺序，选关按此列表顺序进行）
    levels = {
        "/Game/Maps/Level0", -- Level 0
        "/Game/Maps/Garage/TopFloor", -- Habitable Zone
        "/Game/Maps/Pipes", -- Pipe Dreams
        "/Game/Maps/ElectricalStation", -- Electrical Station
        "/Game/Maps/Office", -- Abandoned Office
        "/Game/Maps/Hotel", -- Terror Hotel
        "/Game/Maps/LevelFun", -- Level Fun
        "/Game/Maps/Poolrooms", -- Poolrooms
        "/Game/Maps/LevelRun", -- Level Run
        "/Game/Maps/TheEnd", -- The End
        "/Game/Maps/Level94", -- Level 94
        "/Game/Maps/LightsOut", -- Lights Out
        "/Game/Maps/OceanMap", -- Ocean Map
        "/Game/Maps/CaveLevel", -- Cave Level
        "/Game/Maps/Level05", -- Level 05
        "/Game/Maps/Level9", -- Level 9
        "/Game/Maps/Level10", -- Level 10
        "/Game/Maps/Level3999", -- Level 3999
        "/Game/Maps/Level07", -- Level 07
        "/Game/Maps/Snackrooms", -- Snackrooms
        "/Game/Maps/LevelDash", -- Level Dash
        "/Game/Maps/Level188_Expanded", -- Level 188
        "/Game/Maps/Poolrooms_Expanded", -- Poolrooms Expanded
        "/Game/Maps/LevelFun_Expanded", -- Level Fun Expanded
        "/Game/Maps/Level52", -- Level 52
        "/Game/Maps/TunnelLevel", -- Tunnel
        "/Game/Maps/Bunker", -- Bunker
        "/Game/Maps/Level922", -- Level 922
        "/Game/Maps/Level974", -- Level 974
        "/Game/Maps/GraffitiLevel", -- Graffiti Level
        "/Game/Maps/Grassrooms_Expanded", -- Grassrooms
        "/Game/Maps/LP_LevelPlasticMariana", -- Plastic Mariana
        "/Game/Maps/AnimatedKingdom", -- Animated Kingdom
        "/Game/Maps/TheHub", -- The Hub
        "/Game/Maps/AbandonedBase", -- Abandoned Base
    },
}
-- ========================== 配置区结束 ==========================

local UEHelpers = require("UEHelpers")
local PATHS_OK, GAME_PATHS = pcall(require, "GamePaths")

local HOOK_PATH = "/Script/AdvancedSessions.CreateSessionCallbackProxyAdvanced:CreateAdvancedSession"
local HOOK_REGISTERED = false
local HOOK_FIRED = false
local assist_ticks = 0
local assist_far_since = {}      -- 掉队计时：pawn 地址 -> 第一次被判定掉队的 tick
local slider_done = false
local selected_level = 1
local last_event = "idle"
local last_travel_time = 0
local TRAVEL_COOLDOWN = 10
local cached_exit_zone = nil      -- 出口区域缓存（切图后自动作废）
local cached_exit_level = nil
local panel_seq = 0               -- 面板命令序号，面板据此确认命令已执行
local last_ack = ""               -- 最后一次执行的命令名
local travel_pending_since = 0
-- 面板状态回写：实现位于下方的「面板通信」一节，此处先声明，
-- 以免前面引用它的函数将其视为全局变量（nil）。
local write_state = nil

local KismetSystemLibrary = nil
local notify_variant = nil

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- 以 pcall 包裹，出错时写入日志（静默吞掉错误最难排查）
local function safe(label, fn)
    local ok, err = pcall(fn)
    if not ok then log("error in %s: %s", tostring(label), tostring(err)) end
    return ok
end

local function ksl()
    if not KismetSystemLibrary or not KismetSystemLibrary:IsValid() then
        KismetSystemLibrary = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    if KismetSystemLibrary and KismetSystemLibrary:IsValid() then return KismetSystemLibrary end
    return nil
end

-- ---------------------------------------------------------------- 基础查询
local function get_pc()
    local ok, pc = pcall(UEHelpers.GetPlayerController)
    if ok and pc and pc:IsValid() then return pc end
    for _, controller in pairs(FindAllOf("PlayerController") or {}) do
        if controller:IsValid() then
            local pawn = controller.Pawn
            if pawn and pawn:IsValid() then return controller end
        end
    end
    return nil
end

local function get_pawn()
    local pc = get_pc()
    if not pc then return nil end
    local pawn = pc.Pawn
    if pawn and pawn:IsValid() then return pawn end
    return nil
end

local function get_world()
    local pc = get_pc()
    if not pc then return nil end
    local ok, world = pcall(function() return pc:GetWorld() end)
    if ok and world and world:IsValid() then return world end
    return nil
end

local function is_host()
    local world = get_world()
    if not world then return false end
    local ok, game_mode = pcall(function() return world.AuthorityGameMode end)
    if ok and game_mode and game_mode:IsValid() then return true end
    local ok2, net_mode = pcall(function() return world.NetMode end)
    if ok2 and type(net_mode) == "number" then return net_mode == 0 or net_mode == 2 end
    return false
end

local function gameplay_statics()
    local object = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if object and object:IsValid() then return object end
    local ok, helper = pcall(UEHelpers.GetGameplayStatics)
    if ok and helper and helper:IsValid() then return helper end
    return nil
end

local function current_level()
    local world = get_world()
    if world then
        local ok, name = pcall(function() return world:GetFName() end)
        if ok and name then
            local ok2, text = pcall(function() return name:ToString() end)
            if ok2 and text then return text end
        end
    end
    local statics = gameplay_statics()
    local pc = get_pc()
    if statics and pc then
        local ok, name = pcall(function() return statics:GetCurrentLevelName(pc, true) end)
        if ok and name then
            if type(name) == "userdata" then
                local ok2, text = pcall(function() return name:ToString() end)
                if ok2 and text then return text end
            elseif type(name) == "string" then
                return name
            end
        end
    end
    return nil
end

-- 关卡路径 -> 短名（/Game/Maps/Garage/TopFloor -> TopFloor）
local function short_name(level_path)
    if not level_path then return nil end
    return (tostring(level_path):match("([^/]+)$"))
end

-- 短名 -> 列表里的完整路径（已经是完整路径则原样返回，找不到返回 nil）
local function resolve_level(name)
    if not name or name == "" then return nil end
    local text = tostring(name)
    for _, path in ipairs(CONFIG.levels) do
        if string.lower(path) == string.lower(text) then return path end
    end
    local wanted = string.lower(short_name(text))
    for _, path in ipairs(CONFIG.levels) do
        if string.lower(short_name(path)) == wanted then return path end
    end
    return nil
end

-- 屏幕提示 + 日志
local function notify(text)
    log("%s", text)
    if not CONFIG.screen_notify then return end
    local pc = get_pc()
    local library = ksl()
    if not pc or not library then return end
    local variants = {
        function() library:PrintString(pc, text, true, true, nil, 4.0) end,
        function() library:PrintString(pc, text, true, true) end,
        function() library:PrintString(pc, text, true) end,
    }
    if notify_variant then
        if pcall(variants[notify_variant]) then return end
        notify_variant = nil
    end
    for index, variant in ipairs(variants) do
        if pcall(variant) then
            notify_variant = index
            return
        end
    end
end

local function host_only(label)
    if is_host() then return true end
    notify("host only: " .. label)
    return false
end

-- ====================== 1. 会话槽位 / 人数上限 ======================

local function force_player_cap_param(params)
    local target = CONFIG.max_players
    local param = params[CONFIG.public_connections_param]
    if param then
        local ok, value = pcall(function() return param:get() end)
        if ok and type(value) == "number" and value >= 1 and value <= 64 then
            if value ~= target and pcall(function() param:set(target) end) then
                HOOK_FIRED = true
                log("session param #%d: PublicConnections %s -> %d",
                    CONFIG.public_connections_param, tostring(value), target)
            elseif value == target then
                HOOK_FIRED = true
                log("session param #%d already %d", CONFIG.public_connections_param, target)
            end
            return
        end
    end
    for i, candidate in ipairs(params) do
        local ok, value = pcall(function() return candidate:get() end)
        if ok and type(value) == "number" and value >= 2 and value <= 8 and value ~= target then
            if pcall(function() candidate:set(target) end) then
                HOOK_FIRED = true
                log("fallback rewrite param #%d: %s -> %d", i, tostring(value), target)
                return
            end
        end
    end
    log("warning: no player-cap parameter found")
end

local function session_hook_callback(_, ...)
    local success, err = pcall(force_player_cap_param, { ... })
    if not success then log("hook error: %s", tostring(err)) end
end

local function install_session_hook()
    local ok = pcall(RegisterHook, HOOK_PATH, session_hook_callback)
    if ok then
        HOOK_REGISTERED = true
        log("hooked %s", HOOK_PATH)
    end
    return ok
end

local function enforce_max_players()
    if not CONFIG.enforce_gamestate_max then return end
    for _, class_name in ipairs({ "Lobby_GS_C", "MP_GameState_C" }) do
        for _, state in pairs(FindAllOf(class_name) or {}) do
            if state:IsValid() then
                local ok, value = pcall(function() return state.MaxPlayers end)
                if ok and type(value) == "number" and value ~= CONFIG.max_players then
                    if pcall(function() state.MaxPlayers = CONFIG.max_players end) then
                        log("%s.MaxPlayers %d -> %d", class_name, value, CONFIG.max_players)
                    end
                end
            end
        end
    end
end

local function patch_sliders()
    if not CONFIG.patch_ui_slider then return end
    for _, class_name in ipairs({ "UI_Menu_ModeSelection_C", "W_CreateServer_C" }) do
        for _, widget in pairs(FindAllOf(class_name) or {}) do
            if widget:IsValid() then
                local ok, slider = pcall(function() return widget.Slider_MaxPlayers end)
                if ok and slider and slider:IsValid() then
                    local ok_max, max_value = pcall(function() return slider.MaxValue end)
                    if ok_max and type(max_value) == "number" and max_value < CONFIG.max_players then
                        pcall(function() slider:SetMaxValue(CONFIG.max_players) end)
                        pcall(function() slider.MaxValue = CONFIG.max_players end)
                        log("%s slider max -> %d", class_name, CONFIG.max_players)
                    end
                    if not slider_done then
                        pcall(function() slider:SetValue(CONFIG.slider_default_value) end)
                        slider_done = true
                    end
                end
            end
        end
    end
end

-- ====================== 2. 集合 / 全员进出口 ======================

local function root_component(actor)
    if not actor or not actor:IsValid() then return nil end
    local ok, comp = pcall(function() return actor.RootComponent end)
    if ok and comp and comp:IsValid() then return comp end
    return nil
end

local function get_location(actor)
    if not actor or not actor:IsValid() then return nil end
    local ok, location = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and location then return location end
    local comp = root_component(actor)
    if comp then
        local ok2, location2 = pcall(function() return comp.RelativeLocation end)
        if ok2 then return location2 end
    end
    return nil
end

local function teleport_to(pawn, vector)
    if not pawn or not pawn:IsValid() or not vector then return false end
    local before = get_location(pawn)
    local function arrived()
        local after = get_location(pawn)
        if not after or not before then return false end
        local ok, dx = pcall(function() return after.X - vector.X end)
        if not ok then return true end -- 读取失败时视为成功，避免误判
        local dy, dz = after.Y - vector.Y, after.Z - vector.Z
        return (dx * dx + dy * dy + dz * dz) < 40000 -- 距离小于 200 单位视为已到位
    end
    -- 1) 角色专用 TeleportTo（对 Character 最可靠）
    local ok_rot, rotation = pcall(function() return pawn:K2_GetActorRotation() end)
    if ok_rot and pcall(function() pawn:K2_TeleportTo(vector, rotation) end) and arrived() then
        return true
    end
    -- 2) K2_SetActorLocation
    if pcall(function() pawn:K2_SetActorLocation(vector, false, nil, true) end) and arrived() then
        return true
    end
    -- 3) 直接写入根组件坐标（仅保证服务端坐标；客户端是否同步取决于 CharacterMovement）
    local comp = root_component(pawn)
    if comp and pcall(function() comp.RelativeLocation = vector end) and arrived() then
        log("teleport: %s via RelativeLocation fallback (server-side only)", tostring(pawn:GetFullName()))
        return true
    end
    return false
end

local function all_pawns()
    local pawns = {}
    for _, controller in pairs(FindAllOf("PlayerController") or {}) do
        if controller:IsValid() then
            local pawn = controller.Pawn
            if pawn and pawn:IsValid() then pawns[#pawns + 1] = pawn end
        end
    end
    return pawns
end

local function gather_at(anchor, label)
    local target = get_location(anchor)
    if not target then
        notify("cannot read target position")
        return
    end
    local moved, total = 0, 0
    for _, pawn in ipairs(all_pawns()) do
        total = total + 1
        if pawn:GetAddress() ~= anchor:GetAddress() then
            if teleport_to(pawn, target) then moved = moved + 1 end
        end
    end
    notify(string.format("%s: %d/%d players moved", label, moved + 1, total))
end

-- 出口 / 过关区域的蓝图类名（依据游戏 pak 中的实际资源名整理），按优先级排列。
-- 仅按类名精确查找，不进行全对象遍历 —— 后者会使 UE4SS 读取非法内存并导致游戏崩溃。
local EXIT_ZONE_CLASSES = {
    "BP_ExitZone_GameEnding_C",
    "BP_ExitZone_GameEnding_TunnelLevel_C",
    "BP_ExitZoneLightsOut_C",
    "BP_ExitZone_Basement_C",
    "BP_ExitZone_ToCave_C",
    "BP_ExitZone_922_C",
    "BP_ExitZone_974_C",
    "BP_ExitZone_Cheat_C",
    "BP_ExitZone_C",
    "BP_Fun_Exit_Zone_C",
    "BP_Exit_Gate_C",
    "BP_ExitDoor_C",
    "BP_EndingsDoor_C",
    "BP_Exit_C",
    "BP_Level0Exit_C",
    "BP_HotelExit_C",
    "BP_StationExit_C",
    "Pipe_Exit_C",
    "BP_ElectricalExit_C",
    "BP_RunExit_C",
    "BP_CaveExit_C",
    "BP_Ocean_Exit_C",
    "BP_Snackrooms_Exit_C",
    "BP_Level11_Exit_C",
    "BP_Lobby_Exit_C",
    "BP_FallExit_C",
    "BP_Vent_Exit_C",
    "BP_HideExitVolume_C",
    "BP_Grassrooms_Exit_Door_C",
    "BP_Elevator_Level07_Exit_C",
}

local function format_vector(vector)
    if not vector then return "(?)" end
    local ok, x = pcall(function() return vector.X end)
    if ok and x then return string.format("(%.0f, %.0f, %.0f)", vector.X, vector.Y, vector.Z) end
    return "(?)"
end

-- 查找当前关卡中的出口 / 过关区域：仅按类名 FindAllOf（快速且安全），并缓存结果。
-- 切换地图后 current_level() 变化，缓存自动失效。
local function find_exit_zone()
    local level = current_level()
    if cached_exit_zone and cached_exit_level == level and cached_exit_zone:IsValid() then
        return cached_exit_zone
    end
    cached_exit_zone, cached_exit_level = nil, nil
    local loaded = {}
    for _, class_name in ipairs(EXIT_ZONE_CLASSES) do
        local found = FindAllOf(class_name)
        if found then
            for _, zone in pairs(found) do
                if zone:IsValid() then
                    if not cached_exit_zone then
                        cached_exit_zone = zone
                        cached_exit_level = level
                        log("exit zone: %s @ %s", class_name, format_vector(get_location(zone)))
                    end
                    loaded[#loaded + 1] = class_name
                end
            end
        end
    end
    if not cached_exit_zone then
        log("exit zone: none loaded (checked %d class names, level=%s)",
            #EXIT_ZONE_CLASSES, tostring(level))
    elseif #loaded > 1 then
        log("exit zone: %d candidates loaded: %s", #loaded, table.concat(loaded, ", "))
    end
    return cached_exit_zone
end

local function push_everyone_to_exit()
    local zone = find_exit_zone()
    if not zone then
        last_event = "no_exit_zone"
        notify("no exit zone in this level - see log")
        return false
    end
    local target = get_location(zone)
    if not target then
        last_event = "no_exit_position"
        notify("exit zone found but position unreadable - see log")
        return false
    end
    local moved, total, failed = 0, 0, {}
    for _, pawn in ipairs(all_pawns()) do
        total = total + 1
        if teleport_to(pawn, target) then
            moved = moved + 1
        else
            failed[#failed + 1] = tostring(pawn:GetFullName())
        end
    end
    log("push to exit: %d/%d moved, target %s", moved, total, format_vector(target))
    for _, name in ipairs(failed) do log("  failed: %s", name) end
    last_event = (moved > 0) and "ok_exit" or "exit_teleport_failed"
    notify(string.format("exit: %d/%d players moved", moved, total))
    return moved > 0
end

-- 掉队自动拉人：以房主所在位置为集结点。每 ASSIST_INTERVAL 秒检查一次，
-- 与房主距离超过 ASSIST_RADIUS 且连续 ASSIST_GRACE_CHECKS 次判定为掉队的玩家，
-- 将被拉回房主身边。房主到达出口并停留时，掉队队友会被自动收拢，从而一同结算过关。
local ASSIST_RADIUS = 10000         -- 距离阈值（10000 单位 ≈ 100 米）
local ASSIST_INTERVAL = 5           -- 检查间隔（秒），on_frame_tick 里按这个节流
-- 宽限次数由 CONFIG.assist.grace_seconds 换算，避免配置值与实际生效值不一致
local ASSIST_GRACE_CHECKS = math.max(1, math.floor(CONFIG.assist.grace_seconds / ASSIST_INTERVAL + 0.5))

local function distance_between(a, b)
    if not a or not b then return nil end
    local ok, dx = pcall(function() return a.X - b.X end)
    if not ok then return nil end
    local dy, dz = a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function assist_tick()
    assist_ticks = assist_ticks + 1
    if not CONFIG.assist.enabled then
        assist_far_since = {}
        return
    end
    local host = get_pawn()
    local origin = host and get_location(host)
    if not origin then return end
    local host_address = host:GetAddress()
    local moved = 0
    for _, pawn in ipairs(all_pawns()) do
        if pawn:IsValid() and pawn:GetAddress() ~= host_address then
            local address = pawn:GetAddress()
            local distance = distance_between(origin, get_location(pawn))
            if distance and distance > ASSIST_RADIUS then
                local since = assist_far_since[address]
                if not since then
                    assist_far_since[address] = assist_ticks
                elseif assist_ticks - since >= ASSIST_GRACE_CHECKS then
                    if teleport_to(pawn, origin) then
                        moved = moved + 1
                        assist_far_since[address] = nil
                    else
                        assist_far_since[address] = assist_ticks
                    end
                end
            else
                assist_far_since[address] = nil
            end
        end
    end
    if moved > 0 then
        last_event = "ok_assist"
        notify(string.format("auto escort: %d player(s) pulled back to host", moved))
    end
end

-- ============================ 3. 选关 / 跳关 ============================

local function make_fname(name)
    local ok, value = pcall(function() return FName(name) end)
    if ok and value then return value end
    local ok2, value2 = pcall(function() return FName(name, EFindName.FNAME_Add) end)
    if ok2 then return value2 end
    return nil
end

local function travel_to_level(map_name)
    if not map_name or map_name == "" then return false end
    -- 冷却保护：短时间内连续切换地图会使引擎在地图加载过程中崩溃
    local now = os.time()
    if last_travel_time and (now - last_travel_time) < TRAVEL_COOLDOWN then
        notify(string.format("travel ignored (cooldown %ds)", TRAVEL_COOLDOWN - (now - last_travel_time)))
        log("travel ignored: cooldown, %.0fs left", TRAVEL_COOLDOWN - (now - last_travel_time))
        return false
    end
    -- 关键：仅允许切换列表内的关卡，避免 open 不存在的地图导致崩溃
    local resolved = resolve_level(map_name)
    if not resolved then
        last_event = "bad_level"
        notify("unknown level, refused: " .. tostring(map_name))
        log("travel refused (not in level list): %s", tostring(map_name))
        return false
    end
    local statics = gameplay_statics()
    local pc = get_pc()
    if not statics or not pc then
        notify("cannot travel: GameplayStatics missing")
        return false
    end
    local fname = make_fname(resolved)
    if not fname then
        notify("bad level name: " .. resolved)
        return false
    end
    -- ?listen 确保切换后仍为可继续加入的 listen server，全队一同迁移
    -- 重要：OpenLevel 之后旧世界即开始销毁，此后不得再访问任何游戏对象（否则 Lua 报错或崩溃）
    notify(string.format("travel -> %s (whole party)", short_name(resolved)))
    local ok = pcall(function() statics:OpenLevel(pc, fname, true, "listen") end)
    if ok then
        last_travel_time = now
        last_event = "ok_travel"
    else
        last_event = "travel_failed"
        notify("travel failed: " .. resolved)
    end
    return ok
end

local function level_index_of(map_name)
    if not map_name then return nil end
    local wanted = string.lower(short_name(map_name) or "")
    for index, name in ipairs(CONFIG.levels) do
        if string.lower(short_name(name) or "") == wanted then return index end
    end
    return nil
end

local function show_selection()
    notify(string.format("selected level [%d/%d]: %s   (F8 = travel, F6/F7 = prev/next)",
        selected_level, #CONFIG.levels, short_name(CONFIG.levels[selected_level])))
end

local function select_prev()
    selected_level = selected_level - 1
    if selected_level < 1 then selected_level = #CONFIG.levels end
    show_selection()
end

local function select_next()
    selected_level = selected_level + 1
    if selected_level > #CONFIG.levels then selected_level = 1 end
    show_selection()
end

-- 切换地图必须离开「世界 Tick 内部」：ServerTravel 会销毁当前世界，
-- 若在每帧钩子（Actor:ReceiveTick / Widget:Tick）中直接调用将导致崩溃。
-- 此处改为：延迟一小段时间后交由 UE4SS 的引擎 Tick 队列执行。
local travel_pending = false

local function request_travel(map_name)
    if travel_pending and (os.clock() - travel_pending_since) < 10 then
        notify("travel already queued")
        return
    end
    travel_pending = true
    travel_pending_since = os.clock()
    last_event = "travel_queued"
    notify("travel queued: " .. tostring(short_name(map_name) or map_name))
    ExecuteWithDelay(500, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(travel_to_level, map_name)
            travel_pending = false
            if not ok then
                log("travel error: %s", tostring(err))
                last_event = "travel_failed"
            end
            pcall(write_state)
        end)
    end)
end

-- 注意：request_travel 必须先于 travel_selected 定义，
-- 否则 travel_selected 中的 request_travel 会被视为全局变量（nil）。
local function travel_selected()
    request_travel(CONFIG.levels[selected_level])
end

local function list_levels()
    local now = current_level()
    log("current level: %s", tostring(now))
    for index, name in ipairs(CONFIG.levels) do
        local mark = ""
        if now and string.lower(tostring(now)) == string.lower(short_name(name) or "") then mark = "  <== current" end
        log("  [%2d] %s   %s%s", index, short_name(name), name, mark)
    end
    notify(string.format("current: %s | selected: %s | %d levels (see log)",
        tostring(now), short_name(CONFIG.levels[selected_level]), #CONFIG.levels))
end

local function skip_level()
    -- 使用游戏自身的结算流程：全员进入出口区域 -> 结算 -> 游戏自行 ServerTravel
    if push_everyone_to_exit() then
        -- 占用冷却，避免面板紧接着再次发送切图命令导致引擎崩溃
        last_travel_time = os.time()
        return
    end
    if last_travel_time and (os.time() - last_travel_time) < TRAVEL_COOLDOWN then
        notify("skip ignored (cooldown)")
        return
    end
    -- 未找到出口区域（例如大厅）时直接前往下一关
    local now = current_level()
    local index = level_index_of(now)
    if index then
        selected_level = (index % #CONFIG.levels) + 1
    else
        selected_level = math.min(selected_level, #CONFIG.levels)
    end
    notify("no exit zone, travelling to next level")
    travel_selected()
end

local function status()
    local players = #all_pawns()
    local max_players = "?"
    for _, state in pairs(FindAllOf("MP_GameState_C") or {}) do
        if state:IsValid() then
            local ok, value = pcall(function() return state.MaxPlayers end)
            if ok and type(value) == "number" then max_players = tostring(value) end
        end
    end
    notify(string.format("target %d | cap %s | players %d | host %s | hook %s | level %s",
        CONFIG.max_players, tostring(max_players), players, tostring(is_host()),
        tostring(HOOK_REGISTERED), tostring(current_level())))
end

-- ============================ 快捷键 / 定时器 ============================

local function act_gather()
    if not host_only("gather") then return end
    gather_at(get_pawn(), "gather to host")
    last_event = "ok_gather"
end

local function act_exit()
    if not host_only("push to exit") then return end
    push_everyone_to_exit()
end

local function act_skip()
    if not host_only("skip level") then return end
    last_event = "skip_started"
    skip_level()
end

local function tick_fast()
    ExecuteInGameThread(enforce_max_players)
end

local function tick_ui()
    ExecuteInGameThread(patch_sliders)
end

local function on_key_gather() ExecuteInGameThread(act_gather) end
local function on_key_exit() ExecuteInGameThread(act_exit) end
local function on_key_skip() ExecuteInGameThread(act_skip) end
local function on_key_prev() ExecuteInGameThread(select_prev) end
local function on_key_next() ExecuteInGameThread(select_next) end
local function on_key_travel() ExecuteInGameThread(travel_selected) end
local function on_key_list() ExecuteInGameThread(list_levels) end
local function on_key_status() ExecuteInGameThread(status) end
local function on_key_assist()
    ExecuteInGameThread(function()
        CONFIG.assist.enabled = not CONFIG.assist.enabled
        notify(CONFIG.assist.enabled and "auto escort: ON" or "auto escort: OFF")
    end)
end

-- ============================ 控制台命令 ============================

local function cmd_hub(_, _, output)
    if output then pcall(function() output:Log("ETB_HostKit: see screen + log") end) end
    ExecuteInGameThread(status)
    return true
end

local function cmd_players(_, parameters)
    local value = tonumber(parameters[1])
    if value and value >= 2 and value <= 32 then
        CONFIG.max_players = value
        ExecuteInGameThread(function()
            enforce_max_players()
            patch_sliders()
            notify(string.format("target players = %d (applies next time you host)", value))
        end)
    else
        ExecuteInGameThread(function()
            notify(string.format("target players = %d, usage: etb_players <2-32>", CONFIG.max_players))
        end)
    end
    return true
end

local function cmd_levels()
    ExecuteInGameThread(list_levels)
    return true
end

local function cmd_level(_, parameters)
    local key = parameters[1]
    if not key then
        ExecuteInGameThread(function() notify("usage: etb_level <index|map>") end)
        return true
    end
    ExecuteInGameThread(function()
        if not host_only("travel") then return end
        local index = tonumber(key)
        local map_name = index and CONFIG.levels[index] or key
        if index then selected_level = index end
        travel_to_level(map_name)
    end)
    return true
end

local function cmd_next()
    ExecuteInGameThread(function()
        if not host_only("travel") then return end
        select_next()
        travel_selected()
    end)
    return true
end

local function cmd_skip()
    ExecuteInGameThread(act_skip)
    return true
end

local function cmd_gather()
    ExecuteInGameThread(act_gather)
    return true
end

local function cmd_exit()
    ExecuteInGameThread(act_exit)
    return true
end

local function cmd_assist(_, parameters)
    local value = string.lower(tostring(parameters[1] or "on"))
    CONFIG.assist.enabled = (value ~= "off" and value ~= "0" and value ~= "false")
    log("auto escort: %s", CONFIG.assist.enabled and "ON" or "OFF")
    ExecuteInGameThread(function()
        notify(CONFIG.assist.enabled and "auto escort: ON" or "auto escort: OFF")
    end)
    return true
end

local function cmd_help()
    local lines = {
        MOD_NAME .. " commands:",
        "  etb_hub                 status",
        "  etb_players <n>         target players (2-32), applies next host",
        "  etb_levels              list levels",
        "  etb_level <n|map>       travel whole party to a level",
        "  etb_next                travel to next level",
        "  etb_skip                skip current level (exit flow if possible)",
        "  etb_gather              gather everyone to host",
        "  etb_exit                push everyone into exit zone",
        "  etb_assist <on|off>     auto escort stragglers",
        "  hotkeys: Ctrl+F9 gather | Ctrl+Shift+F9 exit | Ctrl+Shift+F10 skip",
        "           Ctrl+Shift+F6/F7 prev/next level | Ctrl+Shift+F8 travel |",
        "           Ctrl+Shift+F11 level list | Ctrl+Shift+F12 status",
    }
    for _, line in ipairs(lines) do log("%s", line) end
    return true
end

-- ============================== 启动 ==============================

-- ====================== 4. 与「可视化控制台」面板通信 ======================
-- 面板（HostPanel.ps1）将待执行的动作写入 panel_command.txt，
-- mod 每秒读取并执行，随后把实时状态写回 panel_state.txt 供面板显示。

local PANEL_DIR = nil
local CMD_FILE = nil
local STATE_FILE = nil
local ALIVE_FILE = nil

local function clean_path(text)
    if type(text) ~= "string" then return nil end
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil end
    return trimmed
end

-- 依次尝试多个候选目录，取第一个可写的（UE4SS 的工作目录 = Binaries\Win64）
local function init_panel_paths()
    local candidates = {}
    if PATHS_OK and type(GAME_PATHS) == "table" then
        local mods_dir = clean_path(GAME_PATHS.mods_dir)
        if mods_dir then candidates[#candidates + 1] = mods_dir .. "\\ETB_HostKit\\" end
        local bin_dir = clean_path(GAME_PATHS.bin_dir)
        if bin_dir then candidates[#candidates + 1] = bin_dir .. "\\ue4ss\\Mods\\ETB_HostKit\\" end
    end
    candidates[#candidates + 1] = "ue4ss\\Mods\\ETB_HostKit\\"
    candidates[#candidates + 1] = "Mods\\ETB_HostKit\\"

    for _, directory in ipairs(candidates) do
        local probe = io.open(directory .. "panel_state.txt", "w")
        if probe then
            probe:close()
            PANEL_DIR = directory
            CMD_FILE = directory .. "panel_command.txt"
            STATE_FILE = directory .. "panel_state.txt"
            ALIVE_FILE = directory .. "panel_alive.txt"
            log("panel files -> %s", directory)
            return
        end
    end
    log("warning: cannot find a writable panel directory")
end

write_state = function()
    if not STATE_FILE then return end
    local players = 0
    for _ in pairs(all_pawns()) do players = players + 1 end
    local lines = {
        "max_players=" .. tostring(CONFIG.max_players),
        "players=" .. tostring(players),
        "level=" .. tostring(current_level()),
        "selected=" .. tostring(short_name(CONFIG.levels[selected_level])),
        "selected_index=" .. tostring(selected_level),
        "host=" .. tostring(is_host()),
        "hook=" .. tostring(HOOK_REGISTERED) .. (HOOK_FIRED and ",fired" or ""),
        "assist=" .. tostring(CONFIG.assist.enabled),
        "last_event=" .. tostring(last_event),
        "ack=" .. tostring(last_ack),
        "seq=" .. tostring(panel_seq),
        "updated=" .. os.date("%H:%M:%S"),
    }
    local handle = io.open(STATE_FILE, "w")
    if handle then
        handle:write(table.concat(lines, "\n") .. "\n")
        handle:close()
    end
    -- 心跳：面板据此判断游戏内 mod 是否在运行，文件通道无响应时不会误发快捷键
    if ALIVE_FILE then
        local beat = io.open(ALIVE_FILE, "w")
        if beat then
            beat:write(os.date("%H:%M:%S"))
            beat:close()
        end
    end
end

local function set_max_players(value)
    if not value or value < 2 or value > 32 then return end
    CONFIG.max_players = value
    slider_done = false
    enforce_max_players()
    patch_sliders()
    notify(string.format("max players = %d (applies next time you host)", value))
end

local function run_panel_command(text)
    -- 去除可能存在的 UTF-8 BOM 与首尾空白（PowerShell 写文件时可能引入）
    text = text:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    local command, argument = text:match("^(%S+)%s*(.*)$")
    if not command then return end
    command = string.lower(command)
    argument = argument or ""
    panel_seq = panel_seq + 1
    last_ack = command                  -- 面板通过 seq/ack 确认文件通道已收到
    local known = false
    if command == "set_max" then
        known = true
        set_max_players(tonumber(argument))
        last_event = "ok_max"
    elseif command == "gather" then
        known = true
        act_gather()
    elseif command == "exit" then
        known = true
        act_exit()
    elseif command == "skip" then
        known = true
        act_skip()
    elseif command == "next" then
        known = true
        select_next()
        travel_selected()
    elseif command == "next_select" then
        known = true
        select_next()
        last_event = "ok_select"
    elseif command == "prev" then
        known = true
        select_prev()
        last_event = "ok_select"
    elseif command == "travel" then
        known = true
        travel_selected()
    elseif command == "select" then
        known = true
        local index = tonumber(argument)
        if index and CONFIG.levels[index] then
            selected_level = index
            show_selection()
            last_event = "ok_select"
        end
    elseif command == "level" then
        known = true
        local index = tonumber(argument)
        if index and CONFIG.levels[index] then
            selected_level = index
            request_travel(CONFIG.levels[index])
        elseif argument ~= "" then
            request_travel(argument)
        end
    elseif command == "assist" then
        known = true
        CONFIG.assist.enabled = (argument == "on" or argument == "1" or argument == "true")
        assist_far_since = {}
        notify(CONFIG.assist.enabled and "auto escort: ON" or "auto escort: OFF")
        last_event = CONFIG.assist.enabled and "ok_assist_on" or "ok_assist_off"
    elseif command == "assist_on" then
        known = true
        CONFIG.assist.enabled = true
        assist_far_since = {}
        notify("auto escort: ON")
        last_event = "ok_assist_on"
    elseif command == "assist_off" then
        known = true
        CONFIG.assist.enabled = false
        assist_far_since = {}
        notify("auto escort: OFF")
        last_event = "ok_assist_off"
    elseif command == "assist_toggle" then
        known = true
        CONFIG.assist.enabled = not CONFIG.assist.enabled
        assist_far_since = {}
        notify(CONFIG.assist.enabled and "auto escort: ON" or "auto escort: OFF")
        last_event = CONFIG.assist.enabled and "ok_assist_on" or "ok_assist_off"
    elseif command == "status" then
        known = true
        status()
        last_event = "ok_status"
    elseif command == "levels" then
        known = true
        list_levels()
        last_event = "ok_levels"
    end
    if not known then
        log("unknown panel command: [%s]", text)
    end
    write_state()
end

-- ===== 面板驱动（不依赖 UE4SS 的 ExecuteInGameThread 队列）=====
-- 实测该队列在运行一段时间或切换地图后会停止出队，导致面板失效。
-- 方案：异步线程仅负责文件读写（读取命令、写入状态），命令进入队列；
--       引擎每帧钩子（本身即在游戏线程）负责执行队列中的命令。
local pending_commands = {}
local last_assist = 0
local last_panel_io = 0
local tick_hook_fired = false

local function queue_panel_commands()
    if not CMD_FILE then init_panel_paths() end
    if not CMD_FILE then return end
    local handle = io.open(CMD_FILE, "r")
    if not handle then return end
    local content = handle:read("*a")
    handle:close()
    if not content or content == "" then return end
    local empty = io.open(CMD_FILE, "w")
    if empty then empty:write("") empty:close() end
    for line in content:gmatch("[^\r\n]+") do
        pending_commands[#pending_commands + 1] = line
    end
end

local function on_frame_tick()
    if not tick_hook_fired then
        tick_hook_fired = true
        log("panel driver: first frame tick received")
    end
    -- 以「秒数变化」作为闸门，保证文件读写每秒一次（os.clock 为进程 CPU 时间，
    -- 在多核环境下远快于真实时间，不可用作间隔计时）。
    local now = os.time()
    if now ~= last_panel_io then
        last_panel_io = now
        safe("panel io", queue_panel_commands)
        safe("state write", write_state)
        safe("max players", enforce_max_players)
        safe("sliders", patch_sliders)
    end
    -- 命令队列：每次调用均处理（多个钩子同时触发亦无影响）
    while #pending_commands > 0 do
        local command = table.remove(pending_commands, 1)
        safe("command " .. tostring(command), function() run_panel_command(command) end)
    end
    if now - last_assist >= ASSIST_INTERVAL then
        last_assist = now
        safe("assist", assist_tick)
    end
end

local TICK_HOOK_TARGETS = {
    "/Game/Game/BPCharacter_Demo.BPCharacter_Demo_C:ReceiveTick",  -- 玩家角色蓝图每帧 Tick
    "/Game/Game/Flashlight_BP.Flashlight_BP_C:ReceiveTick",        -- 手电蓝图每帧 Tick
    "/Script/UMG.UserWidget:Tick",           -- UMG 控件每帧 Tick（菜单里也一定在跑）
    "/Script/Engine.HUD:ReceiveDrawHUD",     -- 有 HUD 时每帧绘制
}

local function install_tick_hook()
    local installed = 0
    for _, target in ipairs(TICK_HOOK_TARGETS) do
        local ok = pcall(RegisterHook, target, function(self, ...) safe("frame tick", on_frame_tick) end)
        if ok then
            installed = installed + 1
            log("panel driver: hooked %s", target)
        end
    end
    if installed == 0 then
        log("panel driver: no frame hook available, falling back")
    end
    -- 同时保留队列驱动：主菜单中蓝图 Actor / 控件可能不触发 Tick，
    -- 此时依赖它送达命令；进入游戏后由每帧钩子接管（两条路径均可排空队列）。
    LoopAsync(1000, function() ExecuteInGameThread(on_frame_tick) end)
    return installed > 0
end

local function boot()
    log("loading: target %d players", CONFIG.max_players)

    if not install_session_hook() then
        for _, delay in ipairs({ 5000, 15000, 30000, 60000 }) do
            ExecuteWithDelay(delay, install_session_hook)
        end
    end

    ExecuteWithDelay(3000, tick_fast)
    init_panel_paths()
    -- 面板命令仅由游戏线程的帧钩子读取（单一读取方，避免两个线程争用同一文件导致命令丢失）
    install_tick_hook()

    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, on_key_gather)
    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_exit)
    RegisterKeyBind(Key.F10, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_skip)
    RegisterKeyBind(Key.F11, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_list)
    RegisterKeyBind(Key.F12, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_status)
    RegisterKeyBind(Key.F6, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_prev)
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_next)
    RegisterKeyBind(Key.F8, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_travel)
    RegisterKeyBind(Key.F4, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_key_assist)

    RegisterConsoleCommandHandler("etb_hub", cmd_hub)
    RegisterConsoleCommandHandler("etb_players", cmd_players)
    RegisterConsoleCommandHandler("etb_levels", cmd_levels)
    RegisterConsoleCommandHandler("etb_level", cmd_level)
    RegisterConsoleCommandHandler("etb_next", cmd_next)
    RegisterConsoleCommandHandler("etb_skip", cmd_skip)
    RegisterConsoleCommandHandler("etb_gather", cmd_gather)
    RegisterConsoleCommandHandler("etb_exit", cmd_exit)
    RegisterConsoleCommandHandler("etb_assist", cmd_assist)
    RegisterConsoleCommandHandler("etb_help", cmd_help)

    log("hotkeys: Ctrl+F9 gather | Ctrl+Shift+F9 exit | Ctrl+Shift+F10 skip | Ctrl+Shift+F6/F7 prev/next | Ctrl+Shift+F8 travel | Ctrl+Shift+F4 assist | Ctrl+Shift+F11 list | Ctrl+Shift+F12 status")
end

pcall(boot)
