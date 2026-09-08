local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local DataVault = require(ServerScriptService.DataVault)

local TEMPLATE = {
	Coins = 0,
	Inventory = {},
	Settings = {
		Music = true,
		Effects = true,
	},
}

local PlayerStore = DataVault.new("PlayerData_v1", TEMPLATE, {
	SchemaVersion = 1,
	AutoSaveInterval = 120,
	SessionTimeout = 600,
	UseMock = false,
})

local profiles: { [Player]: any } = {}

local function onPlayerAdded(player: Player)
	local profile, loadError = PlayerStore:LoadAsync("Player_" .. player.UserId, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		player:Kick("Data failed to load. Please rejoin. (" .. tostring(loadError) .. ")")
		return
	end

	profile:AddUserId(player.UserId)
	profile.OnReleased:Connect(function(reason: string)
		profiles[player] = nil
		if player.Parent == Players then
			player:Kick("Your data session ended. Please rejoin. (" .. reason .. ")")
		end
	end)

	if player.Parent ~= Players then
		profile:ReleaseAsync()
		return
	end

	profiles[player] = profile
	profile.Data.Coins += 1
end

local function onPlayerRemoving(player: Player)
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
