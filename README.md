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

## Studio sync

Rojo only pushes files into Studio. `./dev` also runs `tools/studio-sync.py`, which does the other direction for scripts: when a script under the Rojo folders (Shared, Server, Client) is edited inside Studio, for example by a Team Create collaborator, the new source is written into the matching repo file.

Setup, once per game: put the place id of the game in `tools/studio-sync.json` (`"placeIds": [123456789]`). `./dev` installs the Studio plugin as `RepoStudioSync.lua` in the Roblox plugins folder; restart Studio and allow its HTTP requests to `127.0.0.1`. The **Studio Sync** button on the Repo Sync toolbar is highlighted while connected. Needs Python 3.

- Scripts only. It never creates folders and never deletes files; a script with no matching repo folder is skipped and noted in `.studio-sync/sync.log`. `src/ServerStorage` is excluded.
- If a file changed in both places since they last matched, the Studio version is held in `.studio-sync/conflicts/` instead of overwriting the repo:
  - `python tools/studio-sync.py conflicts` lists held files
  - `python tools/studio-sync.py take-studio <file|all>` uses the Studio version
  - `python tools/studio-sync.py take-disk <file|all>` keeps the repo version
