"""
Downstream-style pg consumer config.

With artifact + source labels baked into `@pg//:all.bzl` `CFG`, the consumer
shape IS the hub shape: `CONSUMER_CFG = PG_CFG`. The load-time coherence check
below fails loading if a shape regression slips into the hub (a PG target whose
`deps.{buildtime,runtime,test}` kind has a sysroot but no packages or vice
versa, or missing `artifact` / `source` labels), keeping "loading the config IS
the contract test" property. A kind may be entirely absent (empty sysroot AND no
packages), e.g. a flavor that declares no `deps.test`.
"""

load("@pg//:all.bzl", "KINDS", PG_CFG = "CFG")

def _check_kind(target, kind):
    kd = getattr(target.deps, kind)

    # A populated kind emits its sysroot + package labels together; an absent
    # kind (empty sysroot AND no packages) is allowed, e.g. a target with no
    # `deps.test`. Only a half-populated kind is a shape regression.
    if bool(kd.sysroot) != bool(kd.packages):
        msg = "pg target %s/%s: target.deps.%s sysroot/packages disagree (sysroot=%r, n_pkgs=%d)"
        fail(
            msg % (target.version, target.option_set, kind, kd.sysroot, len(
                kd.packages,
            )),
        )

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
