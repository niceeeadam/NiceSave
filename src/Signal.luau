--!strict

-- Lightweight asynchronous signals used by NiceSave's public events.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	return setmetatable({
		_nextId = 0,
		_handlers = {},
	}, Signal) :: any
end

function Signal:Connect(callback)
	assert(type(callback) == "function", "Signal callback must be a function")

	self._nextId += 1
	local id = self._nextId
	self._handlers[id] = callback

	local connection = {
		Connected = true,
	} :: any

	function connection:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected = false
		Signal._disconnect(connection._signal, connection._id)
	end

	connection._signal = self
	connection._id = id
	return connection
end

function Signal:Once(callback)
	local connection: Connection? = nil
	local fired = false
	connection = self:Connect(function(...)
		if fired then
			return
		end
		fired = true
		if connection then
			connection:Disconnect()
		end
		callback(...)
	end)
	return connection :: Connection
end

function Signal:_disconnect(id)
	self._handlers[id] = nil
end

function Signal:Fire(...)
	local arguments = table.pack(...)
	for _, callback in self._handlers do
		task.spawn(function()
			local ok, message = xpcall(function()
				callback(table.unpack(arguments, 1, arguments.n))
			end, debug.traceback)
			if not ok then
				warn("[NiceSave] Signal listener failed:\n" .. tostring(message))
			end
		end)
	end
end

return Signal
