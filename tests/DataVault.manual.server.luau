local ServerScriptService = game:GetService("ServerScriptService")
local DataVault = require(ServerScriptService.DataVault)

local function expect(condition: any, message: string)
	if not condition then
		error("DataVault test failed: " .. message, 2)
	end
end

local function expectEqual(actual: any, expected: any, message: string)
	if actual ~= expected then
		error(string.format("DataVault test failed: %s (expected %s, got %s)", message, tostring(expected), tostring(actual)), 2)
	end
end

DataVault.ClearMockStore("DataVaultManual")

local template = {
	Coins = 0,
	Inventory = {},
	Settings = {
		Music = true,
		Effects = true,
	},
}

local commonOptions = {
	UseMock = true,
	AutoSaveInterval = 30,
	SessionTimeout = 60,
	LoadTimeout = 0,
}

local firstStore = DataVault.new("DataVaultManual", template, commonOptions)
local secondStore = DataVault.new("DataVaultManual", template, commonOptions)

local first, firstError = firstStore:LoadAsync("Player_1")
expect(first ~= nil, "first profile should load: " .. tostring(firstError))
expectEqual(first.Data.Coins, 0, "template should be copied")
expect(first.Data ~= template, "profile data must not alias the template")

first.Data.Coins = 42
first.Data.Settings.Effects = nil
expectEqual(first:Reconcile(), 1, "reconcile should restore one nested field")
expectEqual(first.Data.Settings.Effects, true, "reconcile should copy the default")
expect(first:AddUserId(1), "first user ID insertion should succeed")
expect(not first:AddUserId(1), "duplicate user ID insertion should be ignored")
first:SetMetadata("Environment", "ManualTest")

local saved, saveError = first:SaveAsync()
expect(saved, "save should succeed: " .. tostring(saveError))
expectEqual(first:GetInfo().Revision, 1, "save should increment the revision")

local locked, lockedError = secondStore:LoadAsync("Player_1", { Timeout = 0 })
expect(locked == nil, "a second store must not acquire a live lock")
expect(string.find(tostring(lockedError), "Timed out") ~= nil, "lock failure should report a timeout")

local snapshot, viewError = secondStore:ViewAsync("Player_1")
expect(snapshot ~= nil, "view should read a locked profile: " .. tostring(viewError))
expectEqual(snapshot.Data.Coins, 42, "view should contain saved data")
expectEqual(snapshot.UserIds[1], 1, "native user IDs should persist")
expectEqual(snapshot.Metadata.Environment, "ManualTest", "native metadata should persist")
snapshot.Data.Coins = -1
expectEqual(first.Data.Coins, 42, "view must return an isolated copy")

local released, releaseError = first:ReleaseAsync()
expect(released, "release should save and unlock: " .. tostring(releaseError))
expect(not first:IsActive(), "released profile should be inactive")

local reopened, reopenError = secondStore:LoadAsync("Player_1")
expect(reopened ~= nil, "released profile should reopen: " .. tostring(reopenError))
expectEqual(reopened.Data.Coins, 42, "data should survive reopen")
expectEqual(reopened:GetInfo().Revision, 2, "release should increment the revision")
expect(reopened:RemoveUserId(1), "stored user ID should be removable")

local bad: any = reopened.Data
bad.Cycle = bad
local invalidSaved, invalidError = reopened:SaveAsync()
expect(not invalidSaved, "cyclic data must be rejected")
expect(string.find(tostring(invalidError), "cyclic") ~= nil, "cycle error should explain the failure")
bad.Cycle = nil

local secondReleased, secondReleaseError = reopened:ReleaseAsync()
expect(secondReleased, "reopened profile should release: " .. tostring(secondReleaseError))

local firstShutdown = firstStore:ShutdownAsync()
local secondShutdown = secondStore:ShutdownAsync()
expect(firstShutdown and secondShutdown, "stores should shut down cleanly")

-- Migration test uses another store name so its mock records are isolated.
DataVault.ClearMockStore("DataVaultMigration")
local v1Store = DataVault.new("DataVaultMigration", { Diamonds = 0 }, commonOptions)
local oldProfile = v1Store:LoadAsync("Player_2")
expect(oldProfile ~= nil, "v1 profile should load")
oldProfile.Data.Diamonds = 9
expect(oldProfile:ReleaseAsync(), "v1 profile should release")
expect(v1Store:ShutdownAsync(), "v1 store should shut down")

local v2Store = DataVault.new("DataVaultMigration", { Gems = 0 }, {
	UseMock = true,
	AutoSaveInterval = 30,
	SessionTimeout = 60,
	LoadTimeout = 0,
	SchemaVersion = 2,
	Migrations = {
		[2] = function(data)
			data.Gems = data.Diamonds or 0
			data.Diamonds = nil
		end,
	},
})

local migrated, migrationError = v2Store:LoadAsync("Player_2")
expect(migrated ~= nil, "v2 profile should migrate: " .. tostring(migrationError))
expectEqual(migrated.Data.Gems, 9, "migration should transform data")
expectEqual(migrated:GetInfo().SchemaVersion, 2, "migration should update schema version")
expect(migrated:ReleaseAsync(), "migrated profile should release")
expect(v2Store:ShutdownAsync(), "v2 store should shut down")

print("DataVault manual tests passed")
