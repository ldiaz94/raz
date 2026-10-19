# raz's container registry

This Worker serves the `raz` image from a private R2 bucket using the
Docker Registry v2 protocol. It is a separate deployment from raz's
website and ladle source browser. The proposed public address is
`raz-registry.lucelad.workers.dev`; another account uses its own
workers.dev subdomain.

After deployment and publication, the image can be pulled with:

```sh
docker pull raz-registry.lucelad.workers.dev/raz:0.21.0-debian12-r1
```

Preparing these files does not create a Cloudflare deployment.

## Implementation and checks

`package.json` pins Cloudflare's Apache-2.0
[serverless-registry](https://github.com/cloudflare/serverless-registry)
to commit `a73605d6d5587286eb9cfcb910148f7d1423f218`.
`package-lock.json` fixes dependencies and archive integrity.
`worker.ts` adds anonymous pulls for `raz` alone. The upstream handles
authentication, storage, digest checks and multipart uploads.

Docker discovers a Bearer token endpoint at `/v2/`. Anonymous clients
receive pull-only tokens automatically; a publisher supplies Basic
credentials to receive a push token. Tokens last five minutes, are bound
to this registry's hostname and repository, and use HMAC-SHA256 with the
publisher secret as the signing key. Rotating that secret revokes tokens.
The adapter passes authorized operations to the upstream using its
appropriate read-only or publisher identity.

Anonymous reads use an upstream identity with pull capability alone;
knowing that public identity cannot authorize writes. Supplied
credentials are checked, including on the endpoint used by `docker
login`. Upload status also needs authentication. No other repositories,
catalog or fallback registry are exposed. The R2 bucket stays private.

Use Node 24 or later:

```sh
cd registry
npm ci
npm test
npm run dry-run
```

Tests use isolated local R2 storage, not a Cloudflare account. They
exercise anonymous reads, authentication and write restrictions,
repository scope, upload cancellation, and OCI manifest/blob upload
and pull by tag and digest, plus token scope, expiry, signature and
audience validation. The dry run bundles without publishing. To test
the actual Docker handshake with a built image:

```sh
npm run test:docker -- raz:0.21.0-debian12-r1
```

That test starts a disposable local Worker/R2 instance, pushes using
a generated test password, pulls with an empty Docker credential
directory, and runs the image smoke test. It needs a Docker engine on
the same host. Existing source-image tags are kept.

For local Docker testing, put a disposable `REGISTRY_PASSWORD` in the
ignored `.dev.vars` file and run `npm run dev`. Push to
`localhost:8787/raz:local-test`, using username `publisher`. Docker
permits HTTP for localhost; the deployed registry uses HTTPS. Do not
reuse a local password for production.

## First deployment

Enable R2 on the target Cloudflare account. Attach these values securely
to the environment running Wrangler:

- `CLOUDFLARE_ACCOUNT_ID`: the target account ID.
- `CLOUDFLARE_API_TOKEN`: an account-scoped secret with Workers Scripts
  Edit and Workers R2 Storage Edit. Do not commit or paste this token.

From `registry/`, after `npm ci` and local checks:

```sh
npx wrangler r2 bucket create raz-image-registry
npm run deploy
npx wrangler secret put REGISTRY_PASSWORD
```

Use a newly generated strong password for the last command; Wrangler
reads it interactively. This publisher password is separate from the
Cloudflare API token. Image publishers do not need the Cloudflare token.
Until the password is set, reads work but uploads cannot be authorized.
`REGISTRY_USERNAME` is `publisher`, set in `wrangler.jsonc`.

The deploy output gives the actual hostname. Its version endpoint should
return a 401 Bearer challenge pointing at `/token`; Docker follows that
challenge automatically, without requiring login for pulls:

```sh
curl -i https://raz-registry.lucelad.workers.dev/v2/
```

## Publishing images

The container workflow validates on relevant pushes. Its manual publish
option needs the deployed registry and GitHub Actions secret
`RAZ_REGISTRY_PASSWORD`. Set repository variable `RAZ_REGISTRY` to the
deployed hostname if it differs from the proposed address.

For a manual push, build and test `../containers/ci/` as its README
says, then:

```sh
registry=raz-registry.lucelad.workers.dev
docker login "$registry" --username publisher
docker tag raz:0.21.0-debian12-r1 "$registry/raz:0.21.0-debian12-r1"
docker push "$registry/raz:0.21.0-debian12-r1"
```

Keep published release tags fixed. A changed tool, base or package set
gets a new revision such as `r2`. This is a publishing convention: the
upstream permits authenticated tag replacement. The workflow serializes
its runs and refuses an existing tag; that does not prevent unrelated
manual publishers from replacing it. Pin the manifest digest in
downstream CI for an exact image.

Verify anonymous pulling with an empty Docker credential directory:

```sh
docker_config=$(mktemp -d)
docker --config "$docker_config" pull "$registry/raz:0.21.0-debian12-r1"
docker --config "$docker_config" run --rm "$registry/raz:0.21.0-debian12-r1" \
  sh /usr/local/share/raz-ci/smoke.sh
rm -r "$docker_config"
```

The Worker and R2 have their own request, storage and usage limits.
An individual Docker layer upload must fit the account's request body
limit: advertising chunk sizes does not make every Docker client split
a large layer. Keep compressed layers below 90 MB for headroom under a
100 MB request limit. Local tests cannot establish billing, hostname
availability or edge limits; repeat the push/pull test after deployment.
