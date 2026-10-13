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

## Check

Before pushing:

```bash
./check
```

On Windows PowerShell `./check` works too (or `check.bat`, or Terminal, Run Task, GenTree: check). It runs, in order: Blink, `wally install` if `Packages/` is missing, `rojo sourcemap`, `luau-lsp analyze` on `src`, `selene src`, `stylua --check src`, and `rojo build` to `build/check.rbxlx`. A step whose tool is missing is skipped with a note; any failed step makes it exit non-zero. The Roblox type definitions for luau-lsp are downloaded once into `.cache/luau-lsp/` (delete the file to refresh). Blink output is excluded from types, lint and format.

## Tools

Pinned in `rokit.toml`: Rojo, Wally, Blink, Selene, StyLua, luau-lsp, wally-package-types. After `wally install`, ModuleLoader needs `ReplicatedStorage.Packages.Janitor`; `./dev` then runs wally-package-types so package types show up in the editor.

- `.luaurc`: nonstrict by default. New modules should start with `--!strict`.
- `.stylua.toml`: tabs, 120 columns, double quotes. VS Code formats on save with the StyLua extension.
- `.vscode/`: recommended extensions (luau-lsp, StyLua, Selene, Rojo) and settings. luau-lsp reads the `sourcemap.json` that `./dev` keeps up to date.
- `AGENTS.md`: rules for AI agents working in a game made from this template (`CLAUDE.md` points to it).

## ModuleLoader

`src/client/Client/init.client.luau` calls `ModuleLoader.InitFolder` on the Controllers folder. Each module may define:

- `Init(janitor)`: runs one module at a time; set up state and connections.
- `Start()`: runs in its own thread after every `Init`.
- `OnCharacterAdded(character)`, `OnCharacterRemoving(character)`: client only.
- `Shutdown()`: server only, from `game:BindToClose`, in reverse load order.
- `Priority`: number, higher loads first (default 0, ties by name).

A module that errors prints `[ModuleLoader] <Module>.<Phase> failed:` and the others keep going. When loading is done the folder has the attribute `Ready = true`.

Server features run their own `Init` and `Start` from the `init.server.luau` the watcher creates.

For client to server Blink events, rate-limit on the server with `Shared.Modules.Utils.RateLimit` (example in the file) and validate every argument.

## Studio sync

Rojo only pushes files into Studio. `./dev` also runs `tools/studio-sync.py`, which does the other direction for scripts: when a script under the Rojo folders (Shared, Server, Client) is edited inside Studio, for example by a Team Create collaborator, the new source is written into the matching repo file.

Setup, once per game: put the place id of the game in `tools/studio-sync.json` (`"placeIds": [123456789]`). `./dev` installs the Studio plugin as `RepoStudioSync.lua` in the Roblox plugins folder; restart Studio and allow its HTTP requests to `127.0.0.1`. The **Studio Sync** button on the Repo Sync toolbar is highlighted while connected. Needs Python 3.

- Scripts only. It never creates folders and never deletes files; a script with no matching repo folder is skipped and noted in `.studio-sync/sync.log`. `src/ServerStorage` is excluded.
- If a file changed in both places since they last matched, the Studio version is held in `.studio-sync/conflicts/` instead of overwriting the repo:
  - `python tools/studio-sync.py conflicts` lists held files
  - `python tools/studio-sync.py take-studio <file|all>` uses the Studio version
  - `python tools/studio-sync.py take-disk <file|all>` keeps the repo version
