# Monobot

Monobot generates the monogres catalog: for every extension and Postgres
flavor, the archive each version is downloaded from and the SHA256 that pins
it. It reads a `monobot.json` per entry, downloads the archives that entry
names, digests them, and writes the `repo.json` beside it that
[monogres](https://github.com/monogres/monogres) builds from.

The catalog is version controlled, so what monobot produces has an exact
answer to be held to. `mode=check` is that gate.

## How It Works

Monobot runs as a pipeline with two phases:

1. **Scan** -- Recursively discovers `monobot.json` files under the catalog
   directory. Each one is an entry.
2. **Fetch** -- For each entry, works out which archive each of its versions
   names, downloads the ones the cache cannot answer for, digests them, reads
   what they carry, and writes `repo.json` beside the `monobot.json` it came
   from.

Archive downloads run concurrently via Vert.x async futures, up to
`maxConcurrentDownloads` of them at a time across the whole scan.

Every archive is kept under `cacheDir`, in a tree that mirrors the catalog and
adds a level per version, beside a `fetch.json` recording the URL it came from,
its digest, its length and whatever validators the source gave for it:

```txt
{cacheDir}/extensions/pgvector/0.8.2/pgvector-0.8.2.tar.gz
{cacheDir}/extensions/pgvector/0.8.2/fetch.json
{cacheDir}/extensions/pgvector/0.8.2/vector.control
{cacheDir}/extensions/pgvector/0.8.2/META.json
```

A version whose archive the cache can answer for costs no request. `verifyCache`
decides how much of the file is checked first, and `refreshCache` asks the source
anyway, conditionally, so an unchanged archive costs a 304. Nothing is ever
deleted from the cache: the archives are the raw data every value in `repo.json`
is derived from.

## Modes

`mode` says what a run does with the tree it is pointed at. The expensive half
is the same in all of them, which is why they are one program over one cache:
a cold `fetch` is gigabytes and the rest are not.

| Mode | What it does |
| --- | --- |
| `generate` | Fills the cache and writes the catalog. The default. |
| `check` | Builds every document `generate` would write, compares against what is committed, and writes none of them. A difference fails the entry. |
| `fetch` | Fills the cache and stops. The download pass on its own. |
| `import` | Reads each `repo.json` and writes the `monobot.json` it would be generated from. Asks nothing of the network. |

## Configuration

### Runtime Properties

Monobot reads nine properties, two of them required, provided as environment
variables or command line properties (`-D...`). The seven that are optional
have defaults in `src/main/resources/application.properties`:

| Property | Required | Description |
| --- | --- | --- |
| `catalogDir` | yes | Root of the catalog. Every `monobot.json` under it is an entry, and its `repo.json` is written beside it |
| `cacheDir` | yes | Root of the archive cache, one directory per entry per version |
| `mode` | no | `generate`, `check`, `fetch` or `import`. Defaults to `generate`. |
| `maxConcurrentDownloads` | no | How many archive downloads may be in flight at once, across the whole scan rather than per extension. Defaults to `4`. |
| `downloadTimeout` | no | How long one download may take, as an ISO8601 duration. Defaults to `PT5M`. |
| `tagListTimeout` | no | How long one tag listing may take, as an ISO8601 duration, applied as both the connect and the read timeout. Defaults to `PT30S`. Counted in whole seconds, and anything under a second is raised to one. |
| `runTimeout` | no | How long the whole scan may take, as an ISO8601 duration. Defaults to `PT1H`. Reaching it exits non-zero. |
| `verifyCache` | no | How much of a cached archive is checked before a run answers from it: `size` compares its length against the length recorded for it, `digest` compares its digest, `none` takes the record at its word. Defaults to `size`. |
| `refreshCache` | no | Whether to ask the source about archives the cache can already answer for. The request carries the recorded validators, so an unchanged archive costs a 304. Defaults to `false`. |

### Exit status and the run summary

Every run prints one summary line on its way out, whatever the outcome, giving
how many entries were scanned, how many of them failed, how many versions were
added, how many were skipped and why, and how many documents were written:

```text
Scanned 3 extensions, 1 of them failed: 5 versions added, 41 skipped
  (38 already catalogued, 2 outside satisfy, 1 refused downloads), 2 documents written
```

A failed entry does not stop the run, so the exit status is what says one
happened:

| Status | Meaning |
| --- | --- |
| `0` | Every entry the scan found completed. |
| `1` | Some entries completed and some failed. |
| `2` | No entry completed: either every one of them failed, or the run did not finish within `runTimeout`. |

An entry fails when its `monobot.json` cannot be read, when its stored
`repo.json` cannot be read, when its tags cannot be listed, when any of its
archives could not be downloaded, when a digest disagrees with the one already
catalogued, or when `check` finds a difference. Everything else is a skip, and
skips are reported in the summary rather than in the exit status.

### Input: `monobot.json`

Each entry has a `monobot.json` under `catalogDir`, and its `repo.json` is
written beside it. Everything monobot cannot work out for itself is in here:

```json
{
  "version": 1,
  "name": "vector",
  "url": "https://github.com/pgvector/pgvector",
  "sources": {
    "gh": {
      "tag": "v{version}",
      "gh_org": "pgvector",
      "name": "pgvector",
      "filename": "{tag}",
      "strip_prefix": "{name}-{version}",
      "url": "https://github.com/{gh_org}/{name}/archive/refs/tags/{filename}.tar.gz"
    }
  },
  "versions": { "pin": ["0.8.2"] },
  "metadata": {
    "compatible_with": { "postgres": ">=13" }
  }
}
```

Fields:

- `name` (optional) -- The stem of the control file to look for inside each
  archive (`{name}.control`), and the prefix every log line about the entry
  carries. It is the extension's own name and not the repository's, and the two
  diverge routinely, so pgvector needs `"name": "vector"`. Optional because the
  Postgres flavors have no single control file. A name that matches none leaves
  the version with no control document, with one WARN line saying so.
- `url` (optional) -- The git repository, read only to list tags, so it is
  needed only alongside a `versions.discover` block. It is not where the
  archives come from: postgis has both and they disagree on purpose, since its
  tags are on GitHub and its tarballs are on `download.osgeo.org`.
- `sources` (required) -- Carried into `repo.json` as it stands. See below.
- `versions` (required) -- `pin`, `discover`, or both. See below.
- `metadata` (optional) -- Carried into `repo.json` as it stands, in the order
  written. Whatever the monogres build reads there is somebody else's schema and
  monobot does not model it.
- `disabled` (optional) -- When `true`, the entry is left alone: no tags listed,
  no archives downloaded, and the `repo.json` a previous run wrote stays as it
  is.

#### `sources`

A `download_archives` index template
(`@download_archives//lib:index.bzl`), copied into `repo.json` unchanged. Each
property is materialized in the order it is declared, substituted with what is
already defined, so **property order is load-bearing**: `url` comes last because
it reads everything above it, and `strip_prefix` follows `name` for the same
reason.

Between them these properties hold every decision about where an archive comes
from, which is why they are written rather than derived: which host serves the
tarball, how a tag spells a version, what the archive unpacks into.

A placeholder a source reads without declaring first is one the version has to
supply. Walking the properties of the block above leaves nothing unbound, so
`0.8.2` needs nothing but its own string. Other entries owe more:

| Entry | Left unbound by its sources | What its versions carry |
| --- | --- | --- |
| pgvector | nothing | `sha256` |
| hll | `upstream_version` | `upstream_version`, `sha256` |
| postgres | `tag` | `tag`, `sha256` |
| age | `tag`, `tag_dir` | `tag`, `tag_dir`, `sha256` |
| pgjwt | `commit` | `commit`, `sha256` |

`sha256` is what monobot computes; the rest is what a pin declares or a
discovered tag is rewritten into.

#### `versions`

`pin` names the versions outright, which is what the catalog does: it is a set
of curated pins rather than a feed. A list where nothing is owed and a map where
something is:

```json
"versions": { "pin": ["0.8.2"] }
"versions": {
  "pin": { "18.1": {"tag": "REL_18_1"}, "18.0": {"tag": "REL_18_0"} }
}
```

They are catalogued in the order they are pinned, and that is the order
`repo.json` presents them in.

`discover` reads versions off the repository's tags instead, and an entry
carrying it is one that follows its upstream. Absent, no tag listing happens at
all:

```json
"versions": {
  "discover": {
    "replace": [["^REL_(\\d+)_(\\d+)$", "$1.$2"]],
    "context": { "tag": [["^(.*)$", "$1"]] },
    "satisfy": ">=16",
    "after": "2020-01-01T00:00:00Z",
    "keepNewest": true
  }
}
```

- `replace` -- Ordered `[regex, replacement]` pairs turning a tag into a
  version. The first regex to match the whole tag is the one applied, so the
  more specific rules go first. A tag no rule matches is read as it stands.
- `context` -- Per key, the same shape, filling what the sources leave unbound:
  `tag`, `upstream_version`, `tag_dir` and the like, each derived from the tag.
- `satisfy` -- A [node-semver](https://github.com/npm/node-semver#ranges) range
  every kept version has to satisfy, such as `>=1.0.0 <2.0.0` or `^1 || ^3`.
  There is no negation, so what to leave out is written as what to keep around
  it: `<1.0.0 || >1.9.9`. Unlike in node, pre-releases take part, because
  `1.4.0-2` here is a packaging revision of a release rather than a candidate
  for one.
- `after` -- A datetime. Drops versions whose archive was last modified before
  it. Read from the archive, so it narrows what is catalogued and not what is
  downloaded.
- `keepNewest` -- Keeps the newest version regardless of `after`, so an entry
  whose last release predates the cutoff still reaches the catalog.

The two compose: a pinned version is catalogued whether or not the tags still
name it, which is what keeps a pin from being undone by a repository that
retags.

#### The `replace` rule each catalog entry would need

No entry in `build/catalog` carries a `discover` block: every one of them is
pinned, because the catalog is a set of curated pins rather than a feed. What
follows is the rule each would need when it opts in, derived from the tag its
pinned version was actually cut from.

Of the 53, 11 need no rule at all because the tag is the version already
(`hypopg`, `pg_qualstats`, `pg_stat_monitor`, `pg_track_settings`, `pgaudit`,
`rum`, `timescaledb`, `timescaledb_toolkit`, `vacuum_utils`, `vchord`,
`vectorscale`), and 25 need only `[["^v(.*)$", "$1"]]`. These 14 need their own:

| Entry | Tag | Version | `replace` |
| --- | --- | --- | --- |
| `postgres` | `REL_18_1` | `18.1` | `^REL_(\d+)_(\d+)$` to `$1.$2` |
| `ivorysql` | `IvorySQL_5.0` | `5.0` | `^IvorySQL_(.*)$` to `$1` |
| `babelfish` | `BABEL_4_0_0__PG_16_1` | `4.0` | `^BABEL_(\d+)_(\d+)_\d+__PG_\d+_\d+$` to `$1.$2` |
| `openhalo` | `v1.0-beta1` | `1beta1` | `^v(\d+)\.\d+-beta(\d+)$` to `$1beta$2` |
| `age` | `PG18/v1.8.0-rc0` | `1.8.0` | `^PG\d+/v(\d+\.\d+\.\d+)-rc\d+$` to `$1` |
| `decoderbufs` | `v3.6.0.Final` | `3.6.0` | `^v(\d+\.\d+\.\d+)\.Final$` to `$1` |
| `hll` | `v2.21` | `2.21.0` | `^v(\d+)\.(\d+)$` to `$1.$2.0` |
| `pg_repack` | `ver_1.5.3` | `1.5.3` | `^ver_(.*)$` to `$1` |
| `pg_stat_kcache` | `REL2_3_2` | `2.3.2` | `^REL(\d+)_(\d+)_(\d+)$` to `$1.$2.$3` |
| `pg_store_plans` | `1.10` | `1.10.0` | `^(\d+)\.(\d+)$` to `$1.$2.0` |
| `pgagent` | `pgagent-4.2.3` | `4.2.3` | `^pgagent-(.*)$` to `$1` |
| `safeupdate` | `1.7` | `1.7.0` | `^(\d+)\.(\d+)$` to `$1.$2.0` |
| `set_user` | `REL4_2_0` | `4.2.0` | `^REL(\d+)_(\d+)_(\d+)$` to `$1.$2.$3` |
| `wal2json` | `wal2json_2_6` | `2.6.0` | `^wal2json_(\d+)_(\d+)$` to `$1.$2.0` |

`pg_auditor` and `pgjwt` pin a commit rather than a tag, so there is no rule to
write. `postgis` downloads from `download.osgeo.org`, which has no tags at all;
its `url` names the GitHub repository so a listing is possible, but the sources
have nothing to derive from.

The `context` rules follow the same shape. `tag` is the tag verbatim, `tag_dir`
is `^(.*)/(.*)$` to `$1-$2` for age, `dirname` is `^v(.*)$` to `$1` for
openhalo, and `upstream_version` strips whatever prefix the tag carries.

The version key is the string as written, never rewritten. It is substituted
literally into `strip_prefix` and `url`, so normalizing `1.4` to `1.4.0` would
name `sslutils-1.4.0` and get a 404. Where a key parses as a semantic version it
is compared as one; where it does not, `1beta1` still orders against `2.0.0`.

### Output: `repo.json`

Written beside the `monobot.json` it was generated from, so an entry is one
directory holding both:

```json
{
  "version": 1,
  "sources": {
    "gh": {
      "tag": "v{version}",
      "gh_org": "pgvector",
      "name": "pgvector",
      "filename": "{tag}",
      "strip_prefix": "{name}-{version}",
      "url": "https://github.com/{gh_org}/{name}/archive/refs/tags/{filename}.tar.gz"
    }
  },
  "versions": {
    "0.8.2": {
      "sha256": "3c8adc8c2d..."
    }
  },
  "metadata": {
    "compatible_with": { "postgres": ">=13" }
  }
}
```

`sources` and `metadata` are what `monobot.json` carried. `versions` is the
pins and whatever the tags turned up, each with what its sources owe it and the
digest of the archive that names.

A version already in the catalog keeps the digest recorded for it. The same URL
answering with different bytes is the artifact changing underneath a pin, so
both digests are named and the entry fails rather than the new one being
written.

The layout is fixed rather than incidental, so two runs over the same inputs
produce the same bytes: two-space indent, LF, a trailing newline, objects always
broken over lines, and an array of scalars kept on one line while that line ends
at or before column 80.

### What the archives carried

The control file and the PGXN `META.json` go beside the entry, one directory per
version, parsed:

```text
catalogDir/extensions/pgvector/metadata/0.8.2/control.json
catalogDir/extensions/pgvector/metadata/0.8.2/META.json
```

`control.json` is the control file as the directives it declares, with the three
booleans Postgres defaults emitted whether or not the file names them, and any
directive monobot does not model carried through beside the ones it does.
`META.json` is verbatim. The cache keeps both as the archive spelled them.

## Running

From this directory:

```sh
catalogDir=/path/to/monogres/build/catalog \
cacheDir=/tmp/monobot \
  bazel run //:monobot
```

Regenerating the catalog and checking it against what is committed:

```sh
# once, cold: populates the cache
catalogDir=... cacheDir=... mode=fetch bazel run //:monobot

# rewrite it in place, then look at what moved
catalogDir=... cacheDir=... bazel run //:monobot
git diff build/catalog

# the same thing as a gate, writing nothing
catalogDir=... cacheDir=... mode=check bazel run //:monobot
```

## Development

See [docs/development.md](docs/development.md) for the build, dev mode,
packaging, and the format and lint gate.
