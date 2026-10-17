"""Restore two missing docs for one byte-matched legacy Unity MCP Skill installation.
Default is a local check. --apply adds absent files only; existing files are never replaced.
This is not an updater: changed installed core files require a new provenance review.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request

COMMIT = '25357a0e75b97169d6bca1569df300915e182c7a'
EXISTING = {
    'SKILL.md': '45a6fd0007eeb03b5fdfb48b88a841a1df8c7f945ad386d0dfd5071458698b2f',
    'references/tools-reference.md': 'c457f25cdb5d62f08bfe1772da42010640cd30c6e6debad96083ef21f7f98311',
    'references/workflows.md': '5b230791f50d781e4ca129fe71b6af48d850f3299490721972b13670fd86084b',
    '.unity-mcp-skill-sync': 'f2842d64d8208a81d0b29fa7138abb0acf83636eebea505d5b18524a5535824f',
}
RESTORE = {
    'references/probuilder-guide.md': '2a6337a6ee9a8b5bc3aa129d0c6a967ee256f3edb54116e1c002b13a5fc1c215',
    'references/resources-reference.md': '5f39dbe1bf53bde80f5c1729a0f5ad2c956eca640084241d92aed61f0d28ddce',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inspect(root):
    if not root.is_dir() or (root / 'references').is_symlink():
        raise ValueError('Expected an existing Skill directory with a regular references directory')
    for name, expected in EXISTING.items():
        p = root / name
        if p.is_symlink() or not p.is_file() or sha(p.read_bytes()) != expected:
            raise ValueError('Installed version differs from reviewed snapshot: ' + name)
    missing = []
    for name, expected in RESTORE.items():
        p = root / name
        if p.is_symlink():
            raise ValueError('Refusing a symlink target: ' + name)
        if not p.exists():
            missing.append(name)
        elif not p.is_file() or sha(p.read_bytes()) != expected:
            raise ValueError('Existing reference differs; refusing replacement: ' + name)
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skill-dir', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = args.skill_dir.resolve()
    try:
        missing = inspect(root)
        added = []
        if args.apply and missing:
            downloads = {}
            for name in missing:
                url = 'https://raw.githubusercontent.com/CoplayDev/unity-mcp/' + COMMIT + '/unity-mcp-skill/' + name
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024 or sha(data) != RESTORE[name]:
                    raise ValueError('Downloaded reference failed pinned SHA-256 verification: ' + name)
                downloads[name] = data
            if inspect(root) != missing:
                raise ValueError('Installation changed during download; nothing added')
            for name, data in downloads.items():
                fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
                with os.fdopen(fd, 'wb') as output:
                    output.write(data)
                added.append(name)
            missing = inspect(root)
        print(json.dumps({'complete': not missing, 'missing': missing, 'added': added,
                          'commit': COMMIT, 'existingFilesUnchanged': True}))
        return 0 if not missing else 1
    except (OSError, ValueError) as error:
        print(json.dumps({'complete': False, 'error': str(error)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
