# Monobot

Monobot automatically discovers, fetches, and catalogs Postgres extensions
from Git repositories. It scans for configuration files (`monobot.json`),
downloads source archives for every tagged version, computes SHA256
checksums, extracts metadata from the archives, and produces standardized
JSON catalogs (`repo.json`) used by
[monogres](https://github.com/monogres/monogres) for reproducible builds.

## How It Works

Monobot runs as a pipeline with two phases:

1. **Scan** -- Recursively discovers `monobot.json` files under the config
   directory.
2. **Fetch** -- For each extension, fetches Git tags, downloads source
   archives (by commit, not tag name, for stability), computes SHA256
   checksums, extracts metadata from the archive contents, and writes a
   `repo.json` catalog into the monogres build tree. Existing versions are
   preserved (incremental updates).

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

## Configuration

### Runtime Properties

Monobot reads nine properties, three of them required, provided as
environment variables or command line properties (`-D...`). The six that
are optional have defaults in `src/main/resources/application.properties`:

| Property | Required | Description |
| --- | --- | --- |
| `catalogDir` | yes | Root of the catalog. Every `monobot.json` under it is an entry, and its `repo.json` is written beside it |
| `cacheDir` | yes | Root of the archive cache, one directory per entry per version |
| `mode` | no | What the run does: `generate` writes the catalog, `check` compares against it and writes nothing, `fetch` only fills the cache. Defaults to `generate`. |
| `maxConcurrentDownloads` | no | How many archive downloads may be in flight at once, across the whole scan rather than per extension. Defaults to `4`. |
| `downloadTimeout` | no | How long one download may take, as an ISO8601 duration. Defaults to `PT5M`. |
| `tagListTimeout` | no | How long one tag listing may take, as an ISO8601 duration, applied as both the connect and the read timeout. Defaults to `PT30S`. Counted in whole seconds, and anything under a second is raised to one. |
| `runTimeout` | no | How long the whole scan may take, as an ISO8601 duration. Defaults to `PT1H`. Reaching it exits non-zero. |
| `verifyCache` | no | How much of a cached archive is checked before a run answers from it: `size` compares its length against the length recorded for it, `digest` compares its digest, `none` takes the record at its word. Defaults to `size`. |
| `refreshCache` | no | Whether to ask the source about archives the cache can already answer for. The request carries the recorded validators, so an unchanged archive costs a 304. Defaults to `false`. |

### Exit status and the run summary

Every run prints one summary line on its way out, whatever the outcome, giving
how many extensions were scanned, how many of them failed, how many versions
were added, how many were skipped and why, and how many `repo.json` files were
written:

```text
Scanned 3 extensions, 1 of them failed: 5 versions added, 41 skipped
  (38 already catalogued, 2 outside satisfy, 1 refused downloads), 2 repo.json written
```

A failed extension does not stop the run, so the exit status is what says one
happened:

| Status | Meaning |
| --- | --- |
| `0` | Every extension the scan found completed. |
| `1` | Some extensions completed and some failed. |
| `2` | No extension completed: either every one of them failed, or the run did not finish within `runTimeout`. |

An extension fails when its `monobot.json` cannot be read, when its stored
`repo.json` cannot be read, when its tags cannot be listed, or when any of its
archives could not be downloaded. Everything else is a skip, and skips are
reported in the summary rather than in the exit status.

### Input: `monobot.json`

Each extension has a `monobot.json` file under
`catalogDir/extensions/{extensionName}`. Minimal example:

```json
{
  "name": "envvar",
  "url": "https://github.com/theory/pg-envvar"
}
```

With optional metadata:

```json
{
  "name": "noset",
  "url": "https://gitlab.com/ongresinc/extensions/noset",
  "metadata": {
    "compatible_with": {
      "0.3.0": ">=14",
      "0.2.0": ">=12, <14"
    }
  }
}
```

With rules for tags a version cannot be read from as they stand:

```json
{
  "name": "sslutils",
  "url": "https://github.com/EnterpriseDB/sslutils",
  "versions": {
    "replace": [
      ["v([0-9]+)\\.([0-9]+)-([0-9]+)", "$1.$2.0-$3"]
    ]
  }
}
```

Fields:

- `name` (required) -- Extension name, and two things follow from it. It is the
  stem of the control file looked for inside each archive (`{name}.control`),
  and the prefix every log line about the extension carries. The stem is the one
  that bites: it is the extension's own name and not the repository's, and the
  two diverge routinely, so `pgvector` needs `"name": "vector"`. A name that
  matches no control file leaves the version with no control document, with one
  WARN line saying so.
- `url` (required) -- Git repository URL (GitHub or GitLab). A trailing slash
  and a `.git` suffix are both accepted and both ignored.
- `versions` (optional) -- How tags become versions, and which are kept.
  - `replace` -- Ordered `[regex, replacement]` pairs. The first regex to match
    the whole tag name is the one applied, so the more specific replacement
    rules should go first. A tag no rule matches is read as it stands.
  - `satisfy` -- A [node-semver](https://github.com/npm/node-semver#ranges)
    range every kept version has to satisfy, such as `>=1.0.0 <2.0.0` or
    `^1 || ^3`. There is no negation, so what to leave out is written as what
    to keep around it: `<1.0.0 || >1.9.9`. Unlike in node, pre-releases take
    part, because `1.4.0-2` here is a packaging revision of a release rather
    than a candidate for one.
  - `after` -- A datetime, such as `2020-01-01T00:00:00Z`. Filters versions
    whose archive was last modified before the datetime. This is read from the
    archive, so it narrows what is in the catalog, and not what is downloaded.
  - `keepNewest` -- Keeps the newest version regardless of `after`, so an
    extension whose last release predates the cutoff still reaches the catalog.
- `metadata` (optional) -- Additional metadata to include (verbatim) in the
  output, keyed by category and version.
- `disabled` (optional) -- When `true`, the extension is left alone: no tags
  are listed, no archives downloaded, and the `repo.json` a previous run wrote
  stays as it is.

A version is a semantic version, with two liberties: a leading `v` is ignored,
and a missing patch component is filled in, so `v1.2` is version `1.2.0`. A tag
that names no version is skipped, and monobot warns when none of an extension's
tags names one. Tags are ordered by semantic version precedence, and
`repo.json` presents them newest first.

### Output: `repo.json`

Written beside the `monobot.json` it was generated from, so an entry is one
directory holding both:

```text
catalogDir/extensions/envvar/monobot.json  -->  catalogDir/extensions/envvar/repo.json
```

Each `repo.json` contains (among potentially other fields; for example, if
the extension follows PGXN's convention, then all information under
`META.json` will also be imported by monobot):

```json
{
  "sources": {
    "github.com": {
      "url": "https://api.github.com/repos/theory/pg-envvar/tarball/{commit}",
      "type": "tar.gz"
    }
  },
  "versions": {
    "1.0.1": {
      "tag": "v1.0.1",
      "sha256": "1b6fbc4e095a934faf404e603bc40828eb3e0512...",
      "strip_prefix": "theory-pg-envvar-de37370",
      "commit": "de3737097e3df093031c4e88300ebcd345582e36",
      "short_commit": "de37370"
    }
  },
  "metadata": {
    ".control": {
      "1.0.1": {
        "default_version": "1.0.0",
        "comment": "Get the value of a server environment variable",
        "superuser": true,
        "trusted": false,
        "relocatable": true
      }
    }
  },
  "version": 1
}
```

`version`, `sources.*.type` and the three `.control` booleans are emitted
unconditionally, the booleans because a control file that declares none of them
still has the defaults Postgres would apply.

Any control directive monobot does not model is carried through beside the
ones it does. Key order is fixed rather than incidental, so two runs over the
same inputs produce the same bytes.

## Supported Forges

| Forge | Archive URL pattern |
| --- | --- |
| GitHub | `https://api.github.com/repos/{org}/{repo}/tarball/{commit}` |
| GitLab | `https://gitlab.com/api/v4/projects/{project}/repository/archive.tar.gz?sha={commit}` |

Archives are always fetched by commit hash (not tag name) for
reproducibility.

## Metadata Extraction

Monobot automatically extracts the following metadata from each version's
source archive:

- **`.control`** -- Postgres extension control file. Parsed into fields like
  `default_version`, `comment`, `superuser`, `trusted`, `relocatable`,
  `requires`, etc.
- **`META.json`** -- [PGXN](https://pgxn.org/) metadata file, included
  verbatim if present.

## Running

From this directory:

```sh
catalogDir=/path/to/monogres/build/catalog \
cacheDir=/tmp/monobot \
  bazel run //:monobot
```

## Development

See [docs/development.md](docs/development.md) for the build, dev mode,
packaging, and the format and lint gate.
