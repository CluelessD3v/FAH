# FAH

FAH means Fetch Assets Here.

It is a small Roblox module for keeping asset templates in one place and
replicating only the ones a client actually needs.

The server keeps the canonical templates in `ServerStorage`.

The client fetches cloned prefabs from `ReplicatedStorage`.

That is the trick.

## Why

Roblox projects often end up with asset folders in several places.

Some assets live in `ServerStorage`. Some have to live in `ReplicatedStorage`.
Some are dragged into `Workspace` while you work. Roblox packages can solve
parts of this, but they also add their own shape to your project.

FAH is smaller than that.

Give FAH an asset. It stores the canonical copy on the server. Replicate it when
the client needs it. Clone it from the same API on both sides.

## What It Does

FAH keeps two folders:

```text
ServerStorage
  __assetRegister__

ReplicatedStorage
  __AssetPool__
```

`__assetRegister__` is the server-only registry.

`__AssetPool__` is the replicated pool the client can read.

The server registers assets into the registry.

The server decides when to replicate a registered asset into the pool.

The client can wait for a replicated prefab and clone it.

## What It Does Not Do

FAH is not an asset pool for live `PVInstance`s.

It does not recycle models that have already been spawned into the world.

It does not unload assets after a player stops needing them.

It does not validate gameplay rules.

It does not replace Roblox content loading.

It is an asset registry that happens to make selective replication simple.

## Install

Copy `src` into your project as one ModuleScript named `FAH`.

```text
ReplicatedStorage
  FAH
    connectAssetRequest
```

Keep `connectAssetRequest` as a server script child. It requires FAH on the
server so the server-side registry and remotes exist before clients ask for
assets.

Or use the included project file.

With Wally:

```toml
FAH = "cluelessdev/fah@0.1.0-rc.1"
```

## Basic Usage

Tag assets with `FAH`, then register them on server boot.

```lua
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FAH = require(ReplicatedStorage.FAH)

for _, asset in CollectionService:GetTagged("FAH") do
    FAH.registerAsset(asset, true)
    FAH.replicateAsset(asset)
end
```

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

`clonePrefab` waits for the replicated prefab on the client. The default wait is
10 seconds.

## Replicate On Unlock

You do not have to replicate every asset at boot.

You can keep the asset server-only until a player needs it.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FAH = require(ReplicatedStorage.FAH)

local function unlockSword(player: Player)
    FAH.replicateAsset("IronSword")

    -- Now tell the client that the sword can be shown or equipped.
    -- Use your own event, Relay, or whatever request path your game uses.
end
```

On the client, clone it after the unlock message arrives.

```lua
local sword = FAH.clonePrefab("IronSword", nil, 10)
if sword then
    sword.Parent = workspace
end
```

This does not replicate to only one player. Roblox replication does not work
that way for normal instances under `ReplicatedStorage`.

What it does do is avoid putting the sword in replicated storage until the game
actually needs it.

If you need per-player visibility for the spawned thing, spawn it through your
own server logic or create it locally on that client after the prefab arrives.

## Asset Ids

By default, an asset id is the instance name.

```lua
FAH.replicateAsset("IronSword")
FAH.clonePrefab("IronSword")
```

You can also tell FAH to read asset ids from attributes.

```lua
FAH.assetIds = { "AssetId", "ItemId" }
```

FAH checks those attributes in order. If none are found, it uses
`instance.Name`.

## Querying Metadata

FAH can query the server registry without replicating the full assets.

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

The selector is passed to `QueryDescendants` against the server registry.

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
`ServerStorage.__assetRegister__`. Clients cannot use that path.

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

Client calls use FAH's remote function and receive the same table shape as
server calls.

## When To Use FAH

Use FAH when you want one source of truth for asset templates.

Use FAH when only some assets should be replicated at startup.

Use FAH when a client should clone an asset by id after the server has made it
available.

Use something else when you need a runtime object pool.

That is not what this is.
