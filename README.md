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
