#!/usr/bin/env python3
"""Export this project's current source tree without parent Git history or local artifacts."""

import argparse
import shutil
from pathlib import Path


ROOT_ENTRIES = {
    "App", "Sources", "Tests", "Vendor", "scripts", "docs", "Legado.xcodeproj",
    ".github", ".gitignore", "Package.swift", "Package.resolved", "README.md",
    "LICENSE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "CHANGELOG.md",
}
SKIP_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "DerivedData", "artifacts", "build", "node_modules",
    ".gradle", ".idea", ".vscode", ".sisyphus", "xcuserdata", "__pycache__",
    ".codex", ".agents", ".aws",
}
SKIP_SUFFIXES = {
    ".ipa", ".apk", ".aab", ".log", ".pyc", ".pyo", ".p12", ".p8", ".pem",
    ".key", ".keystore", ".jks", ".mobileprovision", ".xcuserstate",
}


def excluded(path: Path) -> bool:
    return (
        path.is_symlink()
        or path.name in SKIP_DIRECTORIES
        or path.name == ".DS_Store"
        or path.name == ".env"
        or (path.name.startswith(".env.") and path.name != ".env.example")
        or path.suffix in SKIP_SUFFIXES
        or path.name.endswith((".xcresult", ".dSYM"))
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="New, empty destination outside the project")
    parser.add_argument("--without-github-actions", action="store_true", help="Exclude GitHub Actions workflow files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = args.destination.expanduser().resolve()
    if destination.exists():
        parser.error("destination must not already exist; choose a new directory")
    if destination.is_relative_to(root) or root.is_relative_to(destination):
        parser.error("destination must be outside the source project")
    missing = [name for name in ROOT_ENTRIES if not (root / name).exists()]
    if missing:
        parser.error("missing required project entries: " + ", ".join(sorted(missing)))

    def ignore(directory: str, names: list[str]) -> list[str]:
        return [
            name for name in names
            if excluded(Path(directory) / name)
            or (args.without_github_actions and Path(directory) == root / ".github" and name == "workflows")
        ]

    destination.mkdir(parents=True)
    for name in sorted(ROOT_ENTRIES):
        source = root / name
        if excluded(source):
            continue
        if source.is_dir():
            shutil.copytree(source, destination / name, ignore=ignore)
        else:
            shutil.copy2(source, destination / name)
    count = sum(1 for path in destination.rglob("*") if path.is_file())
    print(f"Exported {count} source files to {destination}")
    print("No repository was created or published. Review this copy before initializing a new Git repository.")


if __name__ == "__main__":
    main()
