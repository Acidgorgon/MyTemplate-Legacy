# Working in a GenTree game

Rules for AI agents (and people) changing this repo. Keep changes small and in the existing style.

## Layout

| Path | Lands in | What goes there |
| --- | --- | --- |
| `src/shared/Features/<Name>/init.luau` | `ReplicatedStorage.Shared.Features` | Config and data for a feature (tables, numbers). Visible to clients: no secrets. |
| `src/shared/Modules/` | `ReplicatedStorage.Shared.Modules` | Shared code: `ModuleLoader`, `Utils/` (e.g. `RateLimit`). |
| `src/shared/Interface/` | `ReplicatedStorage.Shared.Interface` | Vide UI. `App/app.luau` is the root, `MountUI.luau` mounts it. |
| `src/shared/events/` | `ReplicatedStorage.Shared.events` | Blink output (paths set in `events.blink`). Generated, never edit. |
| `src/server/Features/<Name>/` | `ServerScriptService.Server.Features` | `<Name>Service.luau` plus `init.server.luau` that runs its `Init` then `Start`. |
| `src/server/Data/`, `src/server/Handlers/` | `ServerScriptService.Server` | Server-only data and handler code. |
| `src/ServerStorage/` | `ServerStorage` | Server-only assets and modules (create the folder when needed). |
| `src/client/Client/init.client.luau` | `StarterPlayerScripts.Client.Client` | Client entry: loads every controller with `ModuleLoader`. |
| `src/client/Client/Controllers/<Name>Controller/init.luau` | under the client script | One controller per feature. |
| `Packages/` | `ReplicatedStorage.Packages` | Wally packages. Never edit; change `wally.toml` instead. |

The Rojo folders `Shared`, `Server` and `Client` use `$ignoreUnknownInstances`, so things made in Studio inside them are kept. Only scripts in the repo are synced.

## New feature

1. With `./dev` running, create `src/shared/Features/<Name>` (PascalCase, letters and digits only).
2. The watcher scaffolds `src/shared/Features/<Name>/init.luau`, `src/server/Features/<Name>/<Name>Service.luau` + `init.server.luau`, and `src/client/Client/Controllers/<Name>Controller/init.luau`. It never overwrites existing files.
3. Deleting the shared folder deletes the server feature and the controller with it. A server feature with no shared folder is server-only and left alone.

Without `./dev` running, create the same files by hand in the same shape.

Config numbers (prices, rates, rewards) are per game. Do not copy them from another game.

## ModuleLoader lifecycle

`ModuleLoader.InitFolder(folder)` requires every ModuleScript under `folder` (including helper modules inside a controller folder) and then:

- `Init(janitor)`: one module at a time. Connect events and build state here; put cleanup in the janitor. Do not wait on other modules.
- `Start()`: each in its own thread after every `Init` has finished. Safe to use other modules here.
- `OnCharacterAdded(character)` / `OnCharacterRemoving(character)`: client only.
- `Shutdown()`: server only, on `game:BindToClose`, in reverse order.
- `Priority = number` on the module table: higher loads first, default 0, ties by name.

Errors are reported as `[ModuleLoader] <Module>.<Phase> failed:` and do not stop other modules. A module whose `Init` failed is not started. The folder gets `Ready = true` when done. `InitFolder` runs once per Luau VM. Server features currently boot from their own `init.server.luau` and do not go through ModuleLoader.

## Networking (Blink)

- Define remotes only in `events.blink`. Output paths are set there (`ClientOutput`, `ServerOutput`). Never edit generated files; `./dev` (or `blink events.blink`) regenerates them.
- Treat every client to server event as hostile. In the server handler: rate-limit first (`Shared.Modules.Utils.RateLimit`, one limiter per event), then check every argument's type and range, then check the player is allowed to do it (owns it, can afford it, is near it). Never trust prices, damage or rewards sent by the client.
- Prefer Blink types that limit size (`string(..32)`, `u8`, enums) over open-ended ones.

## Code style

- Luau, tabs, double quotes, 120 columns: StyLua with `.stylua.toml`. Lint with Selene (`selene.toml`).
- Services at the top: `local Players = game:GetService("Players")`. Require shared code by instance path, e.g. `require(ReplicatedStorage.Shared.Modules.ModuleLoader)`.
- PascalCase for modules, features, services (`<Name>Service`) and controllers (`<Name>Controller`); methods use `:` (`function InventoryService:Start()`).
- The repo default is nonstrict (`.luaurc`). Start new modules with `--!strict` and give public functions typed parameters.
- Comments are short and say why, not what.

## Tools

- `./dev` (Windows: `./dev` in PowerShell or `dev.bat`): feature watcher, Blink, sourcemap, Wally, Studio sync. Leave it running.
- `./check` (Windows: `check.bat`): Blink, sourcemap, luau-lsp types, Selene, StyLua, Rojo build. Run it before every push and fix what it reports. A skipped step means the tool is missing: `rokit install`.
- Tools are pinned in `rokit.toml`. Add packages in `wally.toml`; `./dev` reinstalls them.

## Studio sync

Script edits made in Studio (for example by a Team Create collaborator) are written back into the repo by `tools/studio-sync.py` while `./dev` runs. If a file changed in both places, the Studio copy is held in `.studio-sync/conflicts/` instead of overwriting yours. Check `python tools/studio-sync.py conflicts` before large edits, and resolve with `take-studio <file|all>` or `take-disk <file|all>`. Do not hand-edit `.studio-sync/`.

## Do not

- Edit `Packages/`, `sourcemap.json`, Blink output, or anything in `.studio-sync/`.
- Commit `build/`, `.cache/`, place files or lock files (see `.gitignore`).
- Reformat files you are not otherwise changing.
