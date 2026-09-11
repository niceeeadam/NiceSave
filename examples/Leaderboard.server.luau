--!strict

-- This is a Roblox player-list leaderboard (the built-in `leaderstats` UI).
-- It is not a global, cross-server ranking; that requires OrderedDataStore.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local NiceSave = require(ServerScriptService.NiceSave)

type PlayerData = {
	Stats: { [string]: number },
}

type Profile = NiceSave.Profile<PlayerData>

local TEMPLATE: PlayerData = {
	Stats = {
		Coins = 0,
		Wins = 0,
		Level = 1,
	},
}

local PlayerStore = NiceSave.new("PlayerData_v1", TEMPLATE, {
	SchemaVersion = 1,
	AutoSaveInterval = 120,
	SessionTimeout = 600,
	UseMock = false, -- Use true for safe Studio-only testing.
})

local DISPLAYED_STATS = { "Coins", "Wins", "Level" }
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
local statValues: { [Player]: { [string]: IntValue } } = {}
local statConnections: { [Player]: { RBXScriptConnection } } = {}
local leaderboardFolders: { [Player]: Folder } = {}

local function normalizeStat(value: number): number
	return math.max(0, math.floor(value))
end

local function disconnectLeaderboard(player: Player)
	local connections = statConnections[player]
	if connections ~= nil then
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	statConnections[player] = nil
	statValues[player] = nil

	local folder = leaderboardFolders[player]
	if folder ~= nil then
		folder:Destroy()
	end
	leaderboardFolders[player] = nil
end

local function createLeaderboard(player: Player, profile: Profile)
	disconnectLeaderboard(player)

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player
	leaderboardFolders[player] = folder

	local values: { [string]: IntValue } = {}
	local connections: { RBXScriptConnection } = {}
	statValues[player] = values
	statConnections[player] = connections

	for _, statName in DISPLAYED_STATS do
		local stat = Instance.new("IntValue")
		stat.Name = statName
		stat.Value = normalizeStat(profile.Data.Stats[statName] or 0)
		stat.Parent = folder
		values[statName] = stat
		profile.Data.Stats[statName] = stat.Value

		table.insert(connections, stat:GetPropertyChangedSignal("Value"):Connect(function()
			if not profile:IsActive() then
				return
			end

			local normalized = normalizeStat(stat.Value)
			if normalized ~= stat.Value then
				stat.Value = normalized
				return
			end

			profile.Data.Stats[statName] = normalized
		end))
	end
end

-- Call this from trusted server gameplay code when a displayed stat changes.
-- For a larger game, move this function and the profile table into a service module.
local function incrementStat(player: Player, statName: string, amount: number): boolean
	local profile = profiles[player]
	local values = statValues[player]
	local stat = if values ~= nil then values[statName] else nil

	if profile == nil or stat == nil or not profile:IsActive() then
		return false
	end

	stat.Value = normalizeStat(stat.Value + amount)
	return true
end

local function onPlayerAdded(player: Player)
	if loading[player] or profiles[player] ~= nil then
		return
	end
	loading[player] = true

	local profile, loadError = PlayerStore:LoadAsync("Player_" .. player.UserId, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	loading[player] = nil
	if profile == nil then
		if player.Parent == Players then
			player:Kick("Your data could not be loaded. Please rejoin. (" .. tostring(loadError) .. ")")
		end
		return
	end

	profile:AddUserId(player.UserId)
	profile.OnReleased:Connect(function(reason: string)
		if profiles[player] == profile then
			profiles[player] = nil
		end
		disconnectLeaderboard(player)

		if player.Parent == Players then
			player:Kick("Your data session ended. Please rejoin. (" .. reason .. ")")
		end
	end)

	if player.Parent ~= Players then
		profile:ReleaseAsync()
		return
	end

	profiles[player] = profile
	createLeaderboard(player, profile)

	-- Example reward. Replace this with your own trusted server-side game logic.
	incrementStat(player, "Coins", 1)
end

local function onPlayerRemoving(player: Player)
	loading[player] = nil
	disconnectLeaderboard(player)

	local profile = profiles[player]
	if profile ~= nil then
		profiles[player] = nil
		profile:ReleaseAsync()
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
