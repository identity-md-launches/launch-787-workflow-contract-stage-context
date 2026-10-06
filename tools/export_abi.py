#!/usr/bin/env python3
"""Export/check plain compiler ABI arrays after forge build. No third-party packages."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    names = ("LaunchToken", "CompanyStaking", "SniperVault", "ILaunchRegistry", "ITradingVenue")
    for name in names:
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.exists():
            raise SystemExit(f"Missing {artifact}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        content = json.dumps(abi, indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.exists() or destination.read_text() != content:
                raise SystemExit(f"ABI is absent or stale: {destination}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
        print(f"{'Verified' if args.check else 'Exported'} {name}")


if __name__ == "__main__":
    main()
