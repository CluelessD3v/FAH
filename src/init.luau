--!strict
--[[
	FAH (Shared)
	============
	Author: Clueless_Dev (1761758398)
	Updated: 10/05/26

	Fetch Assets Here keeps canonical asset templates in ServerStorage and
	replicates only selected prefabs to clients. It also supports querying
	server-only asset metadata without cloning or replicating the full assets.
]]

const RunService        = game:GetService('RunService')
const ReplicatedStorage = game:GetService('ReplicatedStorage')
const ServerStorage     = game:GetService('ServerStorage')

const Module = {
	assetIds = {} :: { string },
}

--[=[
	FAH — Fetch Assets Here
	=======================

	A tool that allows you to keep all your assets in one place and have
	both the server and client clone them through the same API, regardless
	of where they physically live (Workspace included).

	You choose what the client gets — only assets you explicitly replicate
	ever land there, which keeps memory lean and avoids managing separate
	asset trees across Workspace, ReplicatedStorage, and ServerStorage.

	On the client, fetches use WaitForChild so they yield until the asset
	arrives rather than failing immediately. Use the optional `timeout`
	parameter to tune how long to wait, or pass 0 to skip waiting entirely.

	Quick reference:
		- `registerAsset`  — give FAH your template to hold onto.
		- `replicateAsset` — push it to ReplicatedStorage for the client.
		- `clonePrefab`    — get a fresh clone, works the same on both sides.

	Each asset is identified by an "asset id":
		- Derived from attributes listed in `Module.assetIds`.
		- Falls back to `instance.Name` if none are found.
]=]

export type QueryRow = {
	properties : {[string]: any},
	attributes : {[string]: any},
	tags       : {[string]: boolean},
}

export type QueryResult = {[string]: QueryRow}

const function getOrCreateFolder(parent: Instance, name: string): Folder
	const existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA('Folder'), `FAH expected "{name}" to be a Folder`)
		return existing
	end

	const folder = Instance.new('Folder')
	folder.Name = name
	folder.Parent = parent
	return folder
end

const function getOrCreateRemoteEvent(name: string): RemoteEvent
	const existing = script:FindFirstChild(name)
	if existing then
		assert(existing:IsA('RemoteEvent'), `FAH expected "{name}" to be a RemoteEvent`)
		return existing
	end

	const remote = Instance.new('RemoteEvent')
	remote.Name = name
	remote.Parent = script
	return remote
end

const function getOrCreateRemoteFunction(name: string): RemoteFunction
	const existing = script:FindFirstChild(name)
	if existing then
		assert(existing:IsA('RemoteFunction'), `FAH expected "{name}" to be a RemoteFunction`)
		return existing
	end

	const remote = Instance.new('RemoteFunction')
	remote.Name = name
	remote.Parent = script
	return remote
end

const assetPool = getOrCreateFolder(ReplicatedStorage, '__AssetPool__')
const assetRequested = getOrCreateRemoteEvent('AssetRequested')
const poolAssets = getOrCreateRemoteEvent('PoolAssets')
const assetQuery = if RunService:IsServer()
	then getOrCreateRemoteFunction('AssetQuery')
	else script:WaitForChild('AssetQuery') :: RemoteFunction

local assetRegister: Folder? = nil

const function safeIndex(container: Instance?, name: string): Instance?
	if not container then
		return nil
	end
	const ok, result = xpcall(function()
		const indexedContainer = container :: any
		return indexedContainer[name]
	end, function()
		return nil
	end)
	return ok and result or nil
end

const function getAssetId(instance: Instance): string
	for _, key in Module.assetIds do
		const value = instance:GetAttribute(key)
		if type(value) == 'string' then
			return value
		end
	end
	return instance.Name
end

const function isEmptyQuery(properties: { string }, attributes: { string }, tags: { string }): boolean
	return #properties == 0 and #attributes == 0 and #tags == 0
end

const function readProperty(instance: Instance, propertyName: string): (boolean, any)
	return pcall(function()
		const readableInstance = instance :: any
		return readableInstance[propertyName]
	end)
end

