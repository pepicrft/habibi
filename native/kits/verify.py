"""Verify reviewed Kit page sources, manifests and executable bundles."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def verify(record=False):
    for folder in sorted((ROOT / "kits").iterdir()):
        if not folder.is_dir():
            continue
        kit = folder.name
        config = json.loads((folder / "nsh.json").read_text())
        if config["capabilities"] != {}:
            raise ValueError("Kit pages cannot declare external capabilities")
        files = [f"kits/{kit}/App.tsx", f"kits/{kit}/nsh.json", f"core/assets/{kit}-page.js"]
        hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files}
        expected = {"runtime": "0.2.0", "sha256": hashes}
        lock = folder / "bundle.json"
        manifest_path = ROOT / f"core/assets/{kit}-kit.json"
        manifest = json.loads(manifest_path.read_text())
        digest = hashes[f"core/assets/{kit}-page.js"]
        if record:
            lock.write_text(json.dumps(expected, indent=2) + "\n")
            manifest["presentation"]["sha256"] = digest
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        if json.loads(lock.read_text()) != expected:
            raise ValueError(f"Regenerate {kit}'s reviewed Kit page using kits/build.sh")
        page = manifest["presentation"]
        if page["version"] != 1 or page["entry"] != f"{kit}-page.js" or page["sha256"] != digest:
            raise ValueError(f"Invalid {kit} page declaration")
        if not page["fallback"].strip() or len(page["fallback"].encode()) > 4000:
            raise ValueError(f"Invalid {kit} page fallback")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    verify(args.record)
    if args.output:
        args.output.write_text(json.dumps({"runtime": "0.2.0", "verified": True}) + "\n")
    print("NSH Kit page sources and bundles verified")
