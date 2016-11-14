local next = next
local pairs = pairs
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local rawset = rawset
local table = table

local tracedoc = {}
local NULL = setmetatable({} , { __tostring = function() return "NULL" end })	-- nil
tracedoc.null = NULL
local tracedoc_type = setmetatable({}, { __tostring = function() return "TRACEDOC" end })
local tracedoc_len = setmetatable({} , { __mode = "kv" })

local function doc_next(doc, last_key)
	local lastversion = doc._lastversion
	if last_key == nil or lastversion[last_key] ~= nil then
		local next_key, v = next(lastversion, last_key)
		if next_key ~= nil then
			return next_key, doc[next_key]
		end
		last_key = nil
	end

	local changes = doc._changes._keys
	while true do
		local next_key = next(changes, last_key)
		if next_key == nil then
			return
		end
		local v = doc[next_key]
		if v ~= nil then
			return next_key, v
		end
		last_key = next_key
	end
end

local function doc_pairs(doc)
	return doc_next, doc
end

local function find_length_after(doc, idx)
	local v = doc[idx + 1]
	if v == nil then
		return idx
	end
	repeat
		idx = idx + 1
		v = doc[idx + 1]
	until v == nil
	tracedoc_len[doc] = idx
	return idx
end

local function find_length_before(doc, idx)
	if idx <= 1 then
		tracedoc_len[doc] = nil
		return 0
	end
	repeat
		idx = idx - 1
		v = doc[idx]
	until v ~= nil
	tracedoc_len[doc] = idx
	return idx
end

local function doc_len(doc)
	local len = tracedoc_len[doc]
	if len == nil then
		len = #doc._lastversion
		tracedoc_len[doc] = len
	end
	if len == 0 then
		return find_length_after(doc, 0)
	end
	local v = doc[len]
	if v == nil then
		return find_length_before(doc, len)
	end
	return find_length_after(doc, len)
end

local function doc_change(t, k, v)
	rawset(t,k,v)
	if v == nil then
		if t._keys[k] then	-- already set
			t._doc._lastversion[k] = nil
		elseif t._doc._lastversion[k] == nil then	-- ignore since lastversion is nil
			return
		end
		t._doc._lastversion[k] = nil
	end
	t._keys[k] = true
end

function tracedoc.new(init)
	local doc = {
		_changes = { _keys = {} , _doc = nil },
		_lastversion = {},
	}
	doc._changes._doc = doc
	setmetatable(doc._changes, {
		__index = doc._lastversion,
		__newindex = doc_change,
	})
	setmetatable(doc, {
		__newindex = doc._changes,
		__index = doc._changes,
		__pairs = doc_pairs,
		__len = doc_len,
		__metatable = tracedoc_type,	-- avoid copy by ref
	})
	if init then
		for k,v in pairs(init) do
			doc[k] = v
		end
		tracedoc.commit(doc)
	end
	return doc
end

local function doc_copy(doc, k, sub_doc)
	local target_doc = doc[k]
	if type(target_doc) ~= "table" then
		target_doc = tracedoc.new()
		doc[k] = target_doc
		for k,v in pairs(sub_doc) do
			target_doc[k] = v
		end
	else
		for k in pairs(target_doc) do
			if sub_doc[k] == nil then
				target_doc[k] = nil
			end
		end
		for k,v in pairs(sub_doc) do
			if target_doc[k] ~= v then
				target_doc[k] = v
			end
		end
	end
	return target_doc
end

function tracedoc.commit(doc, result, prefix)
	if doc._ignore then
		return result
	end
	local lastversion = doc._lastversion
	local changes = doc._changes
	local keys = changes._keys
	local dirty = false
	for k in pairs(keys) do
		local v = changes[k]
		keys[k] = nil
		local change_flag = true
		if type(v) == "table" then
			local vt = getmetatable(v)
			if vt == nil or vt == tracedoc_type then
				v = doc_copy(lastversion, k, v)
				lastversion[k] = v
				change_flag = false
			elseif v ~= lastversion[k] then
				lastversion[k] = v
			else
				change_flag = false
			end
		elseif v == nil then
			v = NULL
			-- lastversion[k] has already set to nil
		elseif lastversion[k] ~= v then
			lastversion[k] = v
		else
			change_flag = false
		end
		if change_flag then
			dirty = true
			if result then
				local key = prefix and prefix .. k or k
				result[key] = v
				result._n = (result._n or 0) + 1
			end
		end
		doc._changes[k] = nil
	end
	for k,v in pairs(lastversion) do
		if getmetatable(v) == tracedoc_type then
			if v._opaque then
				if tracedoc.commit(v) and result then
					result[k] = v
					dirty = dirty
				end
			elseif result then
				local key = (prefix and prefix .. k or k) .. "."
				if not dirty then
					local n = result._n
					tracedoc.commit(v, result, key)
					if n ~= result._n then
						dirty = true
					end
				else
					tracedoc.commit(v, result, key)
				end
			else
				dirty = dirty or tracedoc.commit(v)
			end
		end
	end
	return result or dirty
