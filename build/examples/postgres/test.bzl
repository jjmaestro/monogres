"""e2e testing"""

load("//:utils.bzl", "list_files")

def build_test(name):
    list_files(
        name = name,
        target = "@monogres//postgres:%s" % name,
    )

def build_all_test(name, cfg):
    for target in cfg.targets:
        build_test(target.name)
        name_introspect = "%s--introspect" % target.name
        build_test(name_introspect)

def build_smoke_test(name, cfg):
    """Exercises build_all_test with just the default target."""
    build_all_test(name, struct(targets = [cfg.default]))
