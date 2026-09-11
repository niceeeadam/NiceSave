--!nonstrict

--[[
	NiceSave
	An original, session-locked profile store for Roblox DataStoreService.

	Design goals:
	* one live writer per key (atomic lock + fencing token)
	* cached, directly editable profile data
	* periodic autosaves and graceful shutdown
	* bounded retries with request-budget awareness
	* schema migrations, reconciliation, metadata, user IDs, and mock mode

	This module must only be required by server Scripts.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Signal = require(script.Signal)
local DataUtils = require(script.DataUtils)

local deepCopy = DataUtils.deepCopy
local callWithoutYield = DataUtils.callWithoutYield
local isPositiveInteger = DataUtils.isPositiveInteger
local isNonNegativeInteger = DataUtils.isNonNegativeInteger
local isFiniteNumber = DataUtils.isFiniteNumber
local validateSerializable = DataUtils.validateSerializable
local jsonSize = DataUtils.jsonSize
local validateMetadata = DataUtils.validateMetadata
local reconcile = DataUtils.reconcile
local assertName = DataUtils.assertName
local validateKey = DataUtils.validateKey

if RunService:IsClient() then
	error("NiceSave can only be required on the server", 2)
end

local FORMAT = "NiceSave/1"
local DEFAULT_SCOPE = "global"
local MAX_KEY_LENGTH = 50
local MAX_DATA_BYTES = 4_000_000 -- Headroom below Roblox's 4,194,304-byte hard limit.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
}

export type SessionInfo = {
	Token: string,
	PlaceId: number,
	JobId: string,
	AcquiredAt: number,
	HeartbeatAt: number,
}

export type ProfileInfo = {
	CreatedAt: number,
	UpdatedAt: number,
	Revision: number,
	LoadCount: number,
	SchemaVersion: number,
	Session: SessionInfo?,
}

export type LoadOptions = {
	Timeout: number?,
	Cancel: (() -> boolean)?,
	OnLocked: ((SessionInfo) -> ("Wait" | "Cancel")?)?,
}

export type StoreOptions = {
	Scope: string?,
	AutoSaveInterval: number?,
	SessionTimeout: number?,
	LockRetryInterval: number?,
	LoadTimeout: number?,
	MaxRetries: number?,
	BaseRetryDelay: number?,
	MaxRetryDelay: number?,
	BudgetWaitTimeout: number?,
	MaxDataBytes: number?,
	SchemaVersion: number?,
	Migrations: { [number]: (data: any) -> any }?,
	AutoReconcile: boolean?,
	UseMock: boolean?,
}

export type Snapshot<T> = {
	Data: T,
	Info: ProfileInfo,
	UserIds: { number },
	Metadata: { [string]: any },
}

type InternalMeta = ProfileInfo

type Envelope = {
	_format: string,
	Data: any,
	Meta: InternalMeta,
}

type LoadingGate = {
	Done: boolean,
	Event: any,
	Result: any?,
	Error: string?,
}

type MockRecord = {
	Value: Envelope,
	UserIds: { number },
	Metadata: { [string]: any },
	Version: number,
	CreatedTime: number,
	UpdatedTime: number,
}

type InternalOptions = {
	Scope: string,
	AutoSaveInterval: number,
	SessionTimeout: number,
	LockRetryInterval: number,
	LoadTimeout: number,
	MaxRetries: number,
	BaseRetryDelay: number,
	MaxRetryDelay: number,
	BudgetWaitTimeout: number,
	MaxDataBytes: number,
	SchemaVersion: number,
	Migrations: { [number]: (data: any) -> any },
	AutoReconcile: boolean,
	UseMock: boolean,
}

local function copySession(session: SessionInfo?): SessionInfo?
	if session == nil then
		return nil
	end
	return {
		Token = session.Token,
		PlaceId = session.PlaceId,
		JobId = session.JobId,
		AcquiredAt = session.AcquiredAt,
		HeartbeatAt = session.HeartbeatAt,
	}
end

local function copyInfo(meta: InternalMeta): ProfileInfo
	return {
		CreatedAt = meta.CreatedAt,
		UpdatedAt = meta.UpdatedAt,
		Revision = meta.Revision,
		LoadCount = meta.LoadCount,
		SchemaVersion = meta.SchemaVersion,
		Session = copySession(meta.Session),
	}
end

local function normalizeOptions(options: StoreOptions?): InternalOptions
	assert(options == nil or type(options) == "table", "Store options must be a table")
	local source = options or {}
	local autoSaveInterval = source.AutoSaveInterval or 120
	local sessionTimeout = source.SessionTimeout or 600

	assert(type(autoSaveInterval) == "number" and autoSaveInterval >= 30, "AutoSaveInterval must be at least 30 seconds")
	assert(type(sessionTimeout) == "number" and sessionTimeout >= autoSaveInterval * 2, "SessionTimeout must be at least twice AutoSaveInterval")

	local result: InternalOptions = {
		Scope = source.Scope or DEFAULT_SCOPE,
		AutoSaveInterval = autoSaveInterval,
		SessionTimeout = sessionTimeout,
		LockRetryInterval = source.LockRetryInterval or 7,
		LoadTimeout = source.LoadTimeout or 60,
		MaxRetries = source.MaxRetries or 8,
		BaseRetryDelay = source.BaseRetryDelay or 0.5,
		MaxRetryDelay = source.MaxRetryDelay or 10,
		BudgetWaitTimeout = source.BudgetWaitTimeout or 10,
		MaxDataBytes = source.MaxDataBytes or MAX_DATA_BYTES,
		SchemaVersion = source.SchemaVersion or 1,
		Migrations = source.Migrations or {},
		AutoReconcile = if source.AutoReconcile == nil then true else source.AutoReconcile,
		UseMock = source.UseMock == true,
	}

	assertName(result.Scope, "Scope")
	assert(type(result.LockRetryInterval) == "number" and result.LockRetryInterval >= 1, "LockRetryInterval must be at least 1 second")
	assert(type(result.LoadTimeout) == "number" and result.LoadTimeout >= 0, "LoadTimeout cannot be negative")
	assert(type(result.MaxRetries) == "number" and result.MaxRetries >= 1 and result.MaxRetries % 1 == 0, "MaxRetries must be a positive integer")
	assert(type(result.BaseRetryDelay) == "number" and result.BaseRetryDelay >= 0, "BaseRetryDelay cannot be negative")
	assert(
		type(result.MaxRetryDelay) == "number" and result.MaxRetryDelay >= result.BaseRetryDelay,
		"MaxRetryDelay must be at least BaseRetryDelay"
	)
	assert(type(result.BudgetWaitTimeout) == "number" and result.BudgetWaitTimeout >= 0, "BudgetWaitTimeout cannot be negative")
	assert(
		type(result.MaxDataBytes) == "number" and result.MaxDataBytes > 0 and result.MaxDataBytes <= 4_194_304,
		"MaxDataBytes is outside Roblox's supported range"
	)
	assert(
		type(result.SchemaVersion) == "number" and result.SchemaVersion >= 1 and result.SchemaVersion % 1 == 0,
		"SchemaVersion must be a positive integer"
	)
	assert(type(result.Migrations) == "table", "Migrations must be a table")
	assert(type(result.AutoReconcile) == "boolean", "AutoReconcile must be a boolean")

	for version, migration in result.Migrations do
		assert(isPositiveInteger(version), "Migration keys must be positive integer schema versions")
		assert(type(migration) == "function", "Each migration must be a function")
	end

	return result
end

local Profile = {}
Profile.__index = Profile

local Store = {}
Store.__index = Store

export type Profile<T> = typeof(setmetatable({} :: {
	Data: T,
	Key: string,
	UserIds: { number },
	Metadata: { [string]: any },
	OnReleased: Signal<string>,
	OnSaved: Signal<number>,
}, Profile))

export type Store<T> = typeof(setmetatable({} :: {
	Name: string,
	Scope: string,
	OnLoaded: Signal<Profile<T>>,
	OnReleased: Signal<Profile<T>, string>,
}, Store))

local NiceSave = {
	IsClosing = false,
	OnError = Signal.new(),
	OnCorruption = Signal.new(),
	OnCriticalStateChanged = Signal.new(),
}

local ACTIVE_STORES: { [any]: boolean } = {}
local MOCK_BUCKETS: { [string]: { [string]: MockRecord } } = {}
local SHUTDOWN_BOUND = false
local ISSUE_TIMES: { number } = {}
local CRITICAL = false

local function reportIssue(storeName: string, key: string, operation: string, message: any)
	local now = os.clock()
	table.insert(ISSUE_TIMES, now)
	while ISSUE_TIMES[1] and now - ISSUE_TIMES[1] > 120 do
		table.remove(ISSUE_TIMES, 1)
	end

	NiceSave.OnError:Fire(tostring(message), storeName, key, operation)
	if #ISSUE_TIMES >= 5 and not CRITICAL then
		CRITICAL = true
		NiceSave.OnCriticalStateChanged:Fire(true)
	end
end

local function refreshCriticalState()
	if not CRITICAL then
		return
	end
	local now = os.clock()
	while ISSUE_TIMES[1] and now - ISSUE_TIMES[1] > 120 do
		table.remove(ISSUE_TIMES, 1)
	end
	if #ISSUE_TIMES < 5 then
		CRITICAL = false
		NiceSave.OnCriticalStateChanged:Fire(false)
	end
end

local function makeMockKeyInfo(record: MockRecord): any
	local keyInfo = {
		Version = tostring(record.Version),
		CreatedTime = record.CreatedTime,
		UpdatedTime = record.UpdatedTime,
	}

	function keyInfo:GetUserIds()
		return deepCopy(record.UserIds)
	end

	function keyInfo:GetMetadata()
		return deepCopy(record.Metadata)
	end

	return keyInfo
end

local function metadataFromKeyInfo(keyInfo: any): { [string]: any }
	if keyInfo == nil then
		return {}
	end
	local ok, value = pcall(function()
		return keyInfo:GetMetadata()
	end)
	return if ok and type(value) == "table" then deepCopy(value) else {}
end

local function userIdsFromKeyInfo(keyInfo: any): { number }
	if keyInfo == nil then
		return {}
	end
	local ok, value = pcall(function()
		return keyInfo:GetUserIds()
	end)
	return if ok and type(value) == "table" then deepCopy(value) else {}
end

function Store:_rawUpdate(key: string, transform: (Envelope?, any?) -> (Envelope?, { number }?, { [string]: any }?))
	if not self._options.UseMock then
		return self._dataStore:UpdateAsync(key, transform)
	end

	local bucket = self._mockBucket
	local record = bucket[key]
	local currentValue = if record then deepCopy(record.Value) else nil
	local currentKeyInfo = if record then makeMockKeyInfo(record) else nil
	local transformed = table.pack(transform(currentValue, currentKeyInfo))
	local newValue = transformed[1]

	if newValue == nil then
		return currentValue, currentKeyInfo
	end

	local nowMs = DateTime.now().UnixTimestampMillis
	local newRecord: MockRecord = {
		Value = deepCopy(newValue),
		UserIds = deepCopy(transformed[2] or {}),
		Metadata = deepCopy(transformed[3] or {}),
		Version = if record then record.Version + 1 else 1,
		CreatedTime = if record then record.CreatedTime else nowMs,
		UpdatedTime = nowMs,
	}
	bucket[key] = newRecord
	return deepCopy(newRecord.Value), makeMockKeyInfo(newRecord)
end

function Store:_rawGet(key: string)
	if not self._options.UseMock then
		return self._dataStore:GetAsync(key)
	end

	local record = self._mockBucket[key]
	if not record then
		return nil, nil
	end
	return deepCopy(record.Value), makeMockKeyInfo(record)
end

function Store:_waitForBudget(operation: string)
	if self._options.UseMock or self._options.BudgetWaitTimeout <= 0 then
		return
	end

	local deadline = os.clock() + self._options.BudgetWaitTimeout
	local function hasBudget(requestType: any): boolean
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		return not ok or budget > 0
	end

	while os.clock() < deadline do
		local ready = if operation == "Get"
			then hasBudget(Enum.DataStoreRequestType.StandardRead)
			else hasBudget(Enum.DataStoreRequestType.StandardRead) and hasBudget(Enum.DataStoreRequestType.StandardWrite)
		if ready then
			return
		end
		task.wait(0.5)
	end
end

function Store:_callWithRetry(operation: string, key: string, callback: () -> ...any): (boolean, ...any)
	local lastError = "Unknown DataStore error"

	for attempt = 1, self._options.MaxRetries do
		if (NiceSave.IsClosing or self._closing) and operation == "Load" then
			return false, "Server is shutting down"
		end

		self:_waitForBudget(if operation == "View" then "Get" else "Update")
		local results = table.pack(pcall(callback))
		if results[1] then
			return true, table.unpack(results, 2, results.n)
		end

		lastError = tostring(results[2])
		reportIssue(self.Name, key, operation, lastError)
		if attempt < self._options.MaxRetries then
			local exponential = self._options.BaseRetryDelay * (2 ^ (attempt - 1))
			local delaySeconds = math.min(self._options.MaxRetryDelay, exponential)
			delaySeconds *= 0.8 + math.random() * 0.4
			task.wait(delaySeconds)
		end
	end

	return false, lastError
end

local function newEnvelope(template: any, schemaVersion: number, session: SessionInfo): Envelope
	local now = os.time()
	return {
		_format = FORMAT,
		Data = deepCopy(template),
		Meta = {
			CreatedAt = now,
			UpdatedAt = now,
			Revision = 0,
			LoadCount = 1,
			SchemaVersion = schemaVersion,
			Session = copySession(session),
		},
	}
end

local function validateEnvelope(value: any): (boolean, string?)
	if type(value) ~= "table" then
		return false, "Stored value is not a table"
	end
	if value._format ~= FORMAT then
		return false, "Stored value is not in NiceSave/1 format"
	end
	if type(value.Data) ~= "table" then
		return false, "Stored profile Data is not a table"
	end
	if type(value.Meta) ~= "table" then
		return false, "Stored profile Meta is not a table"
	end

	local meta = value.Meta
	if not isFiniteNumber(meta.CreatedAt)
		or not isFiniteNumber(meta.UpdatedAt)
		or not isNonNegativeInteger(meta.Revision)
		or not isPositiveInteger(meta.LoadCount)
		or not isPositiveInteger(meta.SchemaVersion)
	then
		return false, "Stored profile metadata is malformed"
	end

	if meta.Session ~= nil then
		local session = meta.Session
		if type(session) ~= "table"
			or type(session.Token) ~= "string"
			or not isNonNegativeInteger(session.PlaceId)
			or type(session.JobId) ~= "string"
			or not isFiniteNumber(session.AcquiredAt)
			or not isFiniteNumber(session.HeartbeatAt)
		then
			return false, "Stored session lock is malformed"
		end
	end

	return true, nil
end

local function makeSession(token: string, serverId: string): SessionInfo
	local now = os.time()
	return {
		Token = token,
		PlaceId = game.PlaceId,
		JobId = serverId,
		AcquiredAt = now,
		HeartbeatAt = now,
	}
end

function Store:_finishGate(key: string, gate: LoadingGate, result: any?, message: string?)
	gate.Result = result
	gate.Error = message
	gate.Done = true
	self._loading[key] = nil
	gate.Event:Fire()
	task.delay(1, function()
		gate.Event:Destroy()
	end)
end

function Store:_runMigrations(data: any, storedVersion: number): (boolean, any?, string?)
	if storedVersion > self._options.SchemaVersion then
		return false, nil, string.format(
			"Stored schema version %d is newer than configured version %d",
			storedVersion,
			self._options.SchemaVersion
		)
	end

	local migrated = data
	for version = storedVersion + 1, self._options.SchemaVersion do
		local migration = self._options.Migrations[version]
		if migration == nil then
			return false, nil, string.format("Missing migration for schema version %d", version)
		end

		local migrationOk, result = callWithoutYield(migration, migrated)
		if not migrationOk then
			return false, nil, string.format("Migration to version %d failed: %s", version, tostring(result))
		end
		if result ~= nil then
			migrated = result
		end
		if type(migrated) ~= "table" then
			return false, nil, string.format("Migration to version %d did not produce a table", version)
		end
	end

	return true, migrated, nil
end

function Store:_claim(key: string, token: string): (Envelope?, { number }?, { [string]: any }?, SessionInfo?, string?)
	local desiredSession = makeSession(token, self._serverId)
	local lockedBy: SessionInfo? = nil
	local corruption: string? = nil
	local capturedUserIds: { number } = {}
	local capturedMetadata: { [string]: any } = {}

	local success, valueOrError, returnedKeyInfo = self:_callWithRetry("Load", key, function()
		return self:_rawUpdate(key, function(current, keyInfo)
			lockedBy = nil
			corruption = nil
			capturedUserIds = userIdsFromKeyInfo(keyInfo)
			capturedMetadata = metadataFromKeyInfo(keyInfo)

			if current == nil then
				return newEnvelope(self._template, self._options.SchemaVersion, desiredSession), capturedUserIds, capturedMetadata
			end

			local valid, message = validateEnvelope(current)
			if not valid then
				corruption = message or "Malformed stored profile"
				return nil
			end

			local currentSession = current.Meta.Session
			local isStale = currentSession ~= nil
				and os.time() - currentSession.HeartbeatAt >= self._options.SessionTimeout

			if currentSession ~= nil and currentSession.Token ~= token and not isStale then
				lockedBy = copySession(currentSession)
				return nil
			end

			local claimed = deepCopy(current)
			claimed.Meta.Session = copySession(desiredSession)
			claimed.Meta.LoadCount += 1
			claimed.Meta.UpdatedAt = os.time()
			return claimed, capturedUserIds, capturedMetadata
		end)
	end)

	if not success then
		return nil, nil, nil, nil, tostring(valueOrError)
	end
	if corruption ~= nil then
		NiceSave.OnCorruption:Fire(self.Name, key, corruption)
		return nil, nil, nil, nil, corruption
	end
	if lockedBy ~= nil then
		return nil, nil, nil, lockedBy, nil
	end

	local envelope = valueOrError
	local valid, message = validateEnvelope(envelope)
	if not valid then
		local detail = message or "UpdateAsync returned a malformed profile"
		NiceSave.OnCorruption:Fire(self.Name, key, detail)
		return nil, nil, nil, nil, detail
	end

	if returnedKeyInfo ~= nil then
		capturedUserIds = userIdsFromKeyInfo(returnedKeyInfo)
		capturedMetadata = metadataFromKeyInfo(returnedKeyInfo)
	end
	return envelope, capturedUserIds, capturedMetadata, nil, nil
end

function Store:_deactivate(profile, reason: string)
	if not profile._active then
		return
	end

	profile._active = false
	if self._active[profile.Key] == profile then
		self._active[profile.Key] = nil
	end
	profile.OnReleased:Fire(reason)
	self.OnReleased:Fire(profile, reason)
	task.delay(1, function()
		profile._saveFinished:Destroy()
	end)
end

function Store:_validateForSave(profile): (Envelope?, string?)
	local valid, message = validateSerializable(profile.Data)
	if not valid then
		return nil, message
	end

	local metadataValid, metadataMessage = validateMetadata(profile.Metadata)
	if not metadataValid then
		return nil, "Metadata " .. tostring(metadataMessage)
	end

	local userIdSet: { [number]: boolean } = {}
	for index, userId in profile.UserIds do
		if not isPositiveInteger(userId) then
			return nil, string.format("UserIds[%d] is not a positive integer", index)
		end
		if userIdSet[userId] then
			return nil, string.format("UserIds contains duplicate %d", userId)
		end
		userIdSet[userId] = true
	end

	local envelope: Envelope = {
		_format = FORMAT,
		Data = deepCopy(profile.Data),
		Meta = copyInfo(profile._meta),
	}
	local bytes, encodingError = jsonSize(envelope)
	if bytes == nil then
		return nil, "Profile could not be JSON encoded: " .. tostring(encodingError)
	end
	if bytes > self._options.MaxDataBytes then
		return nil, string.format("Profile is %d bytes; configured maximum is %d", bytes, self._options.MaxDataBytes)
	end
	return envelope, nil
end

function Store:_unlockWithoutSave(profile): boolean
	local lostLock = false
	local success = self:_callWithRetry("Unlock", profile.Key, function()
		return self:_rawUpdate(profile.Key, function(current, keyInfo)
			local valid = validateEnvelope(current)
			if not valid or current == nil or current.Meta.Session == nil or current.Meta.Session.Token ~= profile._token then
				lostLock = true
				return nil
			end

			local unlocked = deepCopy(current)
			unlocked.Meta.Session = nil
			unlocked.Meta.UpdatedAt = os.time()
			return unlocked, userIdsFromKeyInfo(keyInfo), metadataFromKeyInfo(keyInfo)
		end)
	end)
	return success and not lostLock
end

function Store:_saveProfile(profile, release: boolean): (boolean, string?)
	if not profile._active then
		return false, "Profile is not active"
	end

	while profile._saving do
		profile._saveFinished.Event:Wait()
		if not profile._active then
			return false, "Profile became inactive"
		end
	end

	profile._saving = true
	local snapshot, validationError = self:_validateForSave(profile)
	if snapshot == nil then
		profile._saving = false
		profile._saveFinished:Fire()
		reportIssue(self.Name, profile.Key, if release then "Release" else "Save", validationError)
		if release then
			self:_unlockWithoutSave(profile)
			self:_deactivate(profile, "InvalidData")
		end
		return false, validationError
	end

	local lostLock = false
	local savedRevision: number? = nil
	local savedMeta: InternalMeta? = nil
	local operation = if release then "Release" else "Save"
	local success, valueOrError = self:_callWithRetry(operation, profile.Key, function()
		return self:_rawUpdate(profile.Key, function(current)
			local valid = validateEnvelope(current)
			if not valid or current == nil or current.Meta.Session == nil or current.Meta.Session.Token ~= profile._token then
				lostLock = true
				return nil
			end

			local nextEnvelope = deepCopy(snapshot)
			nextEnvelope.Meta.CreatedAt = current.Meta.CreatedAt
			nextEnvelope.Meta.LoadCount = current.Meta.LoadCount
			nextEnvelope.Meta.Revision = current.Meta.Revision + 1
			nextEnvelope.Meta.UpdatedAt = os.time()
			if release then
				nextEnvelope.Meta.Session = nil
			else
				local activeSession = copySession(current.Meta.Session) :: SessionInfo
				activeSession.HeartbeatAt = os.time()
				nextEnvelope.Meta.Session = activeSession
			end
			savedRevision = nextEnvelope.Meta.Revision
			savedMeta = copyInfo(nextEnvelope.Meta)
			return nextEnvelope, deepCopy(profile.UserIds), deepCopy(profile.Metadata)
		end)
	end)

	profile._saving = false
	profile._saveFinished:Fire()

	if lostLock then
		self:_deactivate(profile, "SessionLost")
		return false, "The session lock is no longer owned by this server"
	end
	if not success then
		if release then
			self:_deactivate(profile, "ReleaseFailed")
		end
		return false, tostring(valueOrError)
	end

	if savedMeta ~= nil then
		profile._meta = savedMeta
	end
	profile._nextAutoSave = os.clock() + self._options.AutoSaveInterval
	profile.OnSaved:Fire(savedRevision or profile._meta.Revision)
	if release then
		self:_deactivate(profile, "Released")
	end
	return true, nil
end

function Store:LoadAsync(key: string, loadOptions: LoadOptions?): (any?, string?)
	local keyValid, keyError = validateKey(key)
	if not keyValid then
		return nil, keyError
	end
	if self._closing or NiceSave.IsClosing then
		return nil, "Store is shutting down"
	end

	local existing = self._active[key]
	if existing ~= nil and existing._active then
		return existing, nil
	end

	local otherGate: LoadingGate? = self._loading[key]
	if otherGate ~= nil then
		while not otherGate.Done do
			otherGate.Event.Event:Wait()
		end
		return otherGate.Result, otherGate.Error
	end

	local gate: LoadingGate = {
		Done = false,
		Event = Instance.new("BindableEvent"),
		Result = nil,
		Error = nil,
	}
	self._loading[key] = gate

	if loadOptions ~= nil and type(loadOptions) ~= "table" then
		self:_finishGate(key, gate, nil, "Load options must be a table")
		return nil, "Load options must be a table"
	end
	local options = loadOptions or {}
	local timeout = options.Timeout or self._options.LoadTimeout
	if type(timeout) ~= "number" or timeout < 0 then
		self:_finishGate(key, gate, nil, "Load Timeout must be a non-negative number")
		return nil, "Load Timeout must be a non-negative number"
	end
	if options.Cancel ~= nil and type(options.Cancel) ~= "function" then
		self:_finishGate(key, gate, nil, "Load Cancel must be a function")
		return nil, "Load Cancel must be a function"
	end
	if options.OnLocked ~= nil and type(options.OnLocked) ~= "function" then
		self:_finishGate(key, gate, nil, "Load OnLocked must be a function")
		return nil, "Load OnLocked must be a function"
	end
	local deadline = os.clock() + timeout
	local token = HttpService:GenerateGUID(false)

	while true do
		if self._closing or NiceSave.IsClosing then
			self:_finishGate(key, gate, nil, "Store is shutting down")
			return nil, "Store is shutting down"
		end
		if options.Cancel ~= nil then
			local cancelOk, shouldCancel = callWithoutYield(options.Cancel)
			if not cancelOk then
				local message = "Cancel callback failed: " .. tostring(shouldCancel)
				self:_finishGate(key, gate, nil, message)
				return nil, message
			end
			if type(shouldCancel) ~= "boolean" then
				local message = "Cancel callback must return a boolean"
				self:_finishGate(key, gate, nil, message)
				return nil, message
			end
			if shouldCancel then
				self:_finishGate(key, gate, nil, "Cancelled")
				return nil, "Cancelled"
			end
		end

		local envelope, userIds, metadata, lockedBy, claimError = self:_claim(key, token)
		if envelope ~= nil then
			if self._closing or NiceSave.IsClosing then
				local closingProfile = setmetatable({
					Data = envelope.Data,
					Key = key,
					UserIds = userIds or {},
					Metadata = metadata or {},
					OnReleased = Signal.new(),
					OnSaved = Signal.new(),
					_active = true,
					_meta = envelope.Meta,
					_token = token,
					_store = self,
					_saving = false,
					_saveFinished = Instance.new("BindableEvent"),
					_nextAutoSave = math.huge,
				}, Profile)
				self:_unlockWithoutSave(closingProfile)
				self:_deactivate(closingProfile, "Shutdown")
				self:_finishGate(key, gate, nil, "Store is shutting down")
				return nil, "Store is shutting down"
			end

			local migrationOk, migratedData, migrationError = self:_runMigrations(envelope.Data, envelope.Meta.SchemaVersion)
			if not migrationOk then
				local temporaryProfile = setmetatable({
					Data = envelope.Data,
					Key = key,
					UserIds = userIds or {},
					Metadata = metadata or {},
					OnReleased = Signal.new(),
					OnSaved = Signal.new(),
					_active = true,
					_meta = envelope.Meta,
					_token = token,
					_store = self,
					_saving = false,
					_saveFinished = Instance.new("BindableEvent"),
					_nextAutoSave = math.huge,
				}, Profile)
				self:_unlockWithoutSave(temporaryProfile)
				self:_deactivate(temporaryProfile, "MigrationFailed")
				self:_finishGate(key, gate, nil, migrationError)
				return nil, migrationError
			end

			local migrated = envelope.Meta.SchemaVersion < self._options.SchemaVersion
			envelope.Data = migratedData
			envelope.Meta.SchemaVersion = self._options.SchemaVersion
			if self._options.AutoReconcile then
				reconcile(envelope.Data, self._template)
			end

			local profile = setmetatable({
				Data = envelope.Data,
				Key = key,
				UserIds = userIds or {},
				Metadata = metadata or {},
				OnReleased = Signal.new(),
				OnSaved = Signal.new(),
				_active = true,
				_meta = envelope.Meta,
				_token = token,
				_store = self,
				_saving = false,
				_saveFinished = Instance.new("BindableEvent"),
				_nextAutoSave = os.clock() + self._options.AutoSaveInterval * math.random(),
			}, Profile)
			self._active[key] = profile

			if migrated then
				local saved, saveError = self:_saveProfile(profile, false)
				if not saved then
					if profile._active then
						self:_saveProfile(profile, true)
					end
					self:_finishGate(key, gate, nil, "Could not persist migration: " .. tostring(saveError))
					return nil, "Could not persist migration: " .. tostring(saveError)
				end
			end

			self:_finishGate(key, gate, profile, nil)
			self.OnLoaded:Fire(profile)
			return profile, nil
		end

		if claimError ~= nil then
			self:_finishGate(key, gate, nil, claimError)
			return nil, claimError
		end

		if lockedBy ~= nil and options.OnLocked ~= nil then
			local handlerOk, decision = callWithoutYield(options.OnLocked, copySession(lockedBy))
			if not handlerOk then
				local message = "OnLocked callback failed: " .. tostring(decision)
				self:_finishGate(key, gate, nil, message)
				return nil, message
			end
			if decision == "Cancel" then
				self:_finishGate(key, gate, nil, "Locked")
				return nil, "Locked"
			elseif decision ~= nil and decision ~= "Wait" then
				local message = "OnLocked callback must return 'Wait', 'Cancel', or nil"
				self:_finishGate(key, gate, nil, message)
				return nil, message
			end
		end

		if os.clock() >= deadline then
			self:_finishGate(key, gate, nil, "Timed out waiting for the session lock")
			return nil, "Timed out waiting for the session lock"
		end
		task.wait(math.min(self._options.LockRetryInterval * (0.8 + math.random() * 0.4), math.max(0, deadline - os.clock())))
	end
end

function Store:ViewAsync(key: string): (Snapshot<any>?, string?)
	local keyValid, keyError = validateKey(key)
	if not keyValid then
		return nil, keyError
	end

	local success, valueOrError, keyInfo = self:_callWithRetry("View", key, function()
		return self:_rawGet(key)
	end)
	if not success then
		return nil, tostring(valueOrError)
	end
	if valueOrError == nil then
		return nil, "NotFound"
	end

	local valid, message = validateEnvelope(valueOrError)
	if not valid then
		local detail = message or "Malformed stored profile"
		NiceSave.OnCorruption:Fire(self.Name, key, detail)
		return nil, detail
	end

	return {
		Data = deepCopy(valueOrError.Data),
		Info = copyInfo(valueOrError.Meta),
		UserIds = userIdsFromKeyInfo(keyInfo),
		Metadata = metadataFromKeyInfo(keyInfo),
	}, nil
end

function Store:GetActiveProfile(key: string): any?
	local profile = self._active[key]
	return if profile ~= nil and profile._active then profile else nil
end

function Store:GetActiveProfiles(): { any }
	local profiles = {}
	for _, profile in self._active do
		if profile._active then
			table.insert(profiles, profile)
		end
	end
	return profiles
end

function Store:IsMock(): boolean
	return self._options.UseMock
end

function Store:ShutdownAsync(): (boolean, { [string]: string })
	if self._shutdownDone then
		return true, {}
	end
	if self._shuttingDown then
		while not self._shutdownDone do
			task.wait()
		end
		return true, {}
	end

	self._shuttingDown = true
	self._closing = true
	while next(self._loading) ~= nil do
		task.wait()
	end
	local profiles = self:GetActiveProfiles()
	local remaining = #profiles
	local errors: { [string]: string } = {}

	for _, profile in profiles do
		task.spawn(function()
			local callOk, released, message = pcall(profile.ReleaseAsync, profile)
			if not callOk then
				errors[profile.Key] = tostring(released)
			elseif not released then
				errors[profile.Key] = tostring(message)
			end
			remaining -= 1
		end)
	end

	while remaining > 0 do
		task.wait()
	end

	self._shutdownDone = true
	self._shuttingDown = false
	ACTIVE_STORES[self] = nil
	return next(errors) == nil, errors
end

Store.DestroyAsync = Store.ShutdownAsync

function Store:_startAutoSaveLoop()
	task.spawn(function()
		while not self._closing do
			refreshCriticalState()
			local now = os.clock()
			local activeCount = 0
			local dueProfiles = {}

			for _, profile in self._active do
				if profile._active then
					activeCount += 1
					if not profile._saving and profile._nextAutoSave <= now then
						table.insert(dueProfiles, profile)
					end
				end
			end

			table.sort(dueProfiles, function(left, right)
				return left._nextAutoSave < right._nextAutoSave
			end)
			local savesThisStep = math.min(#dueProfiles, math.max(1, math.ceil(activeCount / self._options.AutoSaveInterval)))
			for index = 1, savesThisStep do
				local dueProfile = dueProfiles[index]
				dueProfile._nextAutoSave = now + self._options.AutoSaveInterval
				task.spawn(function()
					local ok = self:_saveProfile(dueProfile, false)
					if not ok and dueProfile._active then
						dueProfile._nextAutoSave = os.clock() + math.min(30, self._options.AutoSaveInterval / 4)
					end
				end)
			end

			task.wait(1)
		end
	end)
end

function Profile:IsActive(): boolean
	return self._active
end

function Profile:GetInfo(): ProfileInfo
	return copyInfo(self._meta)
end

function Profile:GetDataSize(): (number?, string?)
	return jsonSize({
		_format = FORMAT,
		Data = self.Data,
		Meta = self._meta,
	})
end

function Profile:Reconcile(): number
	if not self._active then
		return 0
	end
	return reconcile(self.Data, self._store._template)
end

function Profile:AddUserId(userId: number): boolean
	assert(isPositiveInteger(userId), "userId must be a positive integer")
	for _, existing in self.UserIds do
		if existing == userId then
			return false
		end
	end
	table.insert(self.UserIds, userId)
	return true
end

function Profile:RemoveUserId(userId: number): boolean
	for index, existing in self.UserIds do
		if existing == userId then
			table.remove(self.UserIds, index)
			return true
		end
	end
	return false
end

function Profile:SetMetadata(key: string, value: any)
	assert(type(key) == "string" and #key > 0 and #key <= MAX_KEY_LENGTH, "Metadata key must contain 1-50 bytes")
	if value == nil then
		self.Metadata[key] = nil
		return
	end
	local valid, message = validateSerializable(value)
	assert(valid, message)
	local previous = self.Metadata[key]
	self.Metadata[key] = deepCopy(value)
	local metadataValid, metadataMessage = validateMetadata(self.Metadata)
	if not metadataValid then
		self.Metadata[key] = previous
		error("Metadata " .. tostring(metadataMessage), 2)
	end
end

function Profile:GetMetadata(key: string): any
	return deepCopy(self.Metadata[key])
end

function Profile:SaveAsync(): (boolean, string?)
	return self._store:_saveProfile(self, false)
end

function Profile:ReleaseAsync(): (boolean, string?)
	return self._store:_saveProfile(self, true)
end

Profile.EndSessionAsync = Profile.ReleaseAsync

local function bindShutdown()
	if SHUTDOWN_BOUND then
		return
	end
	SHUTDOWN_BOUND = true

	game:BindToClose(function()
		NiceSave.IsClosing = true
		local remaining = 0
		for store in ACTIVE_STORES do
			remaining += 1
			task.spawn(function()
				local ok, message = pcall(store.ShutdownAsync, store)
				if not ok then
					reportIssue(store.Name, "<shutdown>", "Shutdown", message)
				end
				remaining -= 1
			end)
		end

		while remaining > 0 do
			task.wait()
		end
	end)
end

function NiceSave.new<T>(name: string, template: T, options: StoreOptions?): Store<T>
	assertName(name, "DataStore name")
	assert(type(template) == "table", "Profile template must be a table")
	local templateValid, templateError = validateSerializable(template)
	assert(templateValid, "Invalid profile template: " .. tostring(templateError))

	local normalized = normalizeOptions(options)
	local templateEnvelope = newEnvelope(template, normalized.SchemaVersion, makeSession("template-check", "template-check"))
	local templateBytes, templateEncodingError = jsonSize(templateEnvelope)
	assert(templateBytes ~= nil, "Profile template could not be encoded: " .. tostring(templateEncodingError))
	assert(
		(templateBytes :: number) <= normalized.MaxDataBytes,
		string.format("Profile template is %d bytes; configured maximum is %d", templateBytes :: number, normalized.MaxDataBytes)
	)
	local serverId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
	local store = setmetatable({
		Name = name,
		Scope = normalized.Scope,
		OnLoaded = Signal.new(),
		OnReleased = Signal.new(),
		_template = deepCopy(template),
		_options = normalized,
		_serverId = serverId,
		_dataStore = nil,
		_mockBucket = nil,
		_active = {},
		_loading = {},
		_closing = false,
		_shuttingDown = false,
		_shutdownDone = false,
	}, Store)

	if normalized.UseMock then
		local bucketName = normalized.Scope .. "/" .. name
		if MOCK_BUCKETS[bucketName] == nil then
			MOCK_BUCKETS[bucketName] = {}
		end
		store._mockBucket = MOCK_BUCKETS[bucketName]
	else
		store._dataStore = DataStoreService:GetDataStore(name, normalized.Scope)
	end

	ACTIVE_STORES[store] = true
	bindShutdown()
	store:_startAutoSaveLoop()
	return store :: any
end

NiceSave.New = NiceSave.new

function NiceSave.IsCriticalState(): boolean
	refreshCriticalState()
	return CRITICAL
end

function NiceSave.ClearMockStore(name: string, scope: string?)
	assertName(name, "DataStore name")
	local resolvedScope = scope or DEFAULT_SCOPE
	assertName(resolvedScope, "Scope")
	MOCK_BUCKETS[resolvedScope .. "/" .. name] = nil
end

NiceSave.Signal = Signal
NiceSave.Version = "0.1.0"

return NiceSave
