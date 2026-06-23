# FAH

Fetch Assets Here.

FAH is a small Roblox module for keeping asset templates in one place.

The server keeps the real templates in `ServerStorage`.

The client gets only the templates you choose to replicate.

Then both sides clone prefabs through the same API.

That is the job.

## Why

Assets spread.

Some end up in `ServerStorage`. Some need to be in `ReplicatedStorage`. Some sit
in `Workspace` because that was convenient at the time.

Sometimes people make a whole separate asset place.

Then it gets abandoned.

Then it stops matching the main place.

Now you have two problems and one of them is named "where is the real sword?"

FAH is for not doing that.

Give FAH the template. It stores the canonical copy on the server. Replicate it
when the client needs it. Clone it by id.

No package ceremony. No second asset universe. Just a registry.

## What It Does

FAH creates two folders.

```text
ServerStorage
  __assetRegister__

ReplicatedStorage
  __AssetPool__
```

`__assetRegister__` is the server-only registry.

`__AssetPool__` is the replicated prefab pool.

Register an asset and FAH stores it in the registry.

Replicate an asset and FAH clones it into the pool.

Clone an asset and FAH gives you a fresh copy from the right place.

## What It Does Not Do

FAH is not a runtime asset pool for live `PVInstance`s.

It does not recycle spawned models.

It does not unload replicated templates.

It does not validate unlocks, purchases, equipment rules, or trust.

It does not replace Roblox content loading.

It is a simple asset registry that also makes selective replication easy.

## Install

Copy `src` into your project as one ModuleScript named `FAH`.

```text
ReplicatedStorage
  FAH
    connectAssetRequest
```

Keep `connectAssetRequest` as a server script child.

It requires FAH on the server so the registry and remotes exist before clients
ask for assets.

Or use the included project file.

With Wally:

```toml
FAH = "cluelessdev/fah@0.1.0-rc.1"
```

## Basic Usage

Register assets on the server.

How you find them is your business.

Tags are just convenient.

```lua
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FAH = require(ReplicatedStorage.FAH)

for _, asset in CollectionService:GetTagged("FAH") do
    FAH.registerAsset(asset, true)
    FAH.replicateAsset(asset)
end
```

The tag can be `FAH`, `Asset`, `Weapon`, or nothing at all.

FAH only cares that you call `registerAsset`.

`registerAsset(asset, true)` moves the asset into the server registry.

`replicateAsset(asset)` clones it into the replicated pool.

On the client:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FAH = require(ReplicatedStorage.FAH)

local sword = FAH.clonePrefab("IronSword")
if sword then
    sword.Parent = workspace
end
```

`clonePrefab` waits for the replicated prefab on the client.

Default wait: 10 seconds.

## Replicate On Unlock

You do not have to replicate everything at boot.

Keep the sword server-only until someone unlocks it.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FAH = require(ReplicatedStorage.FAH)

local function unlockSword(player: Player)
    FAH.replicateAsset("IronSword")

    -- Now tell this player they can show or equip the sword.
    -- Use your own RemoteEvent, Relay, or whatever your game uses.
end
```

On the client, clone it after the unlock message arrives.

```lua
local sword = FAH.clonePrefab("IronSword", nil, 10)
if sword then
    sword.Parent = workspace
end
```

This makes the template available from `ReplicatedStorage.__AssetPool__`.

It does not grant the item.

It does not make the server trust the client.

That part is still your game.

## Asset Ids

By default, the asset id is the instance name.

```lua
FAH.replicateAsset("IronSword")
FAH.clonePrefab("IronSword")
```

You can also read ids from attributes.

```lua
FAH.assetIds = { "AssetId", "ItemId" }
```

FAH checks those attributes in order.

If none are found, it uses `instance.Name`.

## Querying Metadata

FAH can query the server registry without replicating the full assets.

It uses Roblox's
[`Instance:QueryDescendants`](https://create.roblox.com/docs/reference/engine/classes/Instance#QueryDescendants)
under the hood.

That means the selector is the Roblox query selector.

Not a FAH mini-language.

Roblox made this fast.

For registry lookups, use it instead of doing your own descendant walk and
`FindFirstChild` chain.

```lua
local result = FAH.query(
    "[Name='IronSword']",
    { "Name" },
    { "Rarity" },
    { "Weapon" }
)
```

The result is a plain table.

```lua
{
    IronSword = {
        properties = {
            Name = "IronSword",
        },
        attributes = {
            Rarity = "Rare",
        },
        tags = {
            Weapon = true,
        },
    },
}
```

Only the requested properties, attributes, and tag checks are returned.

The asset stays on the server.

## API

### `FAH.registerAsset(asset: Instance, consumeAsset: boolean?)`

Server only.

Stores an asset in `ServerStorage.__assetRegister__`.

If `consumeAsset` is true, the original instance is moved into the registry.

If `consumeAsset` is false or nil, FAH stores a clone and leaves the original
alone.

### `FAH.replicateAsset(assetOrAssetId): Instance?`

Server only.

Copies a registered asset into `ReplicatedStorage.__AssetPool__`.

If it is already replicated, returns the existing prefab.

### `FAH.refresh(assetOrAssetId, replicateIfNot: true?): Instance?`

Server only.

Rebuilds the replicated prefab from the server registry.

This does not update live clones already in the world.

### `FAH.getPrefab(assetOrAssetId, sourceFromRegistry: true?, timeout: number?): Instance?`

Returns the prefab instance.

On the server, the default source is the replicated pool. If missing, FAH
replicates it on demand.

On the client, FAH waits for the replicated prefab. The default timeout is 10
seconds. Pass `0` to skip waiting.

With `sourceFromRegistry = true`, the server reads directly from
`ServerStorage.__assetRegister__`.

Clients cannot use that path.

Do not mutate the returned prefab unless you mean to affect future clones.

### `FAH.clonePrefab(assetOrAssetId, sourceFromRegistry: true?, timeout: number?): Instance?`

Returns a fresh clone of a prefab.

This is the usual client-facing call.

### `FAH.isAssetRegistered(assetOrAssetId): boolean`

Returns whether FAH can see the asset.

On the server, this checks the registry and the replicated pool.

On the client, this checks only the replicated pool.

### `FAH.query(selector, properties, attributes, tags): QueryResult`

Reads metadata from registered server assets.

The selector is passed to Roblox `QueryDescendants` against the registry.

Client calls use FAH's remote function and receive the same table shape as
server calls.

## When To Use FAH

Use FAH when you want one source of truth for asset templates.

Use FAH when only some templates should be replicated.

Use FAH when a client should clone a prefab by id after the server has made it
available.

Use something else when you need a runtime object pool.

That is not what this is.
