"""
Public re-export of the apt `hub_repo` repository rule.

The repository rule itself lives under `//apt/private:repo.bzl` so it stays
behind the module's private / public boundary; this thin wrapper exposes it as
the canonical entry point for callers that need to materialize apt sysroot hub
repos programmatically (e.g. a module extension producing one hub per resolved
package group rather than per `sysroots.apt(...)` tag).

`sysroots.apt(...)` tag users do NOT need to load this. The module extension
calls into `hub_repo` itself.
"""

# buildifier: disable=bzl-visibility
load("//apt/private:repo.bzl", _hub_repo = "hub_repo")

hub_repo = _hub_repo
