#!/usr/bin/env python3
"""Check a docker-save stream against the registry's per-request size budget.

Docker's classic save format names layers */layer.tar. Newer exports may
put raw tar or already compressed layers under blobs/sha256/. Inspect both
without unpacking the image or retaining layers in memory.
"""

import argparse
import sys
import tarfile
import zlib


def check(stream, limit):
    layers = 0
    oversized = False
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            if not member.isfile():
                continue
            if not (member.name.endswith(".tar") or "/blobs/" in "/" + member.name):
                continue
            source = archive.extractfile(member)
            first = source.read(512)
            if first.startswith(b"\x1f\x8b"):
                size = member.size
            elif member.name.endswith(".tar") or first[257:263] in (b"ustar\0", b"ustar "):
                compressor = zlib.compressobj(level=6, wbits=31)
                size = len(compressor.compress(first))
                while chunk := source.read(1024 * 1024):
                    size += len(compressor.compress(chunk))
                size += len(compressor.flush())
            elif first.startswith(b"\x28\xb5\x2f\xfd"):
                raise ValueError("zstd layers are unsupported; export gzip layers for this registry")
            else:
                # Manifests, image configuration and other non-layer blobs.
                continue
            layers += 1
            status = "FAIL" if size >= limit else "OK"
            print(f"{status}: {member.name}: {size:,} compressed bytes", flush=True)
            oversized |= size >= limit
    if layers == 0:
        raise ValueError("no image layers found in docker save stream")
    print(f"Checked {layers} layers; each must be smaller than {limit:,} bytes.")
    return not oversized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-bytes", type=int, default=90_000_000)
    options = parser.parse_args()
    if options.max_bytes <= 0:
        parser.error("--max-bytes must be positive")
    try:
        return 0 if check(sys.stdin.buffer, options.max_bytes) else 1
    except (tarfile.TarError, ValueError, OSError) as error:
        print(f"Layer check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
