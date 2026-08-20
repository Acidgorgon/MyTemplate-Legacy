# GenTree

Rojo starter for Acid''s games. Clone this instead of rebuilding Features / Controllers / ModuleLoader every time.

Folder layout is the house style (shared Features, server Features, client Controllers). Do **not** copy prices, drop rates, or banners from TD GAME or any other place. New game = new economy.

## New game

```bash
git clone <this-repo> MyGame
cd MyGame
# rename default.project.json "name" and wally.toml package name
wally install
rojo serve
```

## New feature (Inventory example)

Copy the `_Template` stubs and rename. Do not copy file bodies from another game.

- `src/shared/Features/_Template` → `src/shared/Features/Inventory`
- `src/server/Features/_Template` → `src/server/Features/Inventory` (rename `TemplateService.luau` → `InventoryService.luau` and fix the require)
- `src/client/Client/Controllers/_TemplateController` → `InventoryController`

Rojo already maps the whole `src/shared`, `src/server`, and `src/client` folders, so you do not need genRojoTree''s project.json generator.

## Tools

- Rojo, Wally, Selene (Aftman/Rokit if you want versions pinned)
- After `wally install`, Packages/Janitor is what ModuleLoader requires
