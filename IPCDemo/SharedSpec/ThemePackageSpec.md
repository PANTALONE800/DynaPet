# DynaPet dynamic theme package v1

Both the Swift/macOS and C#/WPF implementations use this contract. A theme is a directory. ZIP is the transport format: extract it first, then select the directory containing `theme.json` using **导入主题包…** in the pet context menu or status/tray menu. Direct ZIP import is not supported in v1.

```text
MyTheme/
  theme.json
  idle.gif
  touch.gif
  sleep.gif
```

`theme.json` is UTF-8 JSON, at most 64 KiB:

```json
{
  "format": "dynapet-theme",
  "version": 1,
  "name": "My Animated Pet",
  "states": {
    "idle": "idle.gif",
    "touch": "touch.gif",
    "sleep": "sleep.gif"
  }
}
```

`format`, `version`, `name`, and `states` are required. Name is 1–128 UTF-8 bytes. `idle`, `touch`, and `sleep` mappings are mandatory; they may point to the same GIF. Optional mappings: `welcome`, `focus`, `happy`, `hot`, `dizzy`, `puzzled`, `low`, `message`. Unknown state keys are rejected (no silent spelling-error fallback). Engine mood `shy` maps to `touch`; `sleepy` maps to `sleep`; other moods use their matching optional mapping or `idle`. Theme configuration does not replace the existing business state machine or the 7-second touch hold, 9-second mood hysteresis and 14-second greeting window. Windows does not gain message listening; `message` remains its manual surprise pose.

Files must sit directly beside theme.json. Filenames match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.gif` exactly; no subdirectories, absolute paths, URLs, links or executable plugins. Use exact filename casing for portable themes. The importer copies only referenced GIF files and normalized JSON into a new owned theme directory. Original files and previously selected themes are retained. A failed import does not change the selected theme. macOS storage: `~/Library/Application Support/DynaPet/Themes`; Windows: `%LOCALAPPDATA%/DynaPet/Themes`.

## Animation semantics

- Decode **every frame** onto the GIF canvas, respecting palette, transparency, frame offset and GIF disposal. Native decoders are ImageIO/CGImageSource on macOS and GDI+ System.Drawing on Windows, copied into immutable NSImage/WPF BitmapSource frames.
- Use GIF frame delays in centiseconds, preserving every positive delay (including 10 ms). Zero/missing delay is 100 ms on both platforms. macOS reads `kCGImagePropertyGIFUnclampedDelayTime` before the clamped fallback. Windows reads raw GIF control blocks for timing and repeats before invoking GDI+ (which avoids platform-specific metadata normalization). UI repaint frequency can skip presentation of very short frames when the desktop is busy, but decoded frames and their timeline are not truncated or retimed.
- Loop metadata: no loop extension = one pass; raw NETSCAPE repeat count 0 = infinite; positive N = N repetitions after the first pass (N+1 total passes). A finite animation freezes on its final frame. ImageIO reports total passes; Swift normalizes it back to raw repeats. Windows reads the NETSCAPE block directly. No overriding loop field in JSON.
- Restart at frame 0 on a mood change, explicit touch replay, wake greeting, theme import or restore. Changes in caption alone do not restart. Different moods that fall back to `idle` still count as mood changes. Pausing actions freezes the current animation and resumes from that point; it does not continue consuming finite loops while paused. A sleep pose can itself animate.
- Keep the same canvas, aspect ratio and frame registration; no independent auto-crop of individual GIF frames. Existing size controls scale the canvas to the pet area.

## Bounds and errors

Each GIF: at most 32 MiB, canvas dimensions 1–4096, 1–1000 frames. Unique GIFs referenced by one theme: at most 64 MiB and **64,000,000 decoded canvas pixels total** (~256 MB for frame pixels, plus native decoder/runtime overhead). Shared GIF filenames are decoded once. Both implementations check GIF block completeness and decoded frame counts before accepting a package. Oversize, corrupt, incomplete or incompatible resources are rejected with an error; never truncate to meet bounds. These limits protect routine import memory use; themes should still come from trusted sources and OS image decoders should remain updated.

## Shared test data and checks

`TestThemes/MinimalGif/` is an original CC0 geometric moving-dot animation: 8 transparent frames with delays `[40,80,120,160,200,240,280,320]` ms, infinite looping. All three required states map to `demo.gif`. `TestThemes/MinimalGif.zip` contains exactly the same folder. It contains no legacy character art.

`TestThemes/Conformance/` adds missing loop extension, positive repeat count, 10 ms/zero delays, transparent delta rectangles and disposal modes 1/2/3. `expected.json` records full RGBA FNV-1a hashes and per-frame metadata from Pillow; fully transparent RGB bytes are normalized to zero. `tools/generate_gif_test_theme.py` regenerates the fixtures (Pillow is development-only).

Run the Mac decoder/import tests using `tools/check_gif_themes.sh`. Run the C# state/timeline contract tests with:

```sh
 dotnet run --project IPCDemo/WindowsPlatform/Tests/DynaPet.Core.Checks.csproj -c Release -- /path/to/repository
```

On Windows, run actual native decoding and folder-import checks (without opening a pet window):

```powershell
$root = (Get-Location).Path
$exe = Join-Path $root 'IPCDemo/WindowsPlatform/App/bin/Release/net10.0-windows10.0.19041.0/win-x64/DynaPet.exe'
$p = Start-Process -FilePath $exe -ArgumentList @('--theme-check', ('"' + $root + '"'), ('"' + (Join-Path $root 'gif-theme-result.txt') + '"')) -Wait -PassThru
Get-Content (Join-Path $root 'gif-theme-result.txt')
if ($p.ExitCode -ne 0) { throw 'Native GIF conformance failed' }
```

For manual acceptance on each OS: import MinimalGif; watch the dot move through all 8 positions continuously; touch the pet, select a mood, pause/resume, restart the app, restore the default character, and try importing an invalid theme. Confirm both status/tray and pet context menu work and that failed import retains the current character. The minimal theme deliberately reuses one GIF; for visibly distinct state transitions replace its `touch` and `sleep` mappings with your own GIFs.

## Native API references

- [Apple GIF unclamped frame delay](https://developer.apple.com/documentation/imageio/kcgimagepropertygifunclampeddelaytime)
- [Microsoft GDI+ property descriptions](https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-constant-property-item-descriptions) (frame delays 0x5100, loop metadata 0x5101)
