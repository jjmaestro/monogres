"""e2e testing"""

load("//:utils.bzl", "list_files")

def build_test(package, name):
    target = "%s--tar" % name if package == "contrib" else name
    list_files(
        name = name,
        target = "@monogres//extensions/%s:%s" % (package, target),
    )

def build_all_test(name, cfg):
    for target in cfg.targets:
        build_test(name, target.name)

def build_smoke_test(name, cfg):
    """Exercises build_all_test with just the default target."""
    build_all_test(name, struct(targets = [cfg.default]))
