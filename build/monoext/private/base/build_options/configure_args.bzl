"""
Translate the Meson option vocabulary used by `pg.bzl::OPTION_SETS` to autoconf
`./configure` flags for the make-based build path.

The flavor framework computes options as a dict of Meson option names + values
(e.g. `{"ssl": "openssl", "uuid": "ossp", "nls": "enabled", ...}`). PG flavors
that use Meson (`postgres` on PG >= 16, `ivorysql`) consume that dict directly
via `rules_foreign_cc.meson`. PG flavors / versions that use autoconf+make
(`postgres` on PG < 16) consume `./configure --with-X` / `--enable-X` flags
instead.

The two vocabularies do not map 1:1:

- Some Meson option *names* differ from the corresponding autoconf names
  (e.g. `plpython` → `--with-python`, `libedit_preferred` is folded into
  `--with-readline=libedit`).
- Some Meson options have no autoconf counterpart (`auto_features`,
  `injection_points`, `prefix_distro`, `spinlocks`, `atomics`, `rpath`).
  Autoconf hardcodes spinlocks/atomics per platform and has no `prefix_distro`
  notion (it splits embedded path via `--prefix` from staging via `make install
  DESTDIR=...`); `auto_features`/`injection_points` are Meson-only build-system
  features.
- Some autoconf flags have no Meson equivalent. Not surfaced here; flavors
  that need them can pass extra `./configure` args separately.

References:
- https://www.postgresql.org/docs/16/install-make.html
- https://www.postgresql.org/docs/16/install-meson.html

The mapping table (`_BOOL_OPTIONS`, `_STRING_OPTIONS`, `_DROPPED_OPTIONS`)
documents every option in the current `pg.bzl` OPTION_SETS plus a few neighbors
that flavors may add. Unmapped options fall through to the "drop with warning"
path so newly-added Meson options surface visibly.
"""

# Meson "feature" / boolean options that map to `--enable-X` / `--disable-X`
# autoconf flags. Values are the autoconf flag base (no leading `--`).
_BOOL_OPTIONS_ENABLE = {
    "cassert": "cassert",
    "debug": "debug",
    "dtrace": "dtrace",
    # Meson option name → autoconf base name (used as --enable-X / --disable-X)
    "nls": "nls",
    "tap_tests": "tap-tests",
}

# Meson "feature" / boolean options that map to `--with-X` / `--without-X`
# autoconf flags.
_BOOL_OPTIONS_WITH = {
    "bonjour": "bonjour",
    "bsd_auth": "bsd-auth",
    "gssapi": "gssapi",
    "icu": "icu",
    "ldap": "ldap",
    "libxml": "libxml",
    "llvm": "llvm",
    "lz4": "lz4",
    "pam": "pam",
    "readline": "readline",
    "selinux": "selinux",
    "systemd": "systemd",
    "zlib": "zlib",
    "zstd": "zstd",
}

# Meson string options where the value drives an autoconf `--with-X=VALUE` flag.
_STRING_OPTIONS_WITH = {
    "extra_version": "extra-version",
    "system_tzdata": "system-tzdata",
    "uuid": "uuid",
}

# Meson string options that translate to a renamed autoconf flag when the value
# matches a specific signal value. Dict: meson_name → (signal, autoconf flag
# with no value).
_BOOL_OPTIONS_WITH_FROM_STRING = {
    # `plperl`/`plpython`/`pltcl` (Meson) → `--with-perl`/`--with-python`/
    # `--with-tcl` (autoconf). The Meson option names encode the PL language;
    # autoconf names each after the interpreter dependency it links against.
    "plperl": ("true", "perl"),
    "plpython": ("true", "python"),
    "pltcl": ("true", "tcl"),
    # `ssl=openssl` (Meson) → `--with-openssl` (autoconf). Other ssl backends
    # (e.g. `gnutls`) have no autoconf equivalent in PG 16/17.
    "ssl": ("openssl", "openssl"),
}

