"""
Schema for the test-suites codegen (base + extensions hubs).

Decodes the introspect `.tests` array into a typed shape ONCE, at the JSON
boundary, so downstream renderers never re-`["..."]`-index a raw dict. Mirrors
`//monoext/private/base:schema.bzl` (which decodes `BaseEntry`/`BaseTarget`):

- `TestEntry`: one decoded `.tests[]` object. Carries only the fields the
  generator reads (`name`, `suite`, `protocol`, `timeout`, `is_parallel`, and
  the two cmd-derived booleans + the `env.INITDB_TEMPLATE` presence bit). The
  sanitized `cmd`/`env`/`depends` placeholders are NOT retained past decode;
  they are classified into booleans here and discarded, so no rendered target
  ever carries a `<BAZEL_CACHE>`-style path.
- `SuiteInfo`: the per-group reduction over a slice of `TestEntry`s sharing a
  `suite[0]`: the shape `suites.bzl` renders one `sh_test` from.

`TestEntry`/`SuiteInfo` are pure Starlark structs built inside the repo rule
(`hub.bzl::_impl` decodes `json.decode(rctx.read(label))`); they never cross a
JSON boundary themselves, so they ship `decode`/`classify` but no `from_dict`.
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")

# Runner "kind": what command the harness reconstructs + dispatches on. Derived
# from the sanitized `.cmd` (`pg_isolation_regress` / `/pg_regress` token) and
# `protocol`, never from a version string. Held as plain constants so callers
# compare against a single source of truth.
KIND_ISOLATION = "isolation"
KIND_REGRESS = "regress"
KIND_TAP = "tap"
KIND_SETUP = "setup"

# Schedule basename per kind. Only `regress`/`isolation` carry a `--schedule
# …_schedule` token; contrib `pg_regress` groups list inline test names instead.
# The harness resolves the real path from the installed/source tree; the
# generator emits only the basename selector.
_SCHEDULE_BY_KIND = {
    KIND_REGRESS: "parallel_schedule",
    KIND_ISOLATION: "isolation_schedule",
}

# `--max-concurrent-tests=20` literal (the "20-conn" fan-out marker). Matched as
# a whole token so a future `--max-concurrent-tests=8` does not false-positive.
_MAX_CONCURRENT_20 = "--max-concurrent-tests=20"

# ---------------------------------------------------------------------------
# Category: the PG source subtree a suite lives in. Drives whether a suite
# renders into the base hub @{name} (core/pl/module, under `<v>/<opt>/tests/`)
# or the extensions hub @{name}_ext (contrib, under `contrib/<name>/<v>/tests`).
# ---------------------------------------------------------------------------

CAT_CORE = "core"
CAT_PL = "pl"
CAT_MODULE = "module"
CAT_CONTRIB = "contrib"

# Source-subtree prefix -> category, longest-prefix first (src/test/modules
# before src/test). Derived from the sanitized `.cmd` first `--srcdir`/
# `--inputdir` token, which meson keeps as `.../gh/<subtree>` (verified across
# PG16/17/18 + IvorySQL: contrib/<n>, src/test/modules/<m>, src/pl/<pl>,
# src/test/regress, src/test/isolation). `src/test/regress` and
# `src/test/isolation` are both core; the kind separates them downstream.
_SUBTREE_CATEGORY = [
    ("contrib/", CAT_CONTRIB),
    ("src/test/modules/", CAT_MODULE),
    ("src/pl/", CAT_PL),
    ("src/test/regress", CAT_CORE),
    ("src/test/isolation", CAT_CORE),
]

# Make-path fallback: the make `test_suites` introspect carries no category
# field and no module suites (intentionally omitted upstream), so derive from
# the slug over a closed set. The 4 PL names are the full upstream PL list;
# everything non-core/non-PL in the make universe is contrib.
_MAKE_PL_SLUGS = ["plpgsql", "plperl", "pltcl", "plpython"]

def _arg_after(cmd, flag):
    """The token after the first exact `flag` in `cmd`, or `""` (absent/trailing)."""
    for i in range(len(cmd)):
        if cmd[i] == flag and i + 1 < len(cmd):
            return cmd[i + 1]
    return ""

def _gh_relative(tok):
    """The path after `/gh/` in a sanitized source token, or `""` if no `/gh/`.

    meson's sanitized cmd keeps source paths as `.../gh/<subtree>`; the segment
    after the marker is the repo-root-relative path (e.g. `contrib/adminpack`,
    `src/test/modules/test_slru/test_slru.conf`).
    """
    marker = "/gh/"
    i = tok.find(marker)
    return tok[i + len(marker):] if i >= 0 else ""

def _temp_config_srcrel(cmd):
    """Repo-root-relative path of a suite's upstream `--temp-config` .conf, or `""`.

    Upstream meson `regress_args` point `--temp-config` at a .conf checked into
    the suite's OWN source subtree (`src/test/modules/test_slru/test_slru.conf`,
    `contrib/test_decoding/logical.conf`, ...), needed by suites whose extension
    must be `shared_preload_libraries`-loaded (test_slru, snapshot_too_old) or
    that set GUCs (test_decoding `wal_level`, ...). The .conf rides the PG
    `:src` tree the harness already stages, so the renderer threads this
    `/gh/`-relative path and the harness resolves it against the located source
    root, with no checked-in copy. `""` for the vast majority of suites (no
    `--temp-config`). A checked-in `test_overrides[...].temp_config` still wins
    (contrib + forks).
    """
    return _gh_relative(_arg_after(cmd, "--temp-config"))

def _eq_values(cmd, prefix):
    """Values of every `--flag=value` token in `cmd` sharing `prefix`, in order.

    Upstream meson passes repeatable pg_regress flags `=`-joined
    (`--load-extension=pltcl`, `--create-role=regress_x`). Returns e.g.
    `["pltcl"]` / `["regress_x", ...]`; `[]` when none.
    """
    n = len(prefix)
    return [a[n:] for a in cmd if a.startswith(prefix)]

def _regress_encoding(cmd):
    """The pg_regress `--encoding` value (e.g. `UTF8`), or `""`.

    meson emits it `=`-joined (`--encoding=UTF8`); the two-token form is
    accepted too. A suite that asks for an encoding (unaccent, test_extensions,
    ...) must get it or its golden diverges.
    """
    eq = _eq_values(cmd, "--encoding=")
    return eq[0] if eq else _arg_after(cmd, "--encoding")

def _srcdir_subtree(cmd):
    """The `<subtree>` after `/gh/` in the FIRST `--srcdir`/`--inputdir` token.

    meson's sanitized cmd keeps the source path as `.../gh/<subtree>` (e.g.
    `.../gh/contrib/adminpack`). Returns the subtree (`contrib/adminpack`) or
    `""` when neither flag is present, or its value carries no `/gh/` (the
    `@SOURCE_ROOT@` scanner/codegen entries, all TAP/setup -> never emitted).
    """
    for flag in ("--srcdir", "--inputdir"):
        tok = _arg_after(cmd, flag)
        if tok:
            rel = _gh_relative(tok)
            if rel:
                return rel
    return ""

def _package_subtree(subtree):
    """The `src/`-stripped, normalized source subtree for the package layout.

    `src/test/recovery` -> `test/recovery`, `src/bin/pg_dump` -> `bin/pg_dump`,
    `contrib/amcheck` -> `contrib/amcheck` (no `src/` to strip). plpgsql's
    inputdir is `src/pl/plpgsql/src`; trim the trailing `/src` so the package is
    `pl/plpgsql`. Returns "" for an empty subtree (the make path, which keeps
    the category-based layout).
    """
    if not subtree:
        return ""
    s = subtree[len("src/"):] if subtree.startswith("src/") else subtree
    if s.endswith("/src"):
        s = s[:-len("/src")]
    return s

def _classify_category(subtree):
    """Map a source subtree to a category by longest-prefix match.

    An empty subtree (the non-`/gh/` scanner entries) maps to core; harmless,
    since those entries are TAP/setup and are never emitted.
    """
    for prefix, cat in _SUBTREE_CATEGORY:
        if subtree.startswith(prefix):
            return cat
    return CAT_CORE

def _category_from_make_slug(slug):
    """Make-path category from the slug (no category field, no modules)."""
    if slug in ("regress", "isolation"):
        return CAT_CORE
    if slug in _MAKE_PL_SLUGS:
        return CAT_PL
    return CAT_CONTRIB

def _default_dbname(kind):
    """Default regression database for a SuiteDecl that names none.

    Mirrors the per-kind default a make/oracle suite historically ran in: core
    regress `regression`, isolation `isolation_regression`. TAP takes no
    `--dbname` (it drives its own clusters), so it defaults empty -- matching a
    meson TAP entry, whose cmd carries no `--dbname` either.
    """
    if kind == KIND_TAP:
        return ""
    if kind == KIND_ISOLATION:
        return "isolation_regression"
    return "regression"

def _has(cmd, needle):
    """True if any `cmd` token contains `needle` (substring match)."""
    return any([needle in arg for arg in cmd])

def _has_token(cmd, token):
    """True if any `cmd` token equals `token` exactly."""
    return token in cmd

def _extract_tests(cmd):
    """The pg_regress positional test names (the REGRESS list) from a `.cmd`.

    meson's testwrap emits `... pg_regress <flags...> --port <n> <test...>`, so
    the inline test names are the trailing positionals after `--port <value>`
    (e.g. citext -> `create_index_acl citext citext_utf8`). Returns [] when
    `--port` is absent or the suite is schedule-driven (its trailing args are
    flags, which the `--`-prefix filter drops). The `.name` tail is meson's
    generic group testname (`regress`), NOT the pg_regress test list.
    """
    for i in range(len(cmd)):
        if cmd[i] == "--port":
            return [a for a in cmd[i + 2:] if not a.startswith("--")]
    return []

def _classify_kind(cmd, protocol):
    """Classify ONE `.tests[]` entry into a runner kind.

    Order matters: an isolation cmd also contains a `pg_regress`-ish path, so
    `pg_isolation_regress` wins; the 3 `postgresql:setup` entries are the only
    `exitcode` protocol and fall through to `setup`; everything else with a
    `/pg_regress` token is `regress`; the remaining 221 are Perl TAP.
    """
    if _has(cmd, "pg_isolation_regress"):
        return KIND_ISOLATION
    if _has(cmd, "/pg_regress"):
        return KIND_REGRESS
    if protocol == "exitcode":
        return KIND_SETUP
    return KIND_TAP

def _test_entry_decode(raw):
    """Decode one raw `.tests[]` dict into a `TestEntry` struct.

    `raw` is one element of the JSON array. `cmd`/`env` are read here only to
    derive booleans; they are not stored on the struct (so nothing downstream
    can leak a sanitized placeholder path into a rendered target).
    """
    cmd = raw.get("cmd", [])
    subtree = _srcdir_subtree(cmd)
    category = _classify_category(subtree)
    env = raw.get("env", {})
    protocol = raw.get("protocol", "tap")
    return struct(
        name = raw["name"],
        # `suite` is always a single-element list `["postgresql:<group>"]`; the
        # slug is the grouping key (one `sh_test` per slug).
        suite_slug = raw["suite"][0].split(":", 1)[-1],
        protocol = protocol,
        is_parallel = raw.get("is_parallel", False),
        timeout = raw.get("timeout", 0),
        kind = _classify_kind(cmd, protocol),
        # `--schedule …_schedule` present? (regress/isolation only). A schedule
        # whose basename is `*_schedule`; match the `_schedule` substring.
        is_schedule = _has(cmd, "_schedule"),
        # the 148-entry "20-conn" group marker.
        uses_20conn = _has_token(cmd, _MAX_CONCURRENT_20),
        # PG17/18 ship `INITDB_TEMPLATE` in the regress env; PG16 does not. Key
        # PRESENCE is the signal (value is a sanitized placeholder path).
        has_initdb_template = "INITDB_TEMPLATE" in env,
        # inline pg_regress test names (contrib / module groups; [] for
        # schedule-driven core/isolation).
        tests = _extract_tests(cmd),
        # The suite's pg_regress value-flags, mirrored verbatim from the cmd so
        # our run is its exact upstream invocation: the database it runs in
        # (worker_spi's worker connects to `worker_spi.database`, which must
        # equal --dbname), its encoding, whether it forces C locale, and the
        # extensions / roles pg_regress pre-creates. `temp_config_srcrel` is the
        # repo-root- relative path of its --temp-config .conf (rides the PG :src
        # tree).
        temp_config_srcrel = _temp_config_srcrel(cmd),
        dbname = _arg_after(cmd, "--dbname"),
        encoding = _regress_encoding(cmd),
        no_locale = _has_token(cmd, "--no-locale"),
        load_extensions = _eq_values(cmd, "--load-extension="),
        create_roles = _eq_values(cmd, "--create-role="),
        # Build-config env gates the TAP .pl read (with_ldap, with_ssl,
        # enable_injection_points, ...): meson sets them from the build config
        # and the introspect TAP entry carries them. Threaded into the TAP run
        # so a `use warnings FATAL` read of an absent gate cannot abort the
        # script and a suite's own skip logic (e.g. skip unless with_ldap)
        # matches the build. The path-valued env (PG_REGRESS, top_builddir, ...)
        # is the harness's to set, so only the `with_`/`enable_` gates are
        # carried.
        tap_env = {
            k: v
            for k, v in env.items()
            if k.startswith("with_") or k.startswith("enable_")
        },
        category = category,
        # The source subtree the suite lives in (`src/test/recovery`,
        # `src/bin/pg_dump`, `contrib/amcheck`), verbatim from the cmd. The
        # harness resolves the suite's srcdir against it; `package_subtree`
        # derives the `src/`-stripped package path from it. "" for the make path
        # (no introspect subtree).
        subtree = subtree,
    )

def _suite_info_classify(entries):
    """Reduce a slice of `TestEntry`s sharing a `suite_slug` into a `SuiteInfo`.

    Folds the per-entry kind/booleans into one per-group verdict the renderer
    consumes:

    - `kind`: isolation > regress > setup > tap (any isolation entry promotes
      the whole group; otherwise any regress entry; etc.).
    - `is_schedule` / `uses_20conn` / `has_initdb_template`: OR over the slice.
    - `max_timeout`: the band-driving max of the per-entry timeouts.
    - `test_count`: slice length; feeds the small/medium/large sizing.
    - `schedule`: the basename selector for schedule-driven kinds, else `None`.
    """
    slug = entries[0].suite_slug

    # All entries of a slug share a source subtree, so category is constant.
    category = entries[0].category
    kind = KIND_TAP
    is_schedule = False
    uses_20conn = False
    has_initdb_template = False

    # introspect pg_regress value-flags, folded across the (slug, kind) entries:
    # first non-empty dbname/encoding/temp-config, the OR of --no-locale, and
    # the de-duplicated union of --load-extension / --create-role.
    temp_config_srcrel = ""
    dbname = ""
    encoding = ""
    any_no_locale = False
    load_extensions = []
    create_roles = []
    tap_env = {}
    max_timeout = 0

    # kind precedence rank; the highest-ranked entry kind wins for the group.
    # (Reuses the module-level table; for a uniform same-kind slice the loop
    # just re-affirms that one kind.)
    rank = _KIND_RANK

    for e in entries:
        if rank[e.kind] > rank[kind]:
            kind = e.kind
        is_schedule = is_schedule or e.is_schedule
        uses_20conn = uses_20conn or e.uses_20conn
        has_initdb_template = has_initdb_template or e.has_initdb_template
        if not temp_config_srcrel:
            temp_config_srcrel = e.temp_config_srcrel
        if not dbname:
            dbname = e.dbname
        if not encoding:
            encoding = e.encoding
        any_no_locale = any_no_locale or e.no_locale
        for x in e.load_extensions:
            if x not in load_extensions:
                load_extensions.append(x)
        for x in e.create_roles:
            if x not in create_roles:
                create_roles.append(x)
        tap_env.update(e.tap_env)
        max_timeout = max(max_timeout, e.timeout)

    schedule = _SCHEDULE_BY_KIND.get(kind) if is_schedule else None

    # Inline pg_regress test list, in introspect order (== meson/REGRESS order,
    # which is load-bearing), concatenated across the group's entries. Used by
    # contrib / module `pg_regress` groups that carry no `--schedule` file.
    test_names = [t for e in entries for t in e.tests]

    # `force` => the suite's cmd passes --no-locale; `inherit` => it omits it
    # (the DB still comes up C via the ambient LC_ALL=C / the C initdb
    # template). Explicit for the meson path so the renderer mirrors the cmd
    # exactly.
    locale_mode = "force" if any_no_locale else "inherit"

    return struct(
        slug = slug,
        kind = kind,
        is_schedule = is_schedule,
        uses_20conn = uses_20conn,
        has_initdb_template = has_initdb_template,
        temp_config_srcrel = temp_config_srcrel,
        dbname = dbname,
        encoding = encoding,
        locale_mode = locale_mode,
        tap_locale = "",
        tap_exclusive = [],
        load_extensions = load_extensions,
        create_roles = create_roles,
        tap_env = tap_env,
        max_timeout = max_timeout,
        test_count = len(entries),
        test_names = test_names,
        # the `-running` (use-existing-server) variant suite slug. Carried so
        # the override layer can filter these without re-parsing; the default
        # renderer emits a target for every slug.
        is_running = slug.endswith("-running"),
        schedule = schedule,
        category = category,
        subtree = entries[0].subtree,
        # The external-extension `--inputdir` (the suite's REGRESS_OPTS
        # `--inputdir`, joined with the ext source root by the harness); only a
        # `metadata.test_ext` regress decl sets it, so "" for every core/contrib
        # suite (which resolve their srcdir from the subtree instead).
        inputdir = "",
        # A suite whose --temp-config .conf or expected/ dir lives in its own
        # source tree (external `metadata.test_ext` regress decls); "" for every
        # core/contrib suite, which carry neither.
        temp_config = "",
        expecteddir = "",
        # The shared_preload_libraries an external regress suite needs but ships
        # no .conf for; empty for every core/contrib suite.
        preload = [],
        # Per-.pl basenames (the part after the suite slug in each entry name,
        # e.g. `recovery/001_stream_rep` -> `001_stream_rep`); the TAP renderer
        # emits one target per .pl. Meaningful for TAP, harmless otherwise.
        pl_names = [e.name.rsplit("/", 1)[-1] for e in entries],
    )

def _group_by_suite(raw_tests):
    """Group the raw `.tests` array into `{suite_slug: [TestEntry, ...]}`.

    Decodes each entry once and buckets by `suite_slug`. Returns an empty dict
    for an empty `.tests` (make-flavor synth) so the caller's `if not groups:
    continue` guard fires cleanly.
    """
    by_slug = {}
    for raw in raw_tests:
        entry = _test_entry_decode(raw)
        by_slug.setdefault(entry.suite_slug, []).append(entry)
    return by_slug

# kind precedence rank, shared by the per-group reduction and the primary-kind
# pick. Highest rank is the PRIMARY kind for a slug (keeps the bare
# `<opt>.<slug>` name); lower-ranked kinds get a `.<kind>` suffix.
_KIND_RANK = {KIND_TAP: 0, KIND_SETUP: 1, KIND_REGRESS: 2, KIND_ISOLATION: 3}

# Emit order of a slug's per-kind SuiteInfos: the first kind PRESENT is the
# PRIMARY (bare `<opt>.<slug>` name); the rest get a `.<kind>` suffix. regress
# is primary so a dual-kind contrib renders `<opt>.<slug>` (regress) +
# `<opt>.<slug>.isolation`; a pure-isolation slug (core `isolation`) still gets
# the bare name.
_KINDS_BY_RANK = [KIND_REGRESS, KIND_ISOLATION, KIND_SETUP, KIND_TAP]

def _partition_by_kind(entries):
    """Split a slug's `TestEntry`s into `{kind: [TestEntry, ...]}` (order preserved)."""
    by_kind = {}
    for e in entries:
        by_kind.setdefault(e.kind, []).append(e)
    return by_kind

def _suites_from_tests(raw_tests):
    """Decode + group + classify a raw `.tests` array into `{slug: [SuiteInfo]}`.

    The single entry point the repo rule calls per `(version, option_set)`. One
    `SuiteInfo` per (slug, kind): a slug whose `.tests[]` mix kinds (the
    dual-kind contrib suites test_decoding / postgres_fdw, set varies by
    version) yields one reduction per kind over only that kind's entries; a
    single-kind slug yields a 1-element list. Ordered by descending kind rank
    (primary kind first).
    """
    by_slug = _group_by_suite(raw_tests)
    out = {}
    for slug, entries in by_slug.items():
        by_kind = _partition_by_kind(entries)
        out[slug] = [
            _suite_info_classify(by_kind[kind])
            for kind in _KINDS_BY_RANK
            if kind in by_kind
        ]
    return out

def _suite_decl_to_info(slug, decl):
    """Build one `SuiteInfo` from a `test_suites`/`metadata.test` SuiteDecl.

    The make-path analog of `_suite_info_classify`: a SuiteDecl already names
    its `kind`, its source `subtree`, and (for core regress/isolation) its
    `schedule` basename, so there is no per-entry reduction -- the fields are
    read straight off the decl. `max_timeout` is 0 (the make introspect carries
    no per-test timeout, so sizing falls back to `test_count`/`_BIG_SUITES`) and
    `has_initdb_template` is False (PG <= 15 and the make flavors ship no
    installed `initdb-template`, so the harness always runs initdb itself).

    A `kind: tap` decl carries its `.pl` basenames as `tests`: they become
    `pl_names` (the TAP renderer emits one target per .pl) while the inline
    pg_regress `test_names`/`dbname` stay empty and the locale inherits, so a
    make TAP SuiteInfo is shaped identically to a meson one. A decl with no
    `subtree` (a hand-written `metadata.test`/oracle block) keeps the
    category-based layout.
    """
    sched = decl.get("schedule")
    tests = decl.get("tests", [])
    kind = decl["kind"]
    is_tap = kind == KIND_TAP
    subtree = decl.get("subtree", "")

    # Prefer the subtree-derived category (the `test_suites` introspect names
    # the subtree, so a core TAP suite like `recovery` is not treated as contrib
    # by the slug heuristic); fall back to the slug for a subtree-less
    # `metadata.test`/oracle decl.
    category = decl.get("category") or (
        _classify_category(
            subtree,
        ) if subtree else _category_from_make_slug(slug)
    )
    return struct(
        slug = slug,
        kind = kind,
        is_schedule = sched != None,
        # inline test list only for a non-TAP suite with no schedule file: a
        # schedule suite drives off its basename and a TAP suite off `pl_names`,
        # so neither carries an inline pg_regress `--tests` list (the `tests`
        # field is then the schedule / `.pl` contents, kept for sizing/review).
        test_names = [] if (sched or is_tap) else tests,
        uses_20conn = decl.get("max_conc") == 20,
        has_initdb_template = False,
        # make/oracle introspect (no introspect cmd to mirror): a decl may name
        # these explicitly; otherwise derive the database from the kind and
        # force C locale (locale_mode ""), except TAP, which takes no --dbname
        # and inherits locale like the meson TAP entries. The make introspect
        # carries no module suites, which is where meson needs
        # temp_config_srcrel.
        temp_config_srcrel = decl.get("temp_config_srcrel", ""),
        dbname = decl.get("dbname") or _default_dbname(kind),
        encoding = decl.get("encoding", ""),
        locale_mode = decl.get("locale_mode", "inherit" if is_tap else ""),
        # A TAP suite's node locale (e.g. `C.UTF-8` for a suite that needs a
        # UTF-8 database); the hermetic default is C, i.e. SQL_ASCII.
        tap_locale = decl.get("locale", ""),
        # `.pl` basenames a TAP suite runs exclusively (no concurrent tests),
        # for a timing-sensitive test that is deterministic only without
        # parallel CPU contention (pg_stat_monitor's response-time histogram).
        tap_exclusive = decl.get("exclusive", []),
        load_extensions = decl.get("load_extensions", []),
        create_roles = decl.get("create_roles", []),
        tap_env = decl.get("tap_env", {}),
        max_timeout = 0,
        test_count = len(tests),
        is_running = slug.endswith("-running"),
        schedule = sched,
        category = category,
        # The suite's source subtree (`src/test/regress`, `src/bin/pg_dump`,
        # `contrib/amcheck`), carried by the `test_suites` introspect so the
        # renderer mirrors the source tree exactly like the meson path. "" for a
        # subtree-less decl, which keeps the category-based layout.
        subtree = subtree,
        # The external-extension `--inputdir` (REGRESS_OPTS `--inputdir`, e.g.
        # pgvector's `test`), joined with the ext source root by the harness.
        # Only an external `metadata.test_ext` regress decl sets it; "" for the
        # make/oracle introspect.
        inputdir = decl.get("inputdir", ""),
        # An external regress suite whose --temp-config .conf lives in its own
        # source tree (relative to --ext-srcdir, e.g. pgaudit.conf) and/or whose
        # expected/ dir sits outside its --inputdir (pg_qualstats keeps sql
        # under test/ but expected/ at the source root). "" for the make/oracle
        # introspect.
        temp_config = decl.get("temp_config", ""),
        expecteddir = decl.get("expecteddir", ""),
        # The shared_preload_libraries the suite needs but ships no .conf for.
        preload = decl.get("preload", []),
        # Per-.pl basenames for a TAP suite (its `tests` IS the .pl list); the
        # TAP renderer emits one target per .pl. Empty for non-TAP.
        pl_names = tests if is_tap else [],
    )

def _resolve_tests(tests, version):
    """Resolve a spec-keyed `tests` map to the flat list for `version`.

    An external extension introspect keys a suite's `tests` by a base-version
    spec: `{"*": [...]}` for a version-agnostic suite, or disjoint specs like
    `{">=16,<18": [...], ">=18": [...]}` when the upstream `REGRESS` list varies
    by base major. Every spec matching `version` contributes, in map order,
    deduped so an overlapping wildcard does not double-list. A bare list (the
    make-path introspect, whose `tests` is always version-exact) is returned
    unchanged.
    """
    if type(tests) != "dict":
        return tests
    out = []
    for spec, names in tests.items():
        if not is_compatible_with(version, spec):
            continue
        for name in names:
            if name not in out:
                out.append(name)
    return out

def _suites_from_metadata_test(test_meta, version):
    """Decode a catalog `metadata.test` block into `{slug: [SuiteInfo]}`.

    The make-path analog of `_suites_from_tests`: MAKE builds (PG <= 15 and the
    make flavors) synthesize an introspect JSON with no `.tests` array, so the
    suites is read from a checked-in `metadata.test` block instead. The result
    is the SAME `SuiteInfo` shape `suites.bzl` renders, so everything downstream
    (sizing, `_runner_args`, the `test_overrides` post-pass) is agnostic to
    which introspect source produced it.

    `test_meta` is version-spec-keyed (`{spec: {slug: decl}}`, reusing the
    `metadata.deps`/`patches` idiom); every spec matching `version` contributes
    (additive union, later spec wins on a slug clash -- specs are written
    disjoint). A `SuiteDecl` value is one object (single kind) or a list of
    objects (a dual-kind slug, e.g. test_decoding's regress + isolation),
    mirroring `groups[slug]` already being a list of per-kind `SuiteInfo`s.

    Args:
        test_meta: the `metadata.test` map (`{version_spec: {slug:
            decl|[decl]}}`).
        version: the PG `major.minor` this build targets (e.g. `"15.0"`).

    Returns:
        `{slug: [SuiteInfo]}`, each slug's list ordered primary-kind-first
        (regress before isolation), identical to `_suites_from_tests`.
    """
    merged = {}
    for spec, slug_map in test_meta.items():
        if is_compatible_with(version, spec):
            for slug, decl in slug_map.items():
                merged[slug] = decl

    out = {}
    for slug, value in merged.items():
        decls = value if type(value) == "list" else [value]

        # Resolve each decl's spec-keyed `tests` map to the flat list for this
        # base version before classifying, so `_suite_decl_to_info` (shared with
        # the make path) always sees a plain list.
        by_kind = {}
        for decl in decls:
            resolved = dict(decl)
            names = _resolve_tests(decl.get("tests", []), version)

            # `exclude_tests` resolves the same way (flat list drops on every
            # version; spec-keyed map drops only on matching versions), then
            # subtracts from the resolved test list. This is how a suite keeps a
            # test whose committed golden matches only some PG majors.
            excluded = _resolve_tests(decl.get("exclude_tests", []), version)
            if excluded:
                names = [t for t in names if t not in excluded]

            resolved["tests"] = names
            resolved.pop("exclude_tests", None)

            # A suite that resolves to no tests and no schedule has nothing to
            # run on this base version (e.g. exclude_tests dropped every test on
            # this major), so drop the decl rather than emit an unrunnable
            # suite; a slug left with no kinds is dropped below.
            if not names and not resolved.get("schedule"):
                continue

            by_kind[decl["kind"]] = resolved

        infos = [
            _suite_decl_to_info(slug, by_kind[kind])
            for kind in _KINDS_BY_RANK
            if kind in by_kind
        ]
        if infos:
            out[slug] = infos
    return out

def _suites_from_test_suites(test_suites):
    """Decode the make introspect's `test_suites` introspect into `{slug: [SuiteInfo]}`.

    The make analog of `_suites_from_tests`: MAKE builds synthesize a
    `test_suites` array into their introspect JSON
    (`//tools:pg_build_make_introspect.py`), generated from the EXACT built
    tree's schedules + `REGRESS`/`ISOLATION` Makefile vars and gated by what
    actually installed, so it is version-exact AND option-set-exact -- the same
    properties meson's `.tests` has. Each entry is one pre-classified (slug,
    kind) SuiteDecl (`{slug, kind, schedule?, tests, max_conc?}`); a slug that
    defines both `REGRESS` and `ISOLATION` (e.g. test_decoding) appears as two
    entries, grouped here into one `[regress, isolation]` list (primary kind
    first), identical to `_suites_from_tests`.
    """
    by_slug = {}
    for entry in test_suites:
        by_slug.setdefault(entry["slug"], {})[entry["kind"]] = entry

    out = {}
    for slug, by_kind in by_slug.items():
        out[slug] = [
            _suite_decl_to_info(slug, by_kind[kind])
            for kind in _KINDS_BY_RANK
            if kind in by_kind
        ]
    return out

def _split_by_category(groups):
    """Partition `{slug: [SuiteInfo]}` into `{category: {slug: [SuiteInfo]}}`.

    A slug's per-kind SuiteInfos share a category (same subtree), so split on
    element 0. Routes core/pl/module to the base hub `@{name}` and contrib to
    the extensions hub `@{name}_ext` from one decode.
    """

    out = {CAT_CORE: {}, CAT_PL: {}, CAT_MODULE: {}, CAT_CONTRIB: {}}
    for slug, infos in groups.items():
        if infos:
            out[infos[0].category][slug] = infos
    return out

test_entry = struct(
    decode = _test_entry_decode,
)

suite_info = struct(
    classify = _suite_info_classify,
)

schema = struct(
    # kind constants (re-exported so suites.bzl imports them from one place).
    KIND_ISOLATION = KIND_ISOLATION,
    KIND_REGRESS = KIND_REGRESS,
    KIND_TAP = KIND_TAP,
    KIND_SETUP = KIND_SETUP,
    CAT_CORE = CAT_CORE,
    CAT_PL = CAT_PL,
    CAT_MODULE = CAT_MODULE,
    CAT_CONTRIB = CAT_CONTRIB,
    TestEntry = test_entry,
    SuiteInfo = suite_info,
    group_by_suite = _group_by_suite,
    suites_from_tests = _suites_from_tests,
    suites_from_test_suites = _suites_from_test_suites,
    suites_from_metadata_test = _suites_from_metadata_test,
    split_by_category = _split_by_category,
    # exposed for unit tests
    srcdir_subtree = _srcdir_subtree,
    package_subtree = _package_subtree,
    classify_category = _classify_category,
)