const function buildMatchId(root: Instance, instance: Instance): string
	const segments: { string } = {}
	local current: Instance? = instance

	while current and current ~= root do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end

	return table.concat(segments, '/')
end

const function getUniqueMatchId(baseId: string, results: QueryResult, collisionCounts: {[string]: number}): string
	if not results[baseId] then
		collisionCounts[baseId] = 1
		return baseId
	end

	const count = (collisionCounts[baseId] or 1) + 1
	collisionCounts[baseId] = count
	return `{baseId}[{count}]`
end

const function buildQueryRow(instance: Instance, properties: { string }, attributes: { string }, tags: { string }): QueryRow
	const propertyValues: {[string]: any} = {}
	const attributeValues: {[string]: any} = {}
	const tagValues: {[string]: boolean} = {}

	for _, propertyName in properties do
		const ok, value = readProperty(instance, propertyName)
		if not ok then
			warn(`FAH.query: failed to read property "{propertyName}" from "{instance:GetFullName()}"`)
			continue
		end
		propertyValues[propertyName] = value
	end

	for _, attributeName in attributes do
		attributeValues[attributeName] = instance:GetAttribute(attributeName)
	end

	for _, tagName in tags do
		tagValues[tagName] = instance:HasTag(tagName)
	end

	return {
		properties = propertyValues,
		attributes = attributeValues,
		tags       = tagValues,
	}
end

const function queryRegistry(selector: string, properties: { string }, attributes: { string }, tags: { string }): QueryResult
	if selector == '' then
		warn('FAH.query: selector must not be empty')
		return {}
	end
	if isEmptyQuery(properties, attributes, tags) then
		warn('FAH.query: properties, attributes, and tags were all empty')
		return {}
	end

	const registry = assetRegister
	if not registry then
		warn('FAH.query: assetRegister folder is not available')
		return {}
	end

	const ok, matches = pcall(function()
		return (registry :: any):QueryDescendants(selector) :: { Instance }
	end)
	if not ok then
		warn(`FAH.query: selector "{selector}" failed`)
		return {}
	end

	const results: QueryResult = {}
	const collisionCounts: {[string]: number} = {}

	for _, instance in matches :: { Instance } do
		const baseId = buildMatchId(registry, instance)
		const matchId = getUniqueMatchId(baseId, results, collisionCounts)
		results[matchId] = buildQueryRow(instance, properties, attributes, tags)
	end

	return results
end

--[=[
	query(selector, properties, attributes, tags)

	Queries canonical server asset templates without cloning or replicating
	the assets. The selector is passed to QueryDescendants against the server
	registry, then each match returns only the requested data.

	Client calls invoke the FAH-owned remote function and receive the same
	datastore-friendly table shape as server calls.

	Parameters:
		selector   - QueryDescendants selector string.
		properties - property names to read from each matched instance.
		attributes - attribute names to read from each matched instance.
		tags       - tag names to test on each matched instance.

	Returns:
		{ [matchId] = { properties = {}, attributes = {}, tags = {} } }
]=]
function Module.query(selector: string, properties: { string }, attributes: { string }, tags: { string }): QueryResult
	if RunService:IsClient() then
		if selector == '' then
			warn('FAH.query: selector must not be empty')
			return {}
		end
		if isEmptyQuery(properties, attributes, tags) then
			warn('FAH.query: properties, attributes, and tags were all empty')
			return {}
		end
		return assetQuery:InvokeServer(selector, properties, attributes, tags) :: QueryResult
	end

	return queryRegistry(selector, properties, attributes, tags)
end

--[=[
	registerAsset(asset, consumeAsset?)

	Registers a canonical template for `asset` on the server.

	Location:
		Stored under `ServerStorage/__assetRegister__/[assetId]`.

	Parameters:
		asset          - Instance used as the source template.
		consumeAsset   - If true, moves the instance into the registry.
		                 Otherwise stores a clone and leaves `asset` untouched.

	Server-only.
]=]
function Module.registerAsset(asset: Instance, consumeAsset: boolean?)
	if RunService:IsClient() then
		warn('FAH.registerAsset can only be called on the server')
		return
	end

	if not assetRegister then
		warn('FAH.registerAsset: assetRegister folder is not available')
		return
	end

	const assetId = getAssetId(asset)
	const existing = safeIndex(assetRegister, assetId)
	if existing then
		return
	end

	const toStore = consumeAsset and asset or asset:Clone()
	toStore.Name = assetId
	toStore.Parent = assetRegister
