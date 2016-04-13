-- =============================================================================
--  bAutoClaim
--    by: BurstBiscuit
-- =============================================================================

require "math"
require "table"
require "unicode"

require "lib/lib_Callback2"
require "lib/lib_ChatLib"
require "lib/lib_Debug"
require "lib/lib_InterfaceOptions"
require "lib/lib_PanelManager"
require "lib/lib_Wallet"

Debug.EnableLogging(false)


-- =============================================================================
--  Constants
-- =============================================================================

-- Copied from Bounties.lua and REVERSED to match values
local c_BountyTrackRewards = {
    139803,
    139802,
    139801,
    139800,
    139799,
    139798,
    139797,
    139796
}


-- =============================================================================
--  Variables
-- =============================================================================

local g_BountyLastClaim
local g_BountyMismatch      = false
local g_BountyTrackCosts    = {}
local g_CurrencyExchangeURL
local g_DailyRewardStage
local g_IsPlayerReady       = false

local CYCLE_ClaimTimedDailyReward


-- =============================================================================
--  Interface Options
-- =============================================================================

local io_Settings = {
    Debug               = false,
    Daily               = false,
    Timed               = false,
    TimedCombat         = true,
    TimedClosePanel     = true,
    Bounty              = false,
    Credits             = false,
    CrystiteThreshold   = 10000
}

function OnOptionChanged(id, value)
    if     (id == "Debug") then
        Debug.EnableLogging(value)

    elseif (id == "Timed") then
        if (value) then
            CYCLE_ClaimTimedDailyReward:Run(15)

        else
            CYCLE_ClaimTimedDailyReward:Stop()
        end
    end

    io_Settings[id] = value
end