# Meson options the configure_args translator does NOT emit as `./configure`
# flags. Each entry's description leads with a tag:
#
# - `[OOB]` (out-of-band): the option DOES affect the build, but via a different
# facet of `pg_build_make` (e.g. `make_target_for` selects the   make target,
# not a configure flag). The description names where the   option is actually
# honored. Listed here so the dispatch loop in   `to_configure_args` recognizes
# the name and doesn't fire the "unknown   option" warning.
#
# - `[DROP]`: truly dropped. Either a Meson-only build-system metafeature
# (`auto_features`, `b_coverage`, `injection_points`) or a value that   autoconf
# hardcodes per platform (`atomics`, `spinlocks`) or has no   counterpart for
# (`rpath`).
#
# Options that ARE emitted as flags but via a special-case path (e.g. `readline`
# + `libedit_preferred` folded by `_readline_args`, `prefix_distro` translated
# to `--prefix` by `_emit_prefix`) never reach this dict — they're added to
# `seen[]` early in `to_configure_args`. `prefix_distro` is listed here anyway
# for documentation symmetry.
_DROPPED_OPTIONS = {
    "atomics": (
        "[DROP] autoconf hardcodes the atomics implementation per " +
        "platform (pg_config.h's `HAVE_ATOMICS_*` macros); not " +
        "user-tunable."
    ),
    "auto_features": (
        "[DROP] Meson-only metafeature controlling the default for each " +
        "`feature()` option (`enabled` / `disabled` / `auto`). PG's " +
        "autoconf has no equivalent; each `--with-X` is explicitly " +
        "toggled by this translator's enumeration above."
    ),
    "b_coverage": (
        "[DROP] Meson-only build option enabling compiler `-fprofile-arcs` " +
        "/ `-ftest-coverage` instrumentation. PG's autoconf has no " +
        "`--enable-coverage` flag."
    ),
    "contrib": (
        "[OOB] make-target level (`world-bin` when contrib=true vs `all` " +
        "when contrib=false); see `make_target_for` / " +
        "`make_install_target_for`. PG's autoconf has no `--with-contrib` " +
        "flag."
    ),
    "docs": (
        "[OOB] make-target level: `world-bin` (PG 14+'s 'everything except " +
        "docs') is used when contrib=true; `all` is used when " +
        "contrib=false. Neither enters `doc/`. PG's autoconf has no " +
        "`--disable-documentation`."
    ),
    "docs_pdf": (
        "[OOB] subset of `docs`; PDF docs ship as part of the docs target " +
        "which the make-target selection skips. Same handling."
    ),
    "injection_points": (
        "[DROP] Meson-only developer feature added in PG 17 (testing-hook " +
        "injection at chosen control-flow points). PG's autoconf has no " +
        "equivalent."
    ),
    "libdir": (
        "[OOB] Meson's `libdir` is a path-layout knob; autoconf has " +
        "`--libdir=` but with different default-derivation semantics. Not " +
        "auto-translated; if a caller needs a custom libdir on the make " +
        "path they can pass `--libdir=` explicitly via build_options " +
        "metadata (no caller does today)."
    ),
    "prefix_distro": (
        "[OOB] translated to `--prefix=<value>` by `_emit_prefix` (which " +
        "marks `seen[prefix_distro] = True` so this code path is never " +
        "actually reached). Listed here for documentation symmetry."
    ),
    "rpath": (
        "[DROP] Meson-only build-system control over `rpath` baking. PG's " +
        "autoconf relies on toolchain defaults + caller-provided `LDFLAGS`."
    ),
    "spinlocks": (
        "[DROP] autoconf hardcodes the spinlock implementation per " +
        "platform (selected at configure time from a platform allowlist); " +
        "not user-tunable."
    ),
}

def _is_truthy(value):
    """Return True if `value` is one of the Meson-shaped truthy spellings.

    Meson values come through as strings (`"enabled"` / `"disabled"`, `"true"` /
    `"false"`) or sometimes plain booleans. Treat any of `"enabled"` / `"true"`
    / `True` as truthy.
    """
    if value == True:
        return True
    if type(value) == "string":
        v = value.lower()
        return v in ("enabled", "true")
    return False

def _is_falsy(value):
    if value == False:
        return True
    if type(value) == "string":
        v = value.lower()
        return v in ("disabled", "false")
    return False

def _emit_bool_with(autoconf_name, value):
    """`--with-X` / `--without-X` for boolean Meson options."""
    if _is_truthy(value):
        return ["--with-{}".format(autoconf_name)]
    if _is_falsy(value):
        return ["--without-{}".format(autoconf_name)]
    return []

def _emit_bool_enable(autoconf_name, value):
    """`--enable-X` / `--disable-X` for boolean Meson options."""
    if _is_truthy(value):
        return ["--enable-{}".format(autoconf_name)]
    if _is_falsy(value):
        return ["--disable-{}".format(autoconf_name)]
    return []