end

--[=[
	replicateAsset(assetOrAssetId)

	Ensures a replication template for this asset id exists in ReplicatedStorage.

	Location:
		Stored under `ReplicatedStorage/__AssetPool__/[assetId]`.

	Behavior:
		- If already replicated, returns it.
		- Otherwise clones the canonical template from ServerStorage and
		  places the clone in ReplicatedStorage.
		- Returns the replicated template instance.

	Server-only.
]=]
function Module.replicateAsset(assetOrAssetId: any): Instance?
	if RunService:IsClient() then
		warn('FAH.replicateAsset can only be called on the server')
		return nil
	end

	if not assetPool or not assetRegister then
		warn('FAH.replicateAsset: registry or pool folder missing')
		return nil
	end

	const assetId = if typeof(assetOrAssetId) == 'Instance'
		then getAssetId(assetOrAssetId :: Instance)
		else (assetOrAssetId :: string)

	const replicated = safeIndex(assetPool, assetId)
	if replicated then
		return replicated
	end

	const registered = safeIndex(assetRegister, assetId)
	if not registered then
		warn(`FAH.replicateAsset: asset "{assetId}" is not registered`)
		return nil
	end

	const template = registered:Clone()
	template.Name = assetId
	template.Parent = assetPool

	return template
end

--[=[
	refresh(assetOrAssetId, replicateIfNot?)

	Rebuilds the replicated prefab from the canonical registry template.

	Source of truth:
		ServerStorage.__assetRegister__[assetId]

	Replication target:
		ReplicatedStorage.__AssetPool__[assetId]

	Behavior:
		- Server-only.
		- If a replicated prefab already exists, it is replaced with a fresh clone
		  from the registry.
		- If the prefab is missing:
			* if replicateIfNot is true, it will be created from the registry.
			* otherwise returns nil.

	Important:
		- This does not update any already-cloned live instances in the world.
		- Any stored references to the old replicated prefab become invalid.

	Returns:
		The refreshed replicated prefab instance, or nil if unavailable.
]=]
function Module.refresh(assetOrAssetId: any, replicateIfNot: true?): Instance?
	if RunService:IsClient() then
		warn('FAH.refresh can only be called on the server')
		return nil
	end

	if not assetPool or not assetRegister then
		warn('FAH.refresh: registry or pool folder missing')
		return nil
	end

	const assetId = if typeof(assetOrAssetId) == 'Instance'
		then getAssetId(assetOrAssetId :: Instance)
		else (assetOrAssetId :: string)

	const registered = safeIndex(assetRegister, assetId)
	if not registered then
		warn(`FAH.refresh: asset "{assetId}" is not registered`)
		return nil
	end

	const replicated = safeIndex(assetPool, assetId)
	if not replicated and not replicateIfNot then
		return nil
	end

	--\\ parent first, then destroy to avoid the prefab not being there when gotten
	const template = registered:Clone()
	template.Name = assetId
	template.Parent = assetPool

	if replicated then
		replicated:Destroy()
	end

	return template
end

