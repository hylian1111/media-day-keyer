# Media Day Keyer

A Lightroom Classic plugin that turns tethered photos into transparent PNG cut-outs, one per person, while you shoot.

Press **P** on a keeper (or give it a **blue label**), and about 10 seconds later there's a full-resolution PNG of each person with the background removed, sitting in a folder next to your catalog. Built for media days: players on a backdrop, cut-outs going straight to the graphics team.

## What you need

- A Mac on macOS 14 Sonoma or newer (Apple silicon or Intel)
- Lightroom Classic
- Photoshop (it does the cut-out with Select Subject, so it has to be installed; the plugin opens it for you)

It doesn't run on Windows. It relies on macOS's built-in people detection and on scripting Photoshop from the Mac side.

## Install

1. Download `MediaDayKeyer-x.y.z.zip` from the [latest release](https://github.com/hylian1111/media-day-keyer/releases/latest) and unzip it.
2. Move `MediaDayKeyer.lrplugin` somewhere it can stay, such as your Documents folder. Lightroom loads it from wherever it is.
3. In Lightroom: **File > Plug-in Manager > Add**, choose `MediaDayKeyer.lrplugin`, then **Done**.
4. The first time it runs, macOS asks whether Lightroom may control Photoshop. Click **OK**. If you clicked Don't Allow by mistake, turn it on in System Settings > Privacy & Security > Automation, under Adobe Lightroom Classic.

## Use

1. Start tethering (**File > Tethered Capture**). To have your look on every shot, set **Develop Settings** in the tether dialog to your preset. The cut-outs use whatever edit the photo has.
2. **File > Plug-in Extras**, then choose how you'll mark the keepers:
   - **Start Auto-Keying Picks** keys photos you flag with **P**
   - **Start Auto-Keying Blue Labels** keys photos you give a blue label (**8** on the keyboard by default)
   - The **+ PSDs** versions also save a layered Photoshop file for each photo
3. Shoot and mark keepers. A bar in Lightroom's top-left corner shows how many are done and how many are waiting.
4. **File > Plug-in Extras > Open Cutouts Folder** opens the results.

Turn it off with **Stop Auto-Keying**, the X on the progress bar, or by quitting Lightroom. It's always off when Lightroom starts.

### What you get

Everything goes into a `Media Day Cutouts` folder next to your catalog file:

- `PNG/IMG_1234.png` when there's one person. With several people you get `IMG_1234_p1.png`, `IMG_1234_p2.png` and so on, numbered left to right.
- Every PNG is the full camera frame at full resolution, so players line up the same way in a template.
- `PSD/IMG_1234.psd` (**+ PSDs** mode only): one layer per person, each with an editable mask, so you can paint back a missed edge.

Each photo is keyed once. If you change an edit afterwards, select the photo and choose **Re-key Selected Photos**.

If photos were already marked when you press Start, it asks whether to key those too or only new ones.

## Getting good cut-outs

- **Shoot on a plain backdrop.** White, grey or a solid colour. Photoshop's Select Subject is excellent there and weaker on busy backgrounds.
- Anything Photoshop picks up that touches a person stays with them, like a ball, a trophy or a jersey held up. Objects that touch nobody are dropped.
- Up to **4 people** per photo are told apart. In bigger groups, anyone past the fourth ends up in the PNG of whoever they're touching.
- Colour from the backdrop is cleaned off soft edges such as hair, so cut-outs shot on white don't get a white halo on dark graphics.

## Troubleshooting

**File > Plug-in Extras > Show Log and Failed Photos** opens the work folder (`~/Library/Application Support/Media Day Keyer`):

- `keyer.log` records each photo: timings, how many people were found, and any error.
- `failed/` holds any photo that couldn't be keyed, with a `.error.txt` saying why.

Common problems:

- **"macOS blocked Lightroom from controlling Photoshop"**: allow it in System Settings > Privacy & Security > Automation.
- **"Select Subject found nobody"**: Photoshop couldn't find a subject. That usually means the frame is empty or very busy.
- **A popup says "mdkeyer" can't be opened**: the download was blocked before the plugin could clear macOS's download flag. Delete the plugin, download it again, and add it in Plug-in Manager before running anything else.

## How it works

The plugin exports each marked photo, with your develop settings applied, as a full-resolution TIFF. It then hands the TIFF to a small bundled program (`bin/mdkeyer`), which:

1. has Photoshop run **Select Subject** to get the cut-out edge;
2. uses Apple's **Vision** framework to find each person in the frame;
3. splits the cut-out so each person gets their own mask;
4. removes backdrop colour from the soft edges;
5. writes the PNGs, and the layered PSD if asked.

Nothing is uploaded anywhere by the plugin. Photoshop's Select Subject may use Adobe's cloud processing, depending on your Photoshop preferences (Preferences > Image Processing).

## Building from source

Needs Xcode or the Command Line Tools.

```bash
./build.sh           # builds MediaDayKeyer.lrplugin/bin/mdkeyer (universal)
./build.sh release   # also zips the plugin into dist/
```

Test the engine without Lightroom:

```bash
MediaDayKeyer.lrplugin/bin/mdkeyer process photo.jpg --out ~/Desktop/test [--psd]
```

## License

MIT. See [LICENSE](LICENSE).
