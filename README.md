# GenTree

Rojo starter. Clone this instead of rebuilding Features / Controllers / ModuleLoader every time.

House layout only: shared Features, server Features, client Controllers. Do not copy prices, drop rates, or banners from TD GAME. New game = new economy.

## New game

```bash
git clone <this-repo> MyGame
cd MyGame
# rename default.project.json name and wally.toml package name
wally install
rojo serve
```

## New feature

Make three folders. Empty is fine. Rojo already maps src/shared, src/server, and src/client, so you do not need genRojoTree.

- src/shared/Features/Inventory
- src/server/Features/Inventory  (InventoryService.luau + init.server.luau)
- src/client/Client/Controllers/InventoryController

## Tools

Rojo, Wally, Selene. After wally install, ModuleLoader needs Packages/Janitor.