function InitializeOptions()
    InterfaceOptions.SaveVersion(1)

    InterfaceOptions.AddCheckBox({
        id      = "Debug",
        label   = "Debug mode",
        default = io_Settings.Debug
    })

    InterfaceOptions.StartGroup({
        label       = "Bounty rewards",
        checkbox    = true,
        id          = "Bounty",
        default     = io_Settings.Bounty
    })
        if (#g_BountyTrackCosts ~= #c_BountyTrackRewards) then
            g_BountyMismatch = true
            Notification(unicode.format("Bounty track cost(%d) and reward(%d) size mismatch! Defaulting to platinum cache", #g_BountyTrackCosts, #c_BountyTrackRewards))

        else
            for i, bountyTrackRewards in ipairs(c_BountyTrackRewards) do
                local rewardInfo = Game.GetItemInfoByType(bountyTrackRewards)

                InterfaceOptions.AddCheckBox({
                    id          = "BountyReward" .. tostring(i),
                    label       = "Claim " .. ((rewardInfo and rewardInfo.name) and rewardInfo.name or g_BountyTrackCosts[i]),
                    tooltip     = ((rewardInfo and rewardInfo.description) and unicode.gsub(rewardInfo.description, "%[%/?color=?#?%w*%]", "") or nil),
                    default     = false
                })
            end
        end
    InterfaceOptions.StopGroup()

    InterfaceOptions.StartGroup({label = "Daily login rewards"})
        InterfaceOptions.AddCheckBox({
            id          = "Daily",
            label       = "Claim daily login rewards",
            tooltip     = "Automatically claim the daily login reward (Dashboard)",
            default     = io_Settings.Daily
        })
    InterfaceOptions.StopGroup()

    InterfaceOptions.StartGroup({label = "Playtime rewards"})
        InterfaceOptions.AddCheckBox({
            id          = "Timed",
            label       = "Claim playtime rewards",
            tooltip     = "Automatically claim the playtime reward (Field Report)",
            default     = io_Settings.Timed
        })
        InterfaceOptions.AddCheckBox({
            id          = "TimedCombat",
            label       = "Don't claim while in combat",
            tooltip     = "Don't claim the playtime reward in combat, which might interrupt shooting because of the forced cursor mode",
            default     = io_Settings.TimedCombat
        })
        InterfaceOptions.AddCheckBox({
            id          = "TimedClosePanel",
            label       = "Automatically close the Field Report panel",
            default     = io_Settings.TimedClosePanel
        })
    InterfaceOptions.StopGroup()

    InterfaceOptions.StartGroup({label = "Currency exchange"})
        InterfaceOptions.AddCheckBox({
            id          = "Credits",
            label       = "Convert Crystite to Credits",
            tooltip     = "Automatically convert Crystite to Credits on login or switching zones",
            default     = io_Settings.Credits
        })
        InterfaceOptions.AddTextInput({
            id          = "CrystiteThreshold",
            label       = "Crystite threshold",
            tooltip     = "Always keep this amount of Crystite",
            default     = io_Settings.CrystiteThreshold,
            numeric     = true,
            whitespace  = false,
            maxlen      = 14
        })
    InterfaceOptions.StopGroup()
end

-- =============================================================================
--  Functions
-- =============================================================================

function Notification(message)
    ChatLib.Notification({text = "[bAutoClaim] " .. tostring(message)})
end

function TimedDailyRewardRoll()
    local status, failure = pcall(function()
        Player.RequestTimedDailyRewardRoll()
    end)

    Debug.Table("Player.RequestTimedDailyRewardRoll()", {status = status, failure = failure})
end

function ClaimTimedDailyReward()
    if (io_Settings.Timed and not (io_Settings.TimedCombat and Player.IsInCombat())) then
        -- Debug.Log("ClaimTimedDailyReward()")

        local timedDailyRewardInfo = Player.GetTimedDailyRewardInfo()
        -- Debug.Table("timedDailyRewardInfo", timedDailyRewardInfo)

        if (type(timedDailyRewardInfo) ~= "table" or type(timedDailyRewardInfo.countdown_secs) ~= "number" or not timedDailyRewardInfo.state) then
            Debug.Warn("No timedDailyRewardInfo, timedDailyRewardInfo.countdown_secs or timedDailyRewardInfo.state")

        elseif (timedDailyRewardInfo.state == "STARTED" and timedDailyRewardInfo.countdown_secs < 0) then
            Component.SetInputMode("cursor")
            Callback2.FireAndForget(TimedDailyRewardRoll, nil, 0.1)
        end
    end
end

function ConvertCrystiteToCredits(exchangeInfo)
    Debug.Table("ConvertCrystiteToCredits()", exchangeInfo)

    if (not io_Settings.Credits) then
        return

    elseif (HTTP.IsRequestPending(g_CurrencyExchangeURL)) then
        Debug.Log("Request is already pending, rescheduling")
        Callback2.FireAndForget(PostCreditPurchaseRequest, exchangeInfo, 5)

    elseif (exchangeInfo.remaining > 0) then
        local availableCrystite = tonumber(Player.GetItemCount(Wallet.CRYSTITE_ID)) - tonumber(io_Settings.CrystiteThreshold)

        if (availableCrystite >= exchangeInfo.from_quantity) then
            local convert = math.min(math.floor(availableCrystite / exchangeInfo.from_quantity), exchangeInfo.remaining) * exchangeInfo.from_quantity
            Debug.Log("Exchanging Crystite to Credits:", convert)

            HTTP.IssueRequest(g_CurrencyExchangeURL, "POST",
                    {
                        from_sdb_id = tonumber(exchangeInfo.from_sdb_id),
                        to_sdb_id   = tonumber(exchangeInfo.to_sdb_id),
                        quantity    = convert
                    },
                    function(response, failure)

                if (failure) then
                    Debug.Error(failure)

                elseif (response) then
                    Debug.Table("response", response)

                    Notification(unicode.format("Currency exchange: %dx %s -> %dx %s",
                        convert,
                        ChatLib.EncodeItemLink(Wallet.CRYSTITE_ID),
                        response.quantity,
                        ChatLib.EncodeItemLink(response.item_sdb_id)
                    ))
                end
            end)
        end
    end
end

function GetCurrencyExchangeInfo()
    Debug.Log("GetCurrencyExchangeInfo()")

    if (not io_Settings.Credits) then
        return

    elseif (HTTP.IsRequestPending(g_CurrencyExchangeURL)) then
        Debug.Log("Request is already pending, rescheduling")
        Callback2.FireAndForget(GetCurrencyExchangeInfo, nil, 5)

    else
        HTTP.IssueRequest(g_CurrencyExchangeURL, "GET", nil, function(response, failure)
            if (failure) then
                Callback2.FireAndForget(GetCurrencyExchangeInfo, nil, 10)
                Debug.Error(failure)

            elseif (response) then
                Debug.Table("currencyExchangeInfo", response)

                for _, exchangeInfo in pairs(response) do
                    -- Make sure the exchange is active and all needed values are present
                    if (exchangeInfo.active
                            and exchangeInfo.from_sdb_id and tostring(exchangeInfo.from_sdb_id) == tostring(Wallet.CRYSTITE_ID)
                            and exchangeInfo.to_sdb_id and tostring(exchangeInfo.to_sdb_id) == tostring(Wallet.CREDITS_ID)
                            and type(exchangeInfo.from_quantity) == "number" and type(exchangeInfo.to_quantity) == "number"
                            and type(exchangeInfo.daily_limit) == "number" and type(exchangeInfo.remaining) == "number") then

                        Debug.Table("exchangeInfo", exchangeInfo)
                        ConvertCrystiteToCredits(exchangeInfo)

                        break
                    end
                end

            else
                Callback2.FireAndForget(GetCurrencyExchangeInfo, nil, 5)
                Debug.Warn("Something weird happened, no error or response for HTTP request")
            end
        end)
    end
end


-- =============================================================================
--  Events
-- =============================================================================

function OnComponentLoad()
    InterfaceOptions.SetCallbackFunc(OnOptionChanged)

    g_BountyTrackCosts  = Game.GetBountyTrackCosts()
    table.sort(g_BountyTrackCosts, function(a, b) return a > b end)

    CYCLE_ClaimTimedDailyReward = Callback2.CreateCycle(ClaimTimedDailyReward)

    InitializeOptions()
end

function OnBountyPointsChanged(args)
    Debug.Event(args)

    if (io_Settings.Bounty and g_IsPlayerReady and type(args.quantity) == "number") then
        if (g_BountyMismatch and args.quantity >= g_BountyTrackCosts[#g_BountyTrackCosts]) then
            Debug.Log("Player.ClaimBountyRewards()")
            Player.ClaimBountyRewards()

        else
            Debug.Table("g_BountyTrackCosts", g_BountyTrackCosts)

            for i, cost in ipairs(g_BountyTrackCosts) do
                Debug.Log("Checking tracking cost", i, cost)

                if (io_Settings["BountyReward" .. tostring(i)] and args.quantity >= cost and i ~= g_BountyLastClaim) then
                    Debug.Log("Player.ClaimBountyRewards()", i, cost)
                    Player.ClaimBountyRewards()
                    g_BountyLastClaim = i
                    break
                end
            end
        end
    end
end

function OnDailyLoginDataUpdate(args)
    Debug.Event(args)

    if (io_Settings.Daily and args.ready) then
        Player.ClaimDailyItem()
    end
end

-- TODO: ON_DAILY_LOGIN_REWARD does not seem to fire in any way?
function OnDailyLoginReward(args)
    Debug.Event(args)
end

function OnDailyRewardLoginInfoUpdated(args)
    Debug.Event(args)
end

function OnPlayerReady()
    local clientApiHost     = System.GetOperatorSetting("clientapi_host")
    local characterId       = select(5, Player.GetInfo())
    g_CurrencyExchangeURL   = tostring(clientApiHost) .. "/api/v3/characters/" .. tostring(characterId) .. "/currency_exchange"
    g_IsPlayerReady         = true

    GetCurrencyExchangeInfo()
end

function OnTimedDailyReward(args)
    Debug.Event(args)

    if (not g_DailyRewardStage or g_DailyRewardStage > args.stage) then
        g_DailyRewardStage = args.stage
    end

    if (not io_Settings.Timed) then
        return

    elseif (args.state == "ROLLED") then
        local status, failure = pcall(function()
            Player.RequestTimedDailyRewardCommit()
        end)

        Debug.Table("Player.RequestTimedDailyRewardCommit()", {status = status, failure = failure})
        Callback2.FireAndForget(Component.SetInputMode, "default", 0.05)

    elseif (g_DailyRewardStage < args.stage and args.won) then
        g_DailyRewardStage = args.stage

        Notification("Playtime reward: " .. args.won.quantity .. "x " .. ChatLib.EncodeItemLink(args.won.id))

        if (io_Settings.TimedClosePanel) then
            Callback2.FireAndForget(PanelManager.CloseActivePanel, nil, 0.1)
        end
    end
end
