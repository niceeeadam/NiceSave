--!nonstrict

-- Serialization, validation, and table helpers shared by NiceSave.

local HttpService = game:GetService("HttpService")

local MAX_KEY_LENGTH = 50
local MAX_NAME_LENGTH = 50
local MAX_METADATA_BYTES = 300
local MAX_SERIALIZATION_DEPTH = 64

local DataUtils = {}

function DataUtils.deepCopy(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	if visited[value] then
		return visited[value]
	end

	local copy = {}
	visited[value] = copy
	for key, child in value do
		copy[DataUtils.deepCopy(key, visited)] = DataUtils.deepCopy(child, visited)
	end
	return copy
end

function DataUtils.callWithoutYield(callback: (...any) -> ...any, ...: any): (boolean, ...any)
	local thread = coroutine.create(callback)
	local results = table.pack(coroutine.resume(thread, ...))
	if not results[1] then
		return false, tostring(results[2])
	end
	if coroutine.status(thread) ~= "dead" then
		pcall(coroutine.close, thread)
		return false, "Callback yielded"
	end
	return true, table.unpack(results, 2, results.n)
end

function DataUtils.isPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

function DataUtils.isNonNegativeInteger(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

function DataUtils.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function DataUtils.validateSerializable(root: any, maxDepth: number?): (boolean, string?)
	local ancestors: { [any]: boolean } = {}
	local depthLimit = maxDepth or MAX_SERIALIZATION_DEPTH

	local function visit(value: any, path: string, depth: number): (boolean, string?)
		local valueType = typeof(value)
		if valueType == "nil" or valueType == "boolean" or valueType == "string" then
			return true, nil
		end
		if valueType == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return false, path .. " contains NaN or infinity"
			end
			return true, nil
		end
		if valueType ~= "table" then
			return false, string.format("%s contains unsupported %s", path, valueType)
		end
		if depth > depthLimit then
			return false, path .. " exceeds the maximum nesting depth"
		end
		if ancestors[value] then
			return false, path .. " contains a cyclic table reference"
		end

		ancestors[value] = true
		local hasStringKeys = false
		local hasNumberKeys = false
		local largestIndex = 0
		local numberKeyCount = 0

		for key, child in value do
			local keyType = type(key)
			if keyType == "string" then
				hasStringKeys = true
			elseif DataUtils.isPositiveInteger(key) then
				hasNumberKeys = true
				numberKeyCount += 1
				largestIndex = math.max(largestIndex, key)
			else
				ancestors[value] = nil
				return false, path .. " has a key that is not a string or positive integer"
			end

			local ok, message = visit(child, string.format("%s[%s]", path, tostring(key)), depth + 1)
			if not ok then
				ancestors[value] = nil
				return false, message
			end
		end

		ancestors[value] = nil
		if hasStringKeys and hasNumberKeys then
			return false, path .. " mixes string and numeric keys"
		end
		if hasNumberKeys and largestIndex ~= numberKeyCount then
			return false, path .. " is a sparse numeric array"
		end
		return true, nil
	end

	return visit(root, "Data", 1)
end

function DataUtils.jsonSize(value: any): (number?, string?)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if not ok then
		return nil, tostring(encoded)
	end
	return #encoded, nil
end

function DataUtils.validateMetadata(metadata: any): (boolean, string?)
	local valid, message = DataUtils.validateSerializable(metadata)
	if not valid then
		return false, message
	end
	if type(metadata) ~= "table" then
		return false, "must be a table"
	end

	for key, value in metadata do
		if type(key) ~= "string" or #key == 0 or #key > MAX_KEY_LENGTH then
			return false, "keys must contain 1-50 bytes"
		end
		local valueBytes, encodingError = DataUtils.jsonSize(value)
		if valueBytes == nil then
			return false, "value for " .. key .. " could not be encoded: " .. tostring(encodingError)
		end
		if valueBytes > 250 then
			return false, string.format("value for %s is %d bytes; Roblox allows at most 250", key, valueBytes)
		end
	end

	local metadataBytes, metadataEncodingError = DataUtils.jsonSize(metadata)
	if metadataBytes == nil then
		return false, "could not be encoded: " .. tostring(metadataEncodingError)
	end
	if metadataBytes > MAX_METADATA_BYTES then
		return false, string.format("is %d bytes; Roblox allows at most %d", metadataBytes, MAX_METADATA_BYTES)
	end
	return true, nil
end

function DataUtils.reconcile(target: any, template: any): number
	if type(target) ~= "table" or type(template) ~= "table" then
		return 0
	end

	local changes = 0
	for key, defaultValue in template do
		if type(key) == "string" then
			if target[key] == nil then
				target[key] = DataUtils.deepCopy(defaultValue)
				changes += 1
			elseif type(target[key]) == "table" and type(defaultValue) == "table" then
				changes += DataUtils.reconcile(target[key], defaultValue)
			end
		end
	end
	return changes
end

function DataUtils.assertName(value: any, label: string)
	assert(type(value) == "string", label .. " must be a string")
	assert(#value > 0, label .. " cannot be empty")
	assert(#value <= MAX_NAME_LENGTH, label .. " cannot exceed 50 bytes")
	assert(utf8.len(value) ~= nil, label .. " must be valid UTF-8")
end

function DataUtils.validateKey(key: any): (boolean, string?)
	if type(key) ~= "string" then
		return false, "Key must be a string"
	end
	if #key == 0 then
		return false, "Key cannot be empty"
	end
	if #key > MAX_KEY_LENGTH then
		return false, "Key cannot exceed 50 bytes"
	end
	if utf8.len(key) == nil then
		return false, "Key must be valid UTF-8"
	end
	return true, nil
end

return DataUtils
