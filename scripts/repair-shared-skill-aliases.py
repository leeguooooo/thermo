"""Version-pinned repair of three drifted shared Skill mirrors. Default: check only.
Uses installed-binary Skill hashes verified in isolated HOME directories. Never
executes a business tool, starts an agent, or changes config. Original directories
are retained in a private backup. Unsupported content is never overwritten.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

PINS = {
    'message-use': ('efbed0d7a9f92c6158e62402a86446a48c29352c25ff3e01ad0cc00bd53243d4', '19b41fb2bf6af35f386e294eeaa74677b028953be076c957ef571b67e93fb3ad', 'a9c3e2452fa8d9aa6016e434e42f147fe538ade6ebb855a40815758f1bf27cf7'),
    'paste-use': ('feea8168e9f90484b47cd84d182cfdda72d0372180d0151555c176f13d34491b', '75ccd5ba12ac41db3292daa7bbe56b40f51023282d0acadb2b1d70e3f8c6dabb', 'fb110dd781565eb406c3eb315c5d95f1761a9570e1281b25a224e3c464e354c5'),
    'sflow': ('468025d06032587ee20cca919e8eece3fb987853af1c6cb76945b5460bc0ec0a', '067f8276cc50d98a244279a80ca954069fe0f8adeff12b3432734b99c37f63d2', '157fb0f94ffb2279e8ea033cd1c2f49ed9325103bac356c81dbd8b148d9d30f5'),
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def plan(home):
    result = []
    for name, (binary_hash, document_hash, old_hash) in PINS.items():
        source = home/'.codex/skills'/name
        target = home/'.agents/skills'/name
        if target.is_symlink() and target.resolve() == source.resolve():
            if not (source/'SKILL.md').is_file():
                raise ValueError(name+': linked Skill source is missing')
            result.append({'skill': name, 'status': 'already-linked'})
            continue
        if source.resolve() != source or target.resolve() != target:
            raise ValueError(name+': unexpected managed path; refusing to replace it')
        for folder in [source, target]:
            if not stat.S_ISDIR(folder.lstat().st_mode) or folder.lstat().st_uid != os.getuid():
                raise ValueError(name+': expected an owned Skill directory')
            if set(p.name for p in folder.iterdir()) != {'SKILL.md'}:
                raise ValueError(name+': unreviewed resources; refusing to replace directory')
            file = folder/'SKILL.md'
            if not stat.S_ISREG(file.lstat().st_mode) or file.lstat().st_uid != os.getuid():
                raise ValueError(name+': expected an owned regular Skill file')
        if sha(home/'.local/bin'/name) != binary_hash or sha(source/'SKILL.md') != document_hash:
            raise ValueError(name+': binary/source version is outside the reviewed pins')
        current = sha(target/'SKILL.md')
        if current not in [old_hash, document_hash]:
            raise ValueError(name+': shared content changed; refusing to overwrite it')
        result.append({'skill': name, 'status': 'repairable', 'beforeSHA256': current,
                       'sourceSHA256': document_hash, 'targetInode': target.lstat().st_ino})
    return result

def repair(home, expected):
    if plan(home) != expected:
        raise ValueError('plan changed before applying')
    parent = home/'.codex/backups'
    parent.mkdir(mode=0o700, exist_ok=True)
    if parent.is_symlink():
        raise ValueError('backup parent must not be a symlink')
    backup = parent/('shared-skill-aliases-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700)
    completed = []
    try:
        for row in expected:
            if row['status'] != 'repairable': continue
            name = row['skill']; target = home/'.agents/skills'/name; source = home/'.codex/skills'/name
            if target.lstat().st_ino != row['targetInode'] or sha(target/'SKILL.md') != row['beforeSHA256'] or sha(source/'SKILL.md') != row['sourceSHA256']:
                raise ValueError(name+': files changed before linking')
            target.rename(backup/name)
            try:
                # symlink creation fails if another writer created this path.
                target.symlink_to(source, target_is_directory=True)
            except BaseException:
                if not target.exists() and not target.is_symlink():
                    (backup/name).rename(target)
                raise
            completed.append((name, target.lstat().st_ino))
            if sha(target/'SKILL.md') != row['sourceSHA256']:
                raise ValueError(name+': linked source changed during repair')
        manifest = {'plan': expected, 'completed': [name for name, _ in completed]}
        file = backup/'manifest.json'
        fd = os.open(file, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: json.dump(manifest, stream, indent=2)
        return backup
    except BaseException:
        for name, inode in reversed(completed):
            target = home/'.agents/skills'/name
            if target.is_symlink() and target.lstat().st_ino == inode and target.readlink() == home/'.codex/skills'/name:
                target.unlink(); (backup/name).rename(target)
        file = backup/'failed.json'
        fd = os.open(file, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'originalsRetained': [p.name for p in backup.iterdir() if p.is_dir()], 'completedBeforeFailure': [name for name, _ in completed]}, stream)
        raise

def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument('--apply', action='store_true')
    arguments.add_argument('--home', type=Path, default=Path.home(), help='Owned fixture home for offline checks')
    options = arguments.parse_args()
    home = options.home.resolve()
    try:
        expected = plan(home)
        backup = repair(home, expected) if options.apply and any(r['status']=='repairable' for r in expected) else None
        print(json.dumps({'applied': backup is not None, 'plan': expected, 'backupDirectory': str(backup) if backup else None}))
    except (ValueError, OSError) as error:
        arguments.exit(2, str(error)+'\n')

if __name__ == '__main__': main()
