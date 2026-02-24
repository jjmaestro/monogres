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

Monobot requires three properties, provided as environment variables or
command line properties (`-D...`):

| Property | Description |
| --- | --- |
| `configDir` | Root directory containing the `monobot.json` files (typically `config/` subfolder within the project) |
| `workdir` | Working directory for downloaded archives |
| `monogresRepo` | Path to the monogres repository (output goes to `{monogresRepo}/build/`), typically a monogres git checkout |

### Input: `monobot.json`

Each extension has a `monobot.json` file under
`configDir/extensions/{extensionName}`. Minimal example:

```json
{
  "name": "envvar",
  "url": "https://github.com/theory/pg-envvar/"
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

Fields:

- `name` (required) -- Extension name.
- `url` (required) -- Git repository URL (GitHub or GitLab).
- `metadata` (optional) -- Additional metadata to include (verbatim) in the
  output, keyed by category and version.

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

```sh
configDir=/path/to/config \
workdir=/tmp/monobot \
monogresRepo=/path/to/monogres \
  mvn quarkus:run
```

## Development

See [docs/development.md](docs/development.md) for build instructions, dev
mode, packaging, and native executable details.
