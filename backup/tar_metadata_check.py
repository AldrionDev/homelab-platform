#!/usr/bin/env python3
"""Authoritative validator for the generic backup archive contract.

Validates a tar.gz archive's member paths/types, exact supported layout,
manifest strictness, and manifest-vs-payload consistency entirely via
tarfile introspection, without extracting anything to disk. This is the
single implementation of these rules -- neither backup.sh nor restore.sh
re-implements any part of it in bash.

Usage:
    tar_metadata_check.py <archive-path> <expected-top-level-dir-name>

Exit 0: the archive fully satisfies the generic contract. The validated
manifest is printed to stdout as KEY=value lines (plus DATA_BASENAME for
dir-kind archives, a derived fact restore.sh needs but which is not itself
a manifest key).

Exit non-zero: the archive violates the contract. A single-line reason is
printed to stderr. Nothing is printed to stdout.
"""
import hashlib
import re
import sys
import tarfile

TOPDIR_PATTERN = re.compile(r'^[A-Za-z0-9-]+-[0-9]{8}T[0-9]{6}Z$')

MANIFEST_KEY_PATTERNS = {
    'BACKUP_ID': re.compile(r'^[A-Za-z0-9-]+$'),
    'SOURCE_KIND': re.compile(r'^(dir|db)$'),
    'CREATED_AT': re.compile(r'^[0-9]{8}T[0-9]{6}Z$'),
    'FORMAT_VERSION': re.compile(r'^1$'),
    'FILE_COUNT': re.compile(r'^[0-9]+$'),
    'TOTAL_BYTES': re.compile(r'^[0-9]+$'),
    'DUMP_SIZE_BYTES': re.compile(r'^[0-9]+$'),
    'DUMP_SHA256': re.compile(r'^[0-9a-fA-F]{64}$'),
}
ALWAYS_REQUIRED = ('BACKUP_ID', 'SOURCE_KIND', 'CREATED_AT', 'FORMAT_VERSION')
DIR_REQUIRED = ('FILE_COUNT', 'TOTAL_BYTES')
DB_REQUIRED = ('DUMP_SIZE_BYTES', 'DUMP_SHA256')
MANIFEST_OUTPUT_ORDER = (
    'BACKUP_ID', 'SOURCE_KIND', 'CREATED_AT', 'FORMAT_VERSION',
    'FILE_COUNT', 'TOTAL_BYTES', 'DUMP_SIZE_BYTES', 'DUMP_SHA256',
)


def fail(reason):
    sys.stderr.write('tar_metadata_check: ' + reason + '\n')
    sys.exit(1)


def split_components(raw_name, is_dir):
    """Returns the path components of a member name, or None if the name
    is empty or contains any unsafe component (absolute-path markers show
    up as an empty leading component; '.' and '..' are rejected outright;
    a bare repeated separator also shows up as an empty component) -- this
    single check is what makes every accepted name already fully
    normalized, so no separate alias-normalization pass is needed."""
    name = raw_name
    if is_dir and name.endswith('/'):
        name = name[:-1]
    if name == '':
        return None
    parts = name.split('/')
    for part in parts:
        if part in ('', '.', '..'):
            return None
    return parts


def check_member_safety(member, expected_topdir):
    if member.name.startswith('/'):
        fail('member has an absolute path: {0!r}'.format(member.name))
    parts = split_components(member.name, member.isdir())
    if parts is None:
        fail('member path is empty or contains an unsafe component: {0!r}'.format(member.name))
    if parts[0] != expected_topdir:
        fail('member is outside the expected top-level directory: {0!r}'.format(member.name))
    if not (member.isreg() or member.isdir()):
        fail('member is not a regular file or directory: {0!r} (type {1!r})'.format(member.name, member.type))
    if member.linkname:
        fail('member has a populated link target: {0!r}'.format(member.name))
    return tuple(parts)