end

function tracedoc.ignore(doc, enable)
	rawset(doc, "_ignore", enable)	-- ignore it during commit when enable
end

function tracedoc.opaque(doc, enable)
	rawset(doc, "_opaque", enable)
end

----- change set

local function genkey(keys, key)
	if keys[key] then
		return
	end
	key = key:gsub("(%.)(%d+)","[%2]")
	key = key:gsub("^(%d+)","[%1]")
	keys[key] = assert(load ("return function(doc) return doc.".. key .." end"))()
end

local function insert_tag(tags, tag, item, n)
	local v = { table.unpack(item, n, #item) }
	local t = tags[tag]
	if not t then
		tags[tag] = { v }
	else
		table.insert(t, v)
	end
	return v
end

function tracedoc.changeset(map)
	local set = {
		watching_n = 0,
		watching = {} ,
		mapping = {} ,
		keys = {},
		tags = {},
	}
	for _,v in ipairs(map) do
		local tag = v[1]
		if type(tag) == "string" then
			v = insert_tag(set.tags, tag, v, 2)
		else
			v = insert_tag(set.tags, "", v, 1)
		end

		local n = #v
		assert(n >=2 and type(v[1]) == "function")
		if n == 2 then
			local f = v[1]
			local k = v[2]
			local tq = type(set.watching[k])
			genkey(set.keys, k)
			if tq == "nil" then
				set.watching[k] = f
				set.watching_n = set.watching_n + 1
			elseif tq == "function" then
				local q = { set.watching[k], f }
				set.watching[k] = q
			else
				assert (tq == "table")
				table.insert(set.watching[k], q)
			end
		else
			table.insert(set.mapping, { table.unpack(v) })
			for i = 2, #v do
				genkey(set.keys, v[i])
			end
		end
	end
	return set
end

local function do_funcs(doc, funcs, v)
	if v == NULL then
		v = nil
	end
	if type(funcs) == "function" then
		funcs(doc, v)
	else
		for _, func in ipairs(funcs) do
			func(doc, v)
		end
	end
end

local function do_mapping(doc, mapping, changes, keys, args)
	local n = #mapping
	for i=2,n do
		local key = mapping[i]
		local v = changes[key]
		if v == nil then
			v = keys[key](doc)
		elseif v == NULL then
			v = nil
		end
		args[i-1] = v
	end
	mapping[1](doc, table.unpack(args,1,n-1))
end

function tracedoc.mapchange(doc, set, c)
	local changes = tracedoc.commit(doc, c or {})
	local changes_n = changes._n or 0
	if changes_n == 0 then
		return changes
	end
	if changes_n > set.watching_n then
		-- a lot of changes
		for key, funcs in pairs(set.watching) do
			local v = changes[key]
			if v then
				do_funcs(doc, funcs, v)
			end
		end
	else
		-- a lot of watching funcs
		local watching_func = set.watching
		for key, v in pairs(changes) do
			local funcs = watching_func[key]
			if funcs then
				do_funcs(doc, funcs, v)
			end
		end
	end
	-- mapping
	local keys = set.keys
	local tmp = {}
	for _, mapping in ipairs(set.mapping) do
		for i=2,#mapping do
			local key = mapping[i]
			if changes[key] then
				do_mapping(doc, mapping, changes, keys, tmp)
				break
			end
		end
	end
	return changes
end

function tracedoc.mapupdate(doc, set, filter_tag)
	local args = {}
	local keys = set.keys
	for tag, items in pairs(set.tags) do
		if tag == filter_tag or filter_tag == nil then
			for _, mapping in ipairs(items) do
				local n = #mapping
				for i=2,n do
					local key = mapping[i]
					local v = keys[key](doc)
					args[i-1] = v
				end
				mapping[1](doc, table.unpack(args,1,n-1))
			end
		end
	end
end

return tracedoc
