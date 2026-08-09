# Monobot

Monobot automatically discovers, fetches, and catalogs Postgres extensions
from Git repositories. It scans for configuration files (`monobot.json`),
downloads source archives for every tagged version, computes SHA256
checksums, extracts metadata from the archives, and produces standardized
JSON catalogs (`repo.json`) used by
[monogres](https://github.com/monogres/monogres) for reproducible builds.

## How It Works

Monobot runs as a pipeline with three phases:

1. **Scan** -- Recursively discovers `monobot.json` files under the config
   directory.
2. **Fetch** -- For each extension, fetches Git tags, downloads source
   archives (by commit, not tag name, for stability), computes SHA256
   checksums, and extracts metadata from the archive contents.
3. **Write** -- Produces a `repo.json` catalog in the monogres build tree.
   Existing versions are preserved (incremental updates).

All archive downloads run concurrently via Vert.x async futures.

## Configuration

### Runtime Properties

Monobot reads four properties, three of them required, provided as
environment variables or command line properties (`-D...`). The one that
is optional has a default in `src/main/resources/application.properties`:

| Property | Required | Description |
| --- | --- | --- |
| `configDir` | yes | Root directory containing the `monobot.json` files (typically `config/` subfolder within the project) |
| `workdir` | yes | Working directory for downloaded archives |
| `monogresRepo` | yes | Path to the monogres repository (output goes to `{monogresRepo}/build/`), typically a monogres git checkout |
| `downloadTimeout` | no | How long one download may take, as an ISO8601 duration. Defaults to `PT5M`. |

### Input: `monobot.json`

Each extension has a `monobot.json` file under
`configDir/extensions/{extensionName}`. Minimal example:

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

- `name` (required) -- Extension name.
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

Written to `{monogresRepo}/build/{relpath}/repo.json`, where `{relpath}`
mirrors the directory structure under `configDir`. Example:

```text
configDir/extensions/envvar/monobot.json  -->  monogresRepo/build/extensions/envvar/repo.json
```

Each `repo.json` contains (among potentially other fields; for example, if
the extension follows PGXN's convention, then all information under
`META.json` will also be imported by monobot):

```json
{
  "sources": {
    "github.com": {
      "url": "https://api.github.com/repos/theory/pg-envvar/tarball/{commit}"
    }
  },
  "versions": {
    "1.0.1": {
      "tag": "v1.0.1",
      "commit": "de3737097e3df093031c4e88300ebcd345582e36",
      "short_commit": "de37370",
      "sha256": "1b6fbc4e095a934faf404e603bc40828eb3e0512...",
      "strip_prefix": "theory-pg-envvar-de37370"
    }
  },
  "metadata": {
    ".control": {
      "1.0.1": {
        "default_version": "1.0.0",
        "comment": "Get the value of a server environment variable",
        "superuser": true,
        "relocatable": true
      }
    }
  }
}
```

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
configDir=/path/to/config \
workdir=/tmp/monobot \
monogresRepo=/path/to/monogres \
  bazel run //:monobot
```

## Development

See [docs/development.md](docs/development.md) for the build, dev mode,
packaging, and the format and lint gate.
