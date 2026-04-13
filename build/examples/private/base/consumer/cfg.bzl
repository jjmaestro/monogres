"""
Downstream-style pg consumer config.

With artifact + source labels baked into `@pg//:all.bzl` `CFG`, the consumer
shape IS the hub shape: `CONSUMER_CFG = PG_CFG`. The load-time coherence check
below fails loading if a shape regression slips into the hub (empty
`deps.{buildtime,runtime}.{sysroot,packages}` for a PG target, or missing
`artifact` / `source` labels), keeping "loading the config IS the contract test"
property from the previous three-phase pattern.
"""

load("@pg//:all.bzl", "KINDS", PG_CFG = "CFG")

def _check_kind(target, kind):
    kd = getattr(target.deps, kind)

    if not kd.sysroot:
        msg = "pg target %s/%s: expected non-empty target.deps.%s.sysroot"
        fail(msg % (target.version, target.option_set, kind))

    if not kd.packages:
        msg = "pg target %s/%s: target.deps.%s.sysroot is set but packages is empty"
        fail(msg % (target.version, target.option_set, kind))

def _check_target(target):
    if not target.artifact:
        fail(
            "pg target %s/%s: missing artifact label" % (target.version, target.option_set),
        )

    if not target.source.dir or not target.source.files:
        fail(
            "pg target %s/%s: missing source labels" % (target.version, target.option_set),
        )

    for kind in KINDS:
        _check_kind(target, kind)

def _check_cfg(cfg):
    for target in cfg.targets:
        _check_target(target)
    return cfg

CONSUMER_CFG = _check_cfg(PG_CFG)
