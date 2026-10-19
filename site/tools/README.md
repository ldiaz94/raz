# The website's ladle

`ladle.gz` is the static x86-64 Linux executable built from
`ldiaz94/ladle` at `509b9d314f6161a7430b8dc1354ba4ebe203ddb8`.
Its pinned dependencies are sauce `35e0c186db6b8861745c25925ca5b2489219e48d`
and rflate `c55b37888b071e98f57dcf18b97ab31f85595e76`.
`ladle.gz.sha256` checks the compressed file; `source.py` verifies it
before unpacking the executable into `build/site/`.

Keeping this small build tool with the site lets Cloudflare run the
existing `npx wrangler deploy` without a compiler or access to another
private repository. It is a deployment dependency, not a raz release.
Its source and tests remain in ladle's repository.

To replace it, clone ladle with its submodules and check out the
chosen commit. Unpack raz's checked v0.20.0 distribution, keeping its
`lib/` and `tools/` beside `raz`. From ladle's checkout:

```sh
make RAZ=/absolute/path/to/raz test fmt
```

From raz's checkout, pack that tested executable:

```sh
gzip -9n -c ../ladle/build/ladle > site/tools/ladle.gz
(cd site/tools && sha256sum ladle.gz > ladle.gz.sha256)
make site-source
```

Record the new commit and dependency pins here in the same change.
The executable includes debugging paths from its build directory;
another build may have a different checksum. The checksum pins this
tested artifact. Gzip adds neither a filename nor a wall-clock time.
