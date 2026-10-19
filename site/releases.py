"""Release commits shared by the home page and ladle's download pages.

Tags supply released versions. site/releases records existing website
distributions whose tags have not been pushed. Both must name commits
on main's first-parent line, and a later tag must agree with the record.
No tags or archives are created here.
"""
from pathlib import Path
import re
import subprocess


def main_ref(root):
    """Use main locally, or the detached commit supplied to a deployment.

    A build never silently publishes a different local working branch.
    The publishing service selects main before checking out its commit.
    """
    command = ['git', '-C', str(root)]
    if subprocess.run(command + ['show-ref', '--verify', '--quiet', 'refs/heads/main']).returncode == 0:
        return 'refs/heads/main'
    if subprocess.run(command + ['symbolic-ref', '--quiet', 'HEAD'], stdout=subprocess.DEVNULL).returncode:
        return 'HEAD'
    raise ValueError('site build needs main or a detached deployment checkout')


def refs(root, extra=()):
    """Return (version tag, full commit) pairs, oldest first.

    extra holds the optional vX.Y.Z=COMMIT arguments to make site,
    already split into pairs. Conflicting records are errors, so a
    build cannot quietly move an existing version to another commit.
    """
    root = Path(root)

    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()

    # Deployment services may give the build only one commit. The source
    # browser needs the history, and the same origin supplies its tags.
    if git('rev-parse', '--is-shallow-repository') == 'true':
        print('site: fetching full history and tags from origin')
        subprocess.run(['git', '-C', str(root), 'fetch', '--unshallow', '--tags', 'origin'], check=True)
    line = set(git('rev-list', '--first-parent', main_ref(root)).splitlines())
    selected = {}
    tagged = {}

    def add(tag, rev):
        if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
            raise ValueError('release version must be vX.Y.Z: ' + tag)
        if tuple(map(int, tag[1:].split('.'))) < (0, 7, 1):
            return
        commit = git('rev-parse', '--verify', '--end-of-options', rev + '^{commit}')
        if commit not in line:
            raise ValueError(f'release {tag}: {commit} is not on main\'s first-parent line')
        if tag in tagged and tagged[tag] != commit:
            raise ValueError(f'release {tag}: tag and recorded commits disagree')
        if tag in selected and selected[tag] != commit:
            raise ValueError(f'release {tag}: tag and recorded commits disagree')
        selected[tag] = commit

    for tag in git('tag', '-l', 'v*').splitlines():
        if re.fullmatch(r'v\d+\.\d+\.\d+', tag):
            # Tags on another development line are not this site's releases.
            commit = git('rev-parse', '--verify', tag + '^{commit}')
            tagged[tag] = commit
            if commit in line:
                add(tag, commit)
    manifest = root / 'site' / 'releases'
    for number, text in enumerate(manifest.read_text().splitlines(), 1):
        text = text.partition('#')[0].strip()
        if not text:
            continue
        words = text.split()
        if len(words) != 2 or not re.fullmatch(r'[0-9a-f]{40}', words[1]):
            raise ValueError(f'{manifest}:{number}: expected vX.Y.Z and full commit hash')
        add(*words)
    for tag, rev in extra:
        add(tag, rev)
    return sorted(selected.items(), key=lambda item: tuple(map(int, item[0][1:].split('.'))))
