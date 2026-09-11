# NiceSave

NiceSave is an original, server-only Roblox profile persistence module inspired by the safety goals of ProfileService, ProfileStore, and Suphi's DataStore Module. It gives each key one active writer, keeps data cached in memory, autosaves it, and releases the lock when the session ends.

It is **not** a drop-in replacement for those modules and does not read their storage formats automatically.

## What it includes

- Atomic `UpdateAsync` session acquisition
- Per-session fencing tokens, so a server that loses its lock cannot overwrite the new owner
- Automatic stale-lock recovery
- Cached, directly editable `Profile.Data`
- Spread-out autosaves with retry backoff and request-budget awareness
- Immediate save and unlock on `ReleaseAsync()`
- Automatic server-shutdown handling through `BindToClose`
- Recursive template reconciliation
- Ordered schema migrations
- Native DataStore user IDs and metadata
- Data validation, cycle detection, JSON size checks, and corruption reporting
- Read-only snapshots that do not acquire a session
- Shared in-memory mock stores for Studio tests
- Exported Luau API types and no third-party runtime dependencies

## Installation

Sync the included Rojo project, or create a `ModuleScript` named `NiceSave` under `ServerScriptService` and copy the three source files using this structure:

```text
ServerScriptService
└── NiceSave                 ModuleScript — src/NiceSave.luau
    ├── DataUtils            ModuleScript — src/DataUtils.luau
    └── Signal               ModuleScript — src/Signal.luau
```

Game code still imports only the public entry point with `require(ServerScriptService.NiceSave)`. `DataUtils` and `Signal` are implementation details and should not be moved away from their parent.

NiceSave must never be required from a `LocalScript`. In Studio, use `UseMock = true` for safe tests. Only enable Studio API access against a separate test universe; Roblox warns that Studio can otherwise access the same stores as production.

## Player data example

```luau
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local NiceSave = require(ServerScriptService.NiceSave)

local TEMPLATE = {
	Coins = 0,
	Inventory = {},
	Settings = {
		Music = true,
	},
}

local PlayerStore = NiceSave.new("PlayerData_v1", TEMPLATE, {
	AutoSaveInterval = 120,
	SessionTimeout = 600,
	SchemaVersion = 1,
	UseMock = false,
})

local Profiles = {}

local function loadPlayer(player: Player)
	local profile, loadError = PlayerStore:LoadAsync("Player_" .. player.UserId, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if not profile then
		player:Kick("Your data could not be loaded. Please rejoin. (" .. tostring(loadError) .. ")")
		return
	end

	profile:AddUserId(player.UserId)
	profile.OnReleased:Connect(function(reason)
		Profiles[player] = nil
		if player.Parent == Players then
			player:Kick("Your data session ended. Please rejoin. (" .. reason .. ")")
		end
	end)

	if player.Parent ~= Players then
		profile:ReleaseAsync()
		return
	end

	Profiles[player] = profile
	profile.Data.Coins += 10
end

Players.PlayerAdded:Connect(loadPlayer)
Players.PlayerRemoving:Connect(function(player)
	local profile = Profiles[player]
	if profile then
		Profiles[player] = nil
		profile:ReleaseAsync()
	end
end)

for _, player in Players:GetPlayers() do
	task.spawn(loadPlayer, player)
end
```

The module binds its own shutdown callback and releases all active profiles. You do not need a second `BindToClose` handler for NiceSave.

## Leaderboard example

[`examples/Leaderboard.server.luau`](examples/Leaderboard.server.luau) creates Roblox's built-in `leaderstats` folder and persists each player's `Coins`, `Wins`, and `Level` inside their NiceSave profile. Put the script in `ServerScriptService` beside the `NiceSave` ModuleScript.

The example includes an `incrementStat` helper for trusted server-side rewards. Keep stat changes on the server; do not accept arbitrary values from a client RemoteEvent. This example controls the stats shown beside players in the player list. A global top-player ranking across servers is a separate feature and requires an `OrderedDataStore`.

## API

### `NiceSave.new(name, template, options?) -> Store`

Creates a store. Creating it does not issue a DataStore request.

| Option | Default | Meaning |
| --- | ---: | --- |
| `Scope` | `"global"` | Roblox DataStore scope |
| `AutoSaveInterval` | `120` | Seconds between profile heartbeat/saves; minimum 30 |
| `SessionTimeout` | `600` | Age at which an abandoned lock can be acquired; must be at least 2× autosave |
| `LockRetryInterval` | `7` | Base delay between lock attempts |
| `LoadTimeout` | `60` | Default maximum time spent waiting for another live session |
| `MaxRetries` | `8` | Attempts for a failed Roblox request |
| `BaseRetryDelay` | `0.5` | Initial exponential-backoff delay |
| `MaxRetryDelay` | `10` | Retry-delay ceiling |
| `BudgetWaitTimeout` | `10` | How long to wait for visible request budget before trying anyway |
| `MaxDataBytes` | `4,000,000` | Conservative encoded entry limit below Roblox's hard limit |
| `SchemaVersion` | `1` | Current data schema |
| `Migrations` | `{}` | Functions keyed by their destination schema version |
| `AutoReconcile` | `true` | Fill absent string-keyed fields from the template after load |
| `UseMock` | `false` | Use an in-memory backend shared by same-name mock stores |

