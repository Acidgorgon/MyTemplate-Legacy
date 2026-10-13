# GenTree

Rojo starter. Clone this instead of rebuilding Features / Controllers / ModuleLoader every time.

House layout only: shared Features, server Features, client Controllers. Do not copy prices, drop rates, or banners from TD GAME. New game = new economy.

## New game

```bash
git clone <this-repo> MyGame
cd MyGame
# rename default.project.json name and wally.toml package name
rokit install
```

Then one command (feature watcher + Blink + sourcemap + wally):

```bash
./dev
```

On Windows PowerShell the same `./dev` works (or `dev.bat`).

The first `./dev` drops the template `.git` so this folder is not connected to MyTemplate-Legacy. If an editor has `.git` files locked, `./dev` still continues. Add a `.keep-git` file only if you are maintaining the template itself.

Leave that window open. Ctrl+C stops it. Or Terminal, Run Build Task in Cursor.

Rojo serve is separate so it does not fight Studio: `rojo serve` or the Rojo plugin.

## New feature

With `./dev` running, add a folder:

- `src/shared/Features/Inventory`

The watcher creates the server Feature + `InventoryController`. Delete that shared folder and those copies go with it. Server-only Features (never in shared) are left alone.

## Tools

Pinned in `rokit.toml`: Rojo, Wally, Blink, Selene. After `wally install`, ModuleLoader needs `ReplicatedStorage.Packages.Janitor`.

## Player data

Typed, schema-checked player data on top of DataService (which wraps ProfileStore for session locking and saving). The server owns it; clients get a read-only copy of their own data.

```lua
-- 1. Define a field: src/shared/Data/Schema.luau (type + Template + Validator)
--    PlayerData type: Gems: number,   Template: Gems = 0,   Validator: Gems = V.Integer(0, MAX_SAFE),
-- 2. Read (server):
local data = PlayerDataService:WaitForData(player) -- frozen snapshot, nil if they left
-- 3. Update (server): the whole result is validated before it commits
PlayerDataService:Update(player, function(draft) draft.Gems += 10 end)
if not PlayerDataService:Increment(player, "Coins", -price) then return end -- false if Coins would go below 0
-- 4. Developer product: Receipts.Register(productId, function(draft) draft.Gems += 100 end)
-- 5. Read on the client: local coins = PlayerData.Coins()  (or PlayerData.Use(PlayerData.Coins) in Vide)
```

Requires: `PlayerDataService` and `Receipts` from `ServerScriptService.Server.Data`, `PlayerData` from `ReplicatedStorage.Shared.Data.Client`.

- **Schema** (`src/shared/Data/Schema.luau`): the `PlayerData` type, the frozen `Template`, `Version`, and `Validator` built from `src/shared/Data/Validate.luau` (`Integer`, `Number`, `String`, `Enum`, `Array`, `Map`, `Record`, `Optional`, `Union`, `Custom`). Errors carry a path, e.g. `Inventory.Items[3].Count: expected integer, got 1.5`. The comment at the top shows how a feature (e.g. Inventory) owns its slice.
- **Loading**: old saves are migrated (`src/server/Data/Migrations.luau`, bump `Schema.Version` and add a step), missing fields are filled from the template, then the data is validated. Each bad value is repaired (reset to its default, bad list entry removed, over-long list cut) and logged with the player and path. Data that cannot be migrated, or was saved by a newer server, is not touched: the player is kicked with a message.
- **Updates**: `Update` gives you a plain copy to edit (do not yield in it); an invalid result errors and nothing changes. `TryUpdate` returns `ok, err` instead. Signals: `Loaded`, `Changed(player, new, old)`, `Releasing`. Do not call `DataService:set` directly.
- **Purchases**: `src/server/Data/Receipts.luau` is the only `ProcessReceipt`. A grant and its PurchaseId are committed together; Roblox gets `PurchaseGranted` only after a save containing that PurchaseId, so a purchase is never granted twice.
- **Client**: charm-sync over the `PlayerDataSync` Blink event, server to client only, diffed. Each player receives their own data plus everyone's `Schema.ToPublic` fields. There is no client-to-server data path: a client asks through a feature's Blink event, and the server rate limits (`RateLimit`, from the template-dx branch), validates, then `Update`s.
- **Studio**: without API access ProfileStore falls back to an in-memory store and PlayerDataService warns that nothing saves. Set `Config.MockInStudio` in `PlayerDataService.luau` to force that even with access on.
- **Tests**: `lune run tests/run.luau` (or `luau tests/run.luau`) runs the specs for the validator, migrations, update/commit logic, sync filter and receipts.

## Studio sync

Rojo only pushes files into Studio. `./dev` also runs `tools/studio-sync.py`, which does the other direction for scripts: when a script under the Rojo folders (Shared, Server, Client) is edited inside Studio, for example by a Team Create collaborator, the new source is written into the matching repo file.

Setup, once per game: put the place id of the game in `tools/studio-sync.json` (`"placeIds": [123456789]`). `./dev` installs the Studio plugin as `RepoStudioSync.lua` in the Roblox plugins folder; restart Studio and allow its HTTP requests to `127.0.0.1`. The **Studio Sync** button on the Repo Sync toolbar is highlighted while connected. Needs Python 3.

- Scripts only. It never creates folders and never deletes files; a script with no matching repo folder is skipped and noted in `.studio-sync/sync.log`. `src/ServerStorage` is excluded.
- If a file changed in both places since they last matched, the Studio version is held in `.studio-sync/conflicts/` instead of overwriting the repo:
  - `python tools/studio-sync.py conflicts` lists held files
  - `python tools/studio-sync.py take-studio <file|all>` uses the Studio version
  - `python tools/studio-sync.py take-disk <file|all>` keeps the repo version