def parse_manifest(raw_bytes):
    try:
        text = raw_bytes.decode('utf-8')
    except UnicodeDecodeError:
        fail('manifest is not valid UTF-8')
    if text == '' or not text.endswith('\n'):
        fail('manifest is empty or not newline-terminated')
    lines = text.split('\n')[:-1]
    if not lines:
        fail('manifest has no entries')
    values = {}
    for line in lines:
        if '=' not in line:
            fail('manifest line is not KEY=value: {0!r}'.format(line))
        key, _, value = line.partition('=')
        if key not in MANIFEST_KEY_PATTERNS:
            fail('manifest has an unknown key: {0!r}'.format(key))
        if key in values:
            fail('manifest has a duplicate key: {0!r}'.format(key))
        if value == '' or not MANIFEST_KEY_PATTERNS[key].match(value):
            fail('manifest key {0!r} has a malformed value: {1!r}'.format(key, value))
        values[key] = value

    for key in ALWAYS_REQUIRED:
        if key not in values:
            fail('manifest is missing required key: {0!r}'.format(key))

    kind = values['SOURCE_KIND']
    required, forbidden = (DIR_REQUIRED, DB_REQUIRED) if kind == 'dir' else (DB_REQUIRED, DIR_REQUIRED)
    for key in required:
        if key not in values:
            fail('manifest is missing {0}-kind required key: {1!r}'.format(kind, key))
    for key in forbidden:
        if key in values:
            fail('manifest has a key not permitted for {0}-kind: {1!r}'.format(kind, key))
    if len(values) != len(ALWAYS_REQUIRED) + len(required):
        fail('manifest has unexpected extra keys')

    if kind == 'db' and int(values['DUMP_SIZE_BYTES']) <= 0:
        fail('manifest DUMP_SIZE_BYTES must be greater than zero')

    return values


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('usage: tar_metadata_check.py <archive-path> <expected-top-level-dir-name>\n')
        sys.exit(2)
    archive_path, expected_topdir = sys.argv[1], sys.argv[2]
    if not TOPDIR_PATTERN.match(expected_topdir):
        fail('expected top-level directory name is malformed: {0!r}'.format(expected_topdir))

    try:
        tf = tarfile.open(archive_path, mode='r:gz')
    except (tarfile.TarError, OSError) as exc:
        fail('archive could not be opened: {0}'.format(exc))

    with tf:
        try:
            members = tf.getmembers()
        except (tarfile.TarError, OSError) as exc:
            fail('archive could not be listed: {0}'.format(exc))

        seen_names = set()
        manifest_member = None
        data_members = []  # (relative_parts_under_data, member)
        dump_members = []  # (relative_parts_under_dump, member)

        for member in members:
            parts = check_member_safety(member, expected_topdir)
            # Keyed on the already-normalized components, not the raw
            # member.name -- otherwise syntactic aliases that normalize to
            # the same extraction path (e.g. a directory member named
            # "topdir/data" vs "topdir/data/") would not collide here.
            if parts in seen_names:
                fail('archive has a duplicate member path: {0!r}'.format(member.name))
            seen_names.add(parts)

            rel = parts[1:]
            if len(rel) == 0:
                continue  # the bare top-level directory entry itself
            if rel == ('manifest',):
                if not member.isreg():
                    fail('manifest member is not a regular file')
                manifest_member = member
                continue
            if rel[0] == 'data':
                if len(rel) == 1:
                    # the bare "data/" directory scaffolding entry that tar
                    # emits for every directory level -- harmless, not payload
                    if not member.isdir():
                        fail('data must be a directory: {0!r}'.format(member.name))
                    continue
                data_members.append((rel[1:], member))
                continue
            if rel[0] == 'dump':
                if len(rel) == 1:
                    # the bare "dump/" directory scaffolding entry
                    if not member.isdir():
                        fail('dump must be a directory: {0!r}'.format(member.name))
                    continue
                dump_members.append((rel[1:], member))
                continue
            fail('archive has content outside the supported layout: {0!r}'.format(member.name))

        if manifest_member is None:
            fail('archive is missing the manifest')

        manifest_bytes = tf.extractfile(manifest_member).read()
        manifest = parse_manifest(manifest_bytes)

        expected_identity = '{0}-{1}'.format(manifest['BACKUP_ID'], manifest['CREATED_AT'])
        if expected_identity != expected_topdir:
            fail('manifest BACKUP_ID/CREATED_AT do not match the archive identity')

        kind = manifest['SOURCE_KIND']
        data_basename = None

        if kind == 'dir':
            if dump_members:
                fail('dir-kind archive has dump/ content')
            if not data_members:
                fail('dir-kind archive has no data/ content')
            first_components = set(rel[0] for rel, _ in data_members)
            if len(first_components) != 1:
                fail('data/ does not have exactly one source-basename subdirectory')
            data_basename = next(iter(first_components))
            regular = [(rel, m) for rel, m in data_members if m.isreg()]
            file_count = len(regular)
            total_bytes = sum(m.size for _, m in regular)
            if str(file_count) != manifest['FILE_COUNT']:
                fail('manifest FILE_COUNT does not match archived payload')
            if str(total_bytes) != manifest['TOTAL_BYTES']:
                fail('manifest TOTAL_BYTES does not match archived payload')
        else:
            if data_members:
                fail('db-kind archive has data/ content')
            if len(dump_members) != 1 or dump_members[0][0] != ('dump.bin',):
                fail('db-kind archive must contain exactly dump/dump.bin')
            dump_member = dump_members[0][1]
            if not dump_member.isreg():
                fail('dump/dump.bin is not a regular file')
            if str(dump_member.size) != manifest['DUMP_SIZE_BYTES']:
                fail('manifest DUMP_SIZE_BYTES does not match the archived dump')
            fileobj = tf.extractfile(dump_member)
            digest = hashlib.sha256()
            for chunk in iter(lambda: fileobj.read(65536), b''):
                digest.update(chunk)
            if digest.hexdigest().lower() != manifest['DUMP_SHA256'].lower():
                fail('manifest DUMP_SHA256 does not match the archived dump')

    output_lines = []
    for key in MANIFEST_OUTPUT_ORDER:
        if key in manifest:
            output_lines.append('{0}={1}'.format(key, manifest[key]))
    if data_basename is not None:
        output_lines.append('DATA_BASENAME={0}'.format(data_basename))
    sys.stdout.write('\n'.join(output_lines) + '\n')
    sys.exit(0)


if __name__ == '__main__':
    main()