### Store methods

- `Store:LoadAsync(key, options?) -> Profile?, error?` acquires a live session. Concurrent calls on the same store/key share one result.
- `Store:ViewAsync(key) -> Snapshot?, error?` reads without taking a lock and never writes.
- `Store:GetActiveProfile(key) -> Profile?` returns this store's locally cached profile.
- `Store:GetActiveProfiles() -> {Profile}` returns all active local profiles.
- `Store:IsMock() -> boolean` reports the selected backend.
- `Store:ShutdownAsync() -> success, errorsByKey` releases every profile and stops autosaving.

`LoadAsync` accepts `Timeout`, a `Cancel` callback, and an `OnLocked(sessionInfo)` callback. `OnLocked` may return `"Cancel"`; returning `"Wait"` or nothing continues waiting. NiceSave intentionally has no immediate force-steal switch. A live owner must release, or its heartbeat must become stale, before a different server can own the key.

`Cancel`, `OnLocked`, and migration callbacks must not yield. This keeps shutdown and lock handling bounded; NiceSave treats a yielding callback as an error.

### Profile members and methods

- `Profile.Data` is the mutable data table.
- `Profile.Key` is the DataStore key.
- `Profile.UserIds` and `Profile.Metadata` are saved using Roblox's native key info.
- `Profile:IsActive()` confirms that this server still owns the session.
- `Profile:GetInfo()` returns a copy of timestamps, revision, load count, schema version, and session details.
- `Profile:GetDataSize()` estimates the JSON-encoded envelope size.
- `Profile:Reconcile()` adds missing string-keyed template fields.
- `Profile:AddUserId(id)` / `Profile:RemoveUserId(id)` manage GDPR-associated IDs.
- `Profile:SetMetadata(key, value)` / `Profile:GetMetadata(key)` safely manage metadata values.
- `Profile:SaveAsync()` saves and refreshes the lock heartbeat.
- `Profile:ReleaseAsync()` atomically saves and clears the lock.
- `Profile.OnSaved(revision)` and `Profile.OnReleased(reason)` are signals.

`EndSessionAsync` is an alias for `ReleaseAsync`.

### Module signals

```luau
NiceSave.OnError:Connect(function(message, storeName, key, operation)
	warn(message, storeName, key, operation)
end)

NiceSave.OnCorruption:Connect(function(storeName, key, message)
	-- Alert your telemetry. NiceSave refuses to overwrite the malformed value.
end)

NiceSave.OnCriticalStateChanged:Connect(function(isCritical)
	-- Critical means at least five request errors occurred in the last two minutes.
end)
```

Listener callbacks run in their own tasks, so one listener cannot block a save or another listener.

## Schema migrations

Migrations are keyed by the version they produce. New profiles begin at the current version; only older saved profiles run the chain. A migrated profile is saved before `LoadAsync` returns.

Migration functions must be deterministic and must not yield. NiceSave rejects a yielding migration and safely releases the claimed session without replacing the stored data.

```luau
local Store = NiceSave.new("PlayerData_v1", TEMPLATE_V3, {
	SchemaVersion = 3,
	Migrations = {
		[2] = function(data)
			data.Gems = data.Diamonds or 0
			data.Diamonds = nil
		end,
		[3] = function(data)
			data.Settings = data.Settings or { Music = true }
			return data -- Optional; mutating in place also works.
		end,
	},
})
```

Do not remove an old migration until no stored profile can still have the preceding schema version.

## Storage rules

Data may contain booleans, finite numbers, valid UTF-8 strings, and tables. Table keys must be all strings or a contiguous `1..n` numeric array. Mixed tables, sparse arrays, cycles, functions, Instances, Roblox datatypes, and other userdata are rejected before save.

Keep metadata small: Roblox currently permits 50 bytes for a metadata key, 250 for a value, and 300 total. NiceSave conservatively verifies the JSON-encoded metadata table against 300 bytes.

Roblox documents a 50-character limit for store names, scopes, and keys and a 4,194,304-character per-key value limit. `UpdateAsync` is used because Roblox explicitly recommends it for multi-server changes; the callback never yields. See the official [DataStore guide](https://create.roblox.com/docs/cloud-services/data-stores), [limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits), and [best practices](https://create.roblox.com/docs/cloud-services/data-stores/best-practices).

## Important production notes

- This code has defensive mechanisms, but a new persistence library should be soak-tested with mock data and a private test universe before production rollout.
- NiceSave is optimized for one long-lived owner per key, especially player profiles. It is not an OrderedDataStore leaderboard or a high-frequency cross-server database.
- A stale takeover is intentionally delayed. Lowering `SessionTimeout` too far can cause temporary dual gameplay even though fencing still prevents the old server from saving.
- Never mutate profile data after `Profile:IsActive()` becomes false.
- For purchases or trades, build idempotent transaction IDs into your own data model. Session locking prevents concurrent writers; it does not make an entire multi-profile trade atomic.

## Tests

[`tests/NiceSave.manual.server.luau`](tests/NiceSave.manual.server.luau) is a dependency-free Studio regression script. Sync [`test.project.json`](test.project.json), start a server, and check for `NiceSave manual tests passed`.

## License

MIT. See [`LICENSE`](LICENSE).
