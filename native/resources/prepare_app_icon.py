"""Derive native icon resources from the approved, opaque Heartling masters.

Requires Pillow and NumPy. Run: python3 resources/prepare_app_icon.py
Forest is ../assets/logo.png; the other masters
are resources/app-icons/{midnight,blossom}.png. All were generated in
Amp thread T-01a179be-3f68-7128-952f-03993d502a0c, attachment
06aebe5e855f2900796747b4c5f702daf3e49d0eebd939b0f7b33a5997bea018-file.png
and its Midnight (26c7dcb4) / Blossom (0b3ad4bd) variations.
"""

from pathlib import Path
from shutil import copyfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "android/res/drawable-xxxhdpi"
IOS = ROOT / "resources/app-icons/ios"


def android_layers(source, name):
    pixels = np.asarray(source).astype(float)
    # Background pixels are dark; clay pixels are bright. Flood-fill only the
    # exterior so both dark eyes remain part of the opaque foreground.
    exterior = Image.fromarray(np.where(pixels.min(axis=2) < 130, 0, 255).astype(np.uint8)).copy()
    ImageDraw.floodfill(exterior, (0, 0), 128)
    silhouette = Image.fromarray(np.where(np.asarray(exterior) == 128, 0, 255).astype(np.uint8))
    alpha = silhouette.filter(ImageFilter.GaussianBlur(0.45))
    foreground = source.convert("RGBA")
    foreground.putalpha(alpha)

    # Android layers are 108dp. Keep the whole mascot within the central
    # 66dp safe zone, including launchers that use a circular mask.
    foreground = foreground.resize((300, 300), Image.Resampling.LANCZOS)
    layer = Image.new("RGBA", (432, 432))
    layer.paste(foreground, (66, 66))
    layer.save(DESTINATION / f"ic_launcher{name}_foreground.png", optimize=True)

    # Themed icons retain the silhouette and two eye cutouts, not clay shading.
    eyes = (pixels.max(axis=2) < 100) & (np.asarray(silhouette) > 0)
    monochrome_alpha = np.asarray(silhouette).copy()
    monochrome_alpha[eyes] = 0
    monochrome = Image.new("RGBA", source.size, "white")
    monochrome.putalpha(Image.fromarray(monochrome_alpha).filter(ImageFilter.GaussianBlur(0.45)))
    monochrome = monochrome.resize((300, 300), Image.Resampling.LANCZOS)
    layer = Image.new("RGBA", (432, 432))
    layer.paste(monochrome, (66, 66))
    layer.save(DESTINATION / f"ic_launcher{name}_monochrome.png", optimize=True)


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    IOS.mkdir(parents=True, exist_ok=True)
    for name in ("forest", "midnight", "blossom"):
        master = (ROOT.parent / "assets/logo.png" if name == "forest"
                  else ROOT / f"resources/app-icons/{name}.png")
        if name == "forest":
            copyfile(master, ROOT / "ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        source = Image.open(master).convert("RGB")
        source.resize((192, 192), Image.Resampling.LANCZOS).save(IOS / f"icon_{name}.png", optimize=True)
        android_layers(source, "" if name == "forest" else f"_{name}")
        if name != "forest":
            # UIKit's alternate icons are loose bundle PNGs. Explicit iPhone
            # and iPad entries avoid relying on actool's primary-icon output.
            for suffix, size in (("@2x", 120), ("@3x", 180), ("~ipad", 76),
                                 ("@2x~ipad", 152), ("83.5@2x~ipad", 167)):
                source.resize((size, size), Image.Resampling.LANCZOS).save(
                    IOS / f"AppIcon{name.title()}{suffix}.png", optimize=True)


if __name__ == "__main__":
    main()
