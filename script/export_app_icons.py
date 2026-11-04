"""Export both Icon Composer masters to the macOS AppIcon asset set (requires Pillow)."""

import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
ICON_SET = ROOT / "MusicIntelligenceTool/MusicIntelligenceTool/Assets.xcassets/AppIcon.appiconset"


def main():
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    ictool = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    with TemporaryDirectory() as temp:
        for master, sizes in [("AppIcon-small", (16, 32, 64)), ("AppIcon", (128, 256, 512, 1024))]:
            rendered = Path(temp) / f"{master}.png"
            subprocess.run([
                ictool, ROOT / "design" / f"{master}.icon", "--export-image", "--output-file", rendered,
                "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024",
                "--scale", "1",
            ], check=True)
            with Image.open(rendered) as image:
                # Composer exports edge to edge. Restore the original 100 px macOS inset and outer shadow.
                face = image.convert("RGBA").resize((824, 824), Image.Resampling.LANCZOS)
                canvas = Image.new("RGBA", (1024, 1024))
                shadow = Image.new("L", canvas.size)
                shadow.paste(face.getchannel("A"), (100, 110))
                canvas.putalpha(shadow.filter(ImageFilter.GaussianBlur(12)).point(lambda a: round(a * 0.3)))
                canvas.alpha_composite(face, (100, 100))
                for size in sizes:
                    canvas.resize((size, size), Image.Resampling.LANCZOS).save(
                        ICON_SET / f"mac-{size}.png", icc_profile=image.info.get("icc_profile")
                    )


if __name__ == "__main__":
    main()