--[=[
	getPrefab(assetOrAssetId, sourceFromRegistry?)

	Returns the prefab template for an asset id.

	Two possible sources:
		1) Replicated prefab (default):
		   ReplicatedStorage.__AssetPool__[assetId]
		2) Canonical registry template (sourceFromRegistry = true):
		   ServerStorage.__assetRegister__[assetId]

	Important:
		- This does NOT clone. Treat the returned instance as read-only.
		- Mutating the returned prefab will affect future clones from that same source.
		- Registry and replicated prefabs are different instances. Changes do not sync
		  unless you call `refresh`.

	Server:
		- Default: returns replicated prefab if present, otherwise replicates on demand.
		- If sourceFromRegistry: returns the canonical registry template directly.

	Client:
		- Default: waits up to `timeout` seconds for the replicated prefab to
		  arrive (default 10s). Returns nil and warns if it times out.
		- If sourceFromRegistry: returns nil and warns (no access to ServerStorage).

	Parameters:
		timeout  - (client only) how long to wait for the asset to replicate.
		           Defaults to 10 seconds. Pass 0 to skip waiting entirely.

	Returns:
		The prefab instance, or nil if unavailable.
]=]
function Module.getPrefab(assetOrAssetId: any, sourceFromRegistry: true?, timeout: number?): Instance?
	const assetId = if typeof(assetOrAssetId) == 'Instance'
		then getAssetId(assetOrAssetId :: Instance)
		else (assetOrAssetId :: string)

	--\\ Server-only path: fetch directly from the canonical registry.
	if sourceFromRegistry then
		if RunService:IsClient() then
			warn(`FAH.getPrefab: cannot sourceFromRegistry on the client for "{assetId}"`)
			return nil
		end

		if not assetRegister then
			warn('FAH.getPrefab: assetRegister folder is not available')
			return nil
		end

		const registered = safeIndex(assetRegister, assetId)
		if not registered then
			warn(`FAH.getPrefab: asset "{assetId}" is not registered`)
			return nil
		end

		return registered
	end

	--\\ Default path: fetch from replicated pool (and replicate on demand on server).
	if not assetPool then
		warn('FAH.getPrefab: assetPool folder is not available')
		return nil
	end

	if RunService:IsServer() then
		const replicated = safeIndex(assetPool, assetId)
		return replicated or Module.replicateAsset(assetId)
	end

	const waitTime = if timeout ~= nil then timeout else 10
	const replicated = if waitTime > 0
		then assetPool:WaitForChild(assetId, waitTime)
		else safeIndex(assetPool, assetId)

	if not replicated then
		warn(`FAH.getPrefab: timed out waiting for "{assetId}" to replicate`)
	end

	return replicated
end

--[=[
	clonePrefab(assetOrAssetId, sourceFromRegistry?)

	Returns a fresh clone of an asset prefab.

	Default:
		Clones from the replicated prefab in ReplicatedStorage.__AssetPool__.

	If sourceFromRegistry is true:
		Server-only. Clones from the canonical registry template in ServerStorage.
		This does not create or update the replicated prefab.

	Server:
		- Default: clones from replicated prefab, replicating on demand if missing.
		- If sourceFromRegistry: clones directly from the registry.

	Client:
		- Default: waits for the replicated prefab (see getPrefab `timeout`).
		- If sourceFromRegistry: returns nil and warns.

	Returns:
		A new clone instance, or nil if unavailable.
]=]
function Module.clonePrefab(assetOrAssetId: any, sourceFromRegistry: true?, timeout: number?): Instance?
	const assetId = if typeof(assetOrAssetId) == 'Instance'
		then getAssetId(assetOrAssetId :: Instance)
		else (assetOrAssetId :: string)

	const prefab = Module.getPrefab(assetOrAssetId, sourceFromRegistry, timeout)
	if not prefab then
		warn(`FAH.clonePrefab: no prefab available for "{assetId}"`)
		return nil
	end
	return prefab:Clone()
end


function Module.isAssetRegistered(assetOrAssetId: any): boolean
	const assetId = if typeof(assetOrAssetId) == 'Instance'
		then getAssetId(assetOrAssetId :: Instance)
		else (assetOrAssetId :: string)

	if RunService:IsServer() then
		return (safeIndex(assetPool, assetId) or safeIndex(assetRegister, assetId)) ~= nil
	else
		return safeIndex(assetPool, assetId) ~= nil
	end
end

-- bootstrap registry
if RunService:IsServer() then
	assetRegister = getOrCreateFolder(ServerStorage, '__assetRegister__')
	assetQuery.OnServerInvoke = function(_player: Player, selector: string, properties: { string }, attributes: { string }, tags: { string })
		return queryRegistry(selector, properties, attributes, tags)
	end
end

return Module
