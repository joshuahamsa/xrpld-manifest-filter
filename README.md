# xrpld manifest-flood filter

> **Status: retired — fixed upstream in xrpld 3.2.1 (2026-08-01).**
> Following the manifest flood of 2026-07-31, upstream shipped the fix this patch worked
> around: a per-manifest size cap, a per-message cap on untrusted manifests (inbound and
> outbound), a cache cap of 100 unknown validator keys, and no disk persistence of
> untrusted manifests. That is a superset of what this patch does — it additionally bounds
> the local cache, which this patch deliberately left unbounded. If you are running this
> patch, drop it and upgrade to stock 3.2.1 or later (per the official advisory: update,
> wait 1–2 minutes, then restart once more to flush previously persisted flood manifests).
> The node this was written for has done exactly that. The patch below is kept as a
> historical record.

A small out-of-tree patch for [XRPLF/rippled](https://github.com/XRPLF/rippled) (`xrpld`) that stops a
node from re-broadcasting untrusted validator manifests and from dumping its entire manifest cache to
every newly connected peer.

**Two files, +65 / −4 lines.** This is a patch, not a fork — apply it to an upstream tag and build.

## The problem

`xrpld` accepts every well-formed manifest it is offered and caches it. Two code paths then send that
cache back out to the network:

1. `OverlayImpl::onManifests` relays *every* accepted manifest to all peers.
2. `OverlayImpl::getManifestsMessage` builds the manifest message sent on each peer handshake from the
   **entire** cache.

Neither path filters on whether the manifest's master key is on a configured validator list. A node
that has accumulated a large number of untrusted manifests therefore ships them to everyone it meets.

On the node this was written for, the cache had grown to roughly **190,000 manifests**, producing a
**~58 MB `mtMANIFESTS` message per newly connected peer**. That starves the send queue: peer churn
gets worse, which causes more handshakes, which sends more 58 MB messages. Symptoms look like generic
peer instability and sync trouble, so the manifest cache is not an obvious place to look.

Manifests whose master key is not on any configured validator list are not used for validation and are
not written to the wallet DB. Relaying them buys nothing.

## What the patch does

Inbound processing is **unchanged** — every well-formed manifest is still accepted, still cached, still
published to `pubManifest` subscribers. Only what goes *out* is restricted:

| Path | Before | After |
|---|---|---|
| `onManifests` relay set | every accepted manifest | only if master key is listed **or** a trusted publisher key |
| `getManifestsMessage` (handshake) | entire manifest cache | same filter — message is bounded by configured validator lists, not by cache size |

A `debug`-level line reports accepted vs. relayed counts per `onManifests` call so you can confirm the
suppression is active:

```
onManifests: accepted 412, relaying 3
```

### One implementation note worth reading before you review it

The filter in `getManifestsMessage` runs in **two passes**. `ValidatorList::listed()` and
`trustedPublisher()` call back into the `ManifestCache` via `getMasterKey()`, and calling `ManifestCache`
members from inside a `forEachManifest` callback re-locks the cache mutex on the same thread — undefined
behaviour (see the note on `ManifestCache::forEachManifest` in `Manifest.h`). So:

- **Pass 1** snapshots master keys under the callback.
- The filter runs with the cache lock released.
- **Pass 2** serializes only the keys that survived.

The obvious one-pass version deadlocks or worse. Do not "simplify" it.

### Escape hatch

`PeerImp::doProtocolStart` carries a comment marking the two lines that send the handshake manifest
message. Commenting them out is a zero-risk fallback if the filtered build ever misbehaves — it only
makes the node a poor manifest relayer; inbound manifest processing is unaffected either way.

## Applying

```sh
git clone https://github.com/XRPLF/rippled.git
cd rippled
git checkout 3.3.0-b1
git am /path/to/0001-overlay-only-relay-and-serve-validator-listed-manife.patch
```

The patch is in `git format-patch` (mbox) form, so `git am` carries the commit message and records
`base-commit: 58af1e6f188549074e5cd82c38d06bcf7e8d334d`.

### Version compatibility

Verified by actually running `git am` against a clean worktree of each ref:

| Ref | Result |
|---|---|
| `3.3.0-b1` (`58af1e6`) — the base it was written against | applies clean |
| `develop` @ `8306ac7` (fetched 2026-07-11) | applies clean (`--3way`) |
| `3.2.0` and earlier | **not tested** — tag not fetched locally |

The deployed binary this was written for reports `3.2.0-hamsa-manifest-filter.1`; that build came from a
separate tree that no longer exists on the build host, so the 3.2.0 line is unverified here even though
it is what is in production. If you are on 3.2.x, apply with `--3way` and read the result.

## Building

Nothing about the patch changes the build, so **follow upstream's `BUILD.md`** for your version — it is
the authoritative and maintained procedure, and it moves.

The included `Dockerfile` is the toolchain image actually used to produce the deployed binary
(Ubuntu 24.04, gcc/g++-13, cmake, ninja, conan 2.x), provided so you can reproduce the environment
rather than the exact commands:

```sh
docker build -t xrpld-build .
docker run --rm -it -v "$PWD/rippled:/src" xrpld-build bash
# then run upstream's BUILD.md conan/cmake steps inside the container
```

The conan/cmake invocation is deliberately not reproduced here — the exact command used for the
deployed build was not captured in the build logs, and a half-remembered one would be worse than
sending you to upstream's.

The binary lands in the build directory. Install it somewhere versioned (e.g.
`/opt/xrpld-custom/<version>/xrpld`) and point your systemd unit at it, rather than overwriting the
packaged binary — that keeps a rollback one `systemctl` edit away.

## Field status

Ran in production on a mainnet validator from 2026-07-24 until 2026-08-01, when the node
moved to stock 3.2.1 (see the retirement notice above). While deployed:

- `server_state: full`, 8 peers, stable across a 5+ hour observation window at time of writing
- no excess logging, no manifest-related warnings

This is **not** an upstream-blessed change. It alters peer-facing relay behaviour. Read the diff,
understand the two-pass note above, and test on a non-validating node before you put it under a
validator key.

## Upstream

This happened: xrpld 3.2.1 ships the fix (see the retirement notice at the top). The
paragraph below is left as originally written.

The right long-term home for this is upstream. If you hit the same problem, weighing in on an
upstream issue is more useful than everyone carrying a private patch.

## License

The patch is a derivative of rippled and carries rippled's license (ISC). See
[XRPLF/rippled](https://github.com/XRPLF/rippled) for the full text.
