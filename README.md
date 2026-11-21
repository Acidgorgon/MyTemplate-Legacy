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

Then one command (feature watcher + Current + Ripple + sourcemap + wally):

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

Pinned in `rokit.toml`: Rojo, Wally, [Current](https://acidgorgon.github.io/Current/) (networking, compiles `events.blink`; a faster two-way fork of Blink), [Ripple](https://acidgorgon.github.io/Ripple/) (state sync, compiles `game.ripple`), Selene. After `wally install`, ModuleLoader needs `ReplicatedStorage.Packages.Janitor`.

## Player data and state

Saving uses [Anchor](https://acidgorgon.github.io/Anchor/) (session-locked, a drop-in upgrade of ProfileStore), vendored in `vendor/Anchor` and synced to `ServerScriptService.Anchor`. Replication uses [Ripple](https://acidgorgon.github.io/Ripple/): describe the state in `game.ripple`, and `./dev` regenerates `src/shared/Ripple/Server.luau` and `Client.luau` whenever you save it (or run `ripple game.ripple --out src/shared/Ripple`). Commit the generated files.

Server:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Anchor = require(game.ServerScriptService.Anchor)
local Ripple = require(ReplicatedStorage.Shared.Ripple.Server)

local Data = Anchor.new("Main", { Coins = 0 })
Data:UseRipple(function(player, profile)
	return Ripple.PlayerData.new(player, profile.Data) -- replicates the saved table to its player
end)
Data:Bind() -- loads on join, saves on leave and shutdown

Data:Update(player, function(state)
	state.Coins += 10 -- saved and sent to the client at the end of the frame
end)
```

Client:

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)

local data = Ripple.PlayerData.wait()
Ripple.observe(data, "Coins", function(coins)
	print("Coins:", coins)
end)
```

With Vide, `Ripple.useVide(vide)` once, then `Ripple.source(data, "Coins")` is a Vide source. In Studio, set the `Mock` attribute on the Anchor module to keep test sessions off the real DataStore.

## Studio sync

Rojo only pushes files into Studio. `./dev` also runs `tools/studio-sync.py`, which does the other direction for scripts: when a script under the Rojo folders (Shared, Server, Client) is edited inside Studio, for example by a Team Create collaborator, the new source is written into the matching repo file.

Setup, once per game: put the place id of the game in `tools/studio-sync.json` (`"placeIds": [123456789]`). `./dev` installs the Studio plugin as `RepoStudioSync.lua` in the Roblox plugins folder; restart Studio and allow its HTTP requests to `127.0.0.1`. The **Studio Sync** button on the Repo Sync toolbar is highlighted while connected. Needs Python 3.

- Scripts only. It never creates folders and never deletes files; a script with no matching repo folder is skipped and noted in `.studio-sync/sync.log`. `src/ServerStorage` is excluded.
- If a file changed in both places since they last matched, the Studio version is held in `.studio-sync/conflicts/` instead of overwriting the repo:
  - `python tools/studio-sync.py conflicts` lists held files
  - `python tools/studio-sync.py take-studio <file|all>` uses the Studio version
  - `python tools/studio-sync.py take-disk <file|all>` keeps the repo version

### Place tree (Studio-only assets)

The plugin also sends a read-only snapshot of the place's instance tree, so models, parts, sounds, images and folders that only exist in Studio (for example in `Workspace`, `ReplicatedStorage.Assets`, `ServerStorage`, `StarterGui`, `Lighting`, `SoundService`) can be browsed and their Roblox paths copied for an AI or a teammate.

- What syncs: names, classes and nesting, plus a few properties per asset (`Size` of parts, `MeshId`/`TextureID`, `SoundId`, decal `Texture`, `Image`, `AnimationId`). The assets themselves stay in the place file; nothing is exported into the repo and nothing is ever written back into Studio. Scripts still sync both ways as above.
- Stored in `.studio-sync/tree.json` and served at `GET http://127.0.0.1:34873/tree`. It is sent when the plugin connects and again about 1.5 s after anything is added, removed or renamed (plus a rescan every 30 s); an unchanged tree is not re-sent.
- Settings in `tools/studio-sync.json`: `treeServices` (services to include), `treeDepth` (default 12 levels below a service), `treeMaxNodes` (default 20000; past that the tree is cut and marked `truncated`). Cameras, `Players`, Terrain contents and the insides of Wally `Packages` folders are left out.
- Tests: `python3 -m unittest tools/test_studio_sync.py`