def _emit_prefix(value):
    """`prefix_distro=<path>` → `--prefix=<path>`.

    Meson's `prefix_distro` decouples "path embedded in pg_config.h" (used at
    runtime to find binaries/share/lib) from "install location" (where files
    actually land). Autoconf has the same separation natively:
    `--prefix=<path>` sets the embedded path, and `make install
    DESTDIR=<staging>` is what controls install staging — completely
    independent. The build wrapper sets `DESTDIR` explicitly when invoking `make
    install`.
    """
    if not value:
        return []
    return ["--prefix={}".format(value)]

def _readline_args(options):
    """Translate `readline` + `libedit_preferred` to autoconf flags.

    Meson splits them into two independent boolean options (`-Dreadline=true`,
    `-Dlibedit_preferred=true`). PG's autoconf has only `--with-readline`
    (boolean): when enabled, GNU readline is used if found, with libedit as a
    fallback. There is no way at the `./configure` level to *prefer* libedit
    when readline is also available — that's a Meson-specific feature.

    `libedit_preferred` is therefore ignored for autoconf builds; only
    `readline=true/false` matters.
    """
    readline = options.get("readline")
    if readline == None:
        return []
    if _is_falsy(readline):
        return ["--without-readline"]
    if _is_truthy(readline):
        return ["--with-readline"]
    return []

def to_configure_args(options, debug = False):
    """Translate a Meson-shaped options dict into autoconf `./configure` args.

    Crucially, this enumerates the *full* known boolean option set and emits
    `--without-X` (or `--disable-X`) for each option that's absent from the
    input dict. This is the autoconf-side analog of Meson's `auto_features =
    "disabled"` (the value the flavor framework passes for every set except
    `full`): without this enumeration, autoconf would fall back to its built-in
    defaults (ICU, readline, etc. default to `yes` in PG 16/17), pulling in
    dependencies the option set explicitly excludes. `barebones` builds in
    particular would otherwise try to link ICU and fail.

    Args:
        options (dict): Meson option name → value, as produced by
            `flavors.FLAVORS[<flavor>].build_options(...)`.
        debug (bool): If `True`, prints a debug line for any unmapped option
            that gets dropped.

    Returns:
        list: Sorted list of autoconf flag strings (e.g. `--with-openssl`,
        `--prefix=/postgres/15.0`, `--enable-nls`, `--without-icu`). Order is
        stable per option name so the result is reproducible.
    """
    args = []
    seen = {}

    # `readline` + `libedit_preferred` are conjoined; handle them up-front so
    # the per-key loop below can skip both.
    readline_args = _readline_args(options)
    args.extend(readline_args)
    seen["readline"] = True
    seen["libedit_preferred"] = True

    # `prefix_distro` → `--prefix`. Pop it so the dropped-options pass below
    # does not also log it.
    prefix_args = _emit_prefix(options.get("prefix_distro"))
    args.extend(prefix_args)
    seen["prefix_distro"] = True

    # Enumerate the full known boolean option set: emit `--with-X` /
    # `--without-X` (or `--enable-X` / `--disable-X`) for every known option,
    # defaulting to the disabled side when absent. This anchors the configure
    # step against autoconf's built-in defaults. Skip options already consumed
    # by special-case handling above (e.g. readline, folded with
    # libedit_preferred).
    for name, autoconf_name in sorted(_BOOL_OPTIONS_WITH.items()):
        if name in seen:
            continue
        seen[name] = True
        value = options.get(name)
        if value == None or _is_falsy(value):
            args.append("--without-{}".format(autoconf_name))
        elif _is_truthy(value):
            args.append("--with-{}".format(autoconf_name))

    for name, autoconf_name in sorted(_BOOL_OPTIONS_ENABLE.items()):
        if name in seen:
            continue
        seen[name] = True
        value = options.get(name)
        if value == None or _is_falsy(value):
            args.append("--disable-{}".format(autoconf_name))
        elif _is_truthy(value):
            args.append("--enable-{}".format(autoconf_name))

    # Signal-string options: emit `--with-X` only when the value matches the
    # signal; otherwise emit `--without-X` so the autoconf default doesn't
    # default-enable.
    for name, (signal, flag) in sorted(_BOOL_OPTIONS_WITH_FROM_STRING.items()):
        if name in seen:
            continue
        seen[name] = True
        value = options.get(name)
        if value == signal or (signal == "true" and _is_truthy(value)):
            args.append("--with-{}".format(flag))
        else:
            args.append("--without-{}".format(flag))

    # Process the remaining options (string-valued, contrib, dropped, unknown).
    for name, value in sorted(options.items()):
        if name in seen:
            continue

        if name in _STRING_OPTIONS_WITH:
            if value not in (None, ""):
                args.append(
                    "--with-{}={}".format(_STRING_OPTIONS_WITH[name], value),
                )
        elif name in _DROPPED_OPTIONS:
            # `contrib`, `libdir` are handled out of band (see
            # `_DROPPED_OPTIONS` comment); the rest are Meson-only or
            # autoconf-hardcoded. Debug-log the drop so the user can audit which
            # options were skipped.
            if debug:
                # buildifier: disable=print
                print(
                    "configure_args: dropping %r (%s)" % (name, _DROPPED_OPTIONS[name]),
                )
        elif debug:
            # buildifier: disable=print
            print(
                "configure_args: unknown Meson option %r=%r — dropped" % (name, value),
            )

    return args

