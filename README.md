# FS25 Map Preload Flyover

Farming Simulator 25 mod that flies an automatic camera tour across the entire map so textures, assets and shaders get rendered once — reduces stutter on first visit of an area.

## Installation

1. Download the latest `FS25_MapPreloadFlyover.zip` from the [Releases](../../releases) page (or zip the repo contents yourself).
2. Drop the zip into `Documents\My Games\FarmingSimulator2025\mods\`.
3. Activate it in the ingame mod list.

## Usage

Open the ingame console (`~` / German layout: `ö`) and run:

```
preloadMapShaders [spacing] [height] [speed] [restore]
preloadMapShadersStop
```

All arguments are optional. Defaults adapt automatically to the map size (1×, 2×, 4× maps).

| Argument | Meaning                                  | Default |
|----------|------------------------------------------|---------|
| spacing  | Distance between flyover lanes (meters)  | auto    |
| height   | Camera altitude above terrain (meters)   | auto    |
| speed    | Flight speed (m/s)                       | auto    |
| restore  | Teleport back to start position on end   | true    |

Examples:

```
preloadMapShaders
preloadMapShaders 260 180 240 true
```

## Features

- Auto-detects terrain size (works on 1×/2×/4× maps).
- Single boustrophedon sweep across the whole map (no double traversal).
- Live HUD panel with progress, coverage grid, ETA.
- Path hotspots drawn onto the PDA map (press `M`) and minimap.
- Player position is restored after the run (optional).
- Stop the run any time with `preloadMapShadersStop`.

## Known limitations

- Multiplayer should work in principle (flyover is client-local), but is **untested**. Use at your own risk on MP servers.
- Leave your vehicle before starting — the flyover takes over the local player camera.

## License

MIT — see [LICENSE](LICENSE).