def make_target_for(options):
    """Return the (sub_dir, targets) pairs for the build phase.

    PG provides three build-everything-style targets:

    - `all`: PG core (src + config). No contrib, no docs. The default.
    - `world`: core + contrib + docs. Used by distros that ship pre-built docs.
    - `world-bin`: core + contrib only — *no docs* (PG 14+, see PG commit
      `15a8f8c41a` "Add option to build all binary distribution components").

    `world-bin` is the canonical PG target for the make-build path here: the
    full set wants core + contrib without paying the docs cost (xsltproc +
    DocBook stylesheets are not in the deps_buildtime sysroot, and the pre-built
    artifact does not need docs to be functionally equivalent to a Meson build
    configured with `docs=disabled`).

    The `contrib` option drives the choice:
    - `contrib=true` -> `world-bin` (core + contrib, no docs)
    - else          -> `all`        (core only)

    Args:
        options (dict): Meson option name -> value (the same dict consumed by
            `to_configure_args`).

    Returns:
        list: Single entry of shape `[(subdir, [target,...])]`. `subdir == ""`
        means run make in the source root.
    """
    target = "world-bin" if _is_truthy(options.get("contrib")) else "all"
    return [("", [target])]

def make_install_target_for(options):
    """Return the (sub_dir, targets) pairs for the install phase.

    Mirrors `make_target_for`: `install-world-bin` (core + contrib, no docs)
    when `contrib=true`, plain `install` (core only) otherwise.

    Args:
        options (dict): Meson option name -> value (the same dict consumed by
            `to_configure_args`).

    Returns:
        list: Same shape as `make_target_for` but with install targets.
    """
    target = "install-world-bin" if _is_truthy(
        options.get("contrib"),
    ) else "install"
    return [("", [target])]

def extra_libs_for(options):
    """Return extra `-l<lib>` flags to append to `LIBS` in `Makefile.global`.

    Some build options need extra link libraries that PG's autoconf does not add
    itself. The caller (pg_build_make) appends these to the `LIBS` line in
    `src/Makefile.global` *after* `./configure` runs — passing them via the
    configure env (`LIBS=...`) instead would force every configure probe binary
    (including the very first "does the C compiler work" probe) to link against
    the same chain, which on non-trivial transitive deps (e.g. avahi-client ->
    libdbus-1) tends to break the probes.

    Currently:

    - `bonjour=enabled` -> `-ldns_sd`. PG's autoconf path *only* probes for
      `dns_sd.h` when `--with-bonjour` is in effect — it deliberately does *not*
      run `AC_SEARCH_LIBS(DNSServiceRegister, dns_sd)` (see the comment block in
      `configure.ac` near the bonjour stanza: "If you want to use Apple's own
      Bonjour code on another platform, just add -ldns_sd to LIBS manually.").
      On non-Darwin, the postmaster link therefore needs `-ldns_sd` injected
      into `LIBS` by the caller. Meson handles this automatically via
      `cc.find_library('dns_sd', has_headers: ['dns_sd.h'])`, which emits both
      the include probe AND the link flag; the autoconf path requires us to
      inject the link flag ourselves.

    Args:
        options (dict): Meson option name -> value (the same dict consumed by
            `to_configure_args`).

    Returns:
        list: `-l<lib>` flags to append to `LIBS` in `Makefile.global` (or empty
        list if no extra libs are needed for the active option set).
    """
    libs = []
    if _is_truthy(options.get("bonjour")):
        libs.append("-ldns_sd")
    return libs

testing = struct(
    _is_truthy = _is_truthy,
    _is_falsy = _is_falsy,
    _emit_bool_with = _emit_bool_with,
    _emit_bool_enable = _emit_bool_enable,
    _emit_prefix = _emit_prefix,
    _readline_args = _readline_args,
)
