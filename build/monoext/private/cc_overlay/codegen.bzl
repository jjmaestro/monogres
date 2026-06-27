"""Codegen genrule translation for the native cc_* Postgres overlay.

Codegen (analysis section 3): Postgres generates headers and sources at build
time with perl scripts, bison, and flex (the flex run wrapped by the pgflex
python helper). The introspect records each generator as a `custom` target
carrying the resolved command line (with meson `@INPUT@` / `@OUTPUT@` /
`@OUTDIR@` / `@SOURCE_ROOT@` / `@BUILD_ROOT@` / `@PRIVATE_DIR@` placeholders)
plus its inputs and declared outputs. `codegen_genrule` translates one such
target into a Bazel genrule, rewriting tool paths to `$(execpath ...)` and
substituting the placeholders, and exports each tool's runtime environment
inline (genrules have no `env` attr): the @perl_sysroot loader + @INC, the
@libc_sysroot the rules-built bison / flex / m4 link against, m4 for bison /
flex, and the hermetic python interpreter's stdlib. The generated headers
collect into `pg_generated_headers`; the generated compiled sources (gram.c,
scan.c, ...) become srcs of the libs whose introspect `generated_sources` list
them, resolved through a producer index so the two same-named `gram` targets
stay distinct.
"""

load("@starlark_utils//starlark:starlark.bzl", Star = "starlark")
load("//toolchains/perl:perl_toolchain.bzl", _PERL_VERSION = "PERL_VERSION")
load(
    ":flags.bzl",
    "dedup",
    "reconcile_build_flags",
    "rel_out",
    "rel_src",
    "resolve_sysroot",
)
load(
    ":labels.bzl",
    "gen_label",
    "longest_pkg_prefix",
    "src_label",
)

# Perl interpreter + toolchain, resolved from the overlay repo's repo mapping
# (the monogres module's, like the rest of the generated BUILD). Same labels
# `pg_build.bzl` threads into the meson build: `:perl` is the per-arch
# single-file alias whose underlying target carries the @perl_sysroot tree as
# runfiles, and `:current_perl_toolchain` emits the `$(PERL_MULTIARCH)` make
# variable used to locate perl's module dirs.
_PERL_BIN = "@monogres//toolchains/perl:perl"
_PERL_TOOLCHAIN = "@monogres//toolchains/perl:current_perl_toolchain"

# The @perl_sysroot tree as a direct genrule input. `:perl`'s DefaultInfo
# exposes only the interpreter binary as `files`; the interpreter's NEEDED
# shared libs (libm, libc, ...) and its perl modules ride along as runfiles,
# which the hermetic Linux sandbox does not materialize for a genrule `tools`
# dep. Naming the sysroot filegroup here makes every one of its files a declared
# action input, so the loader (via LD_LIBRARY_PATH) and @INC (via PERL5LIB)
# resolve.
_PERL_SYSROOT = "@monogres//toolchains/perl:sysroot"

# Codegen tool binaries, keyed by the basename they appear under in the
# introspect command (compiler[0], or embedded like pgflex's --flex / --perl).
_BISON_BIN = "@bison//bin:bison"
_FLEX_BIN = "@flex//bin:flex"
_M4_BIN = "@m4//bin:m4"
_PYTHON_BIN = "@python_3_11//:python3"
_TOOL_BIN = {
    "bison": _BISON_BIN,
    "flex": _FLEX_BIN,
    "m4": _M4_BIN,
    "perl": _PERL_BIN,
    "python3": _PYTHON_BIN,
}

# Codegen tools resolved from PATH rather than a Bazel label: the hermetic Linux
# sandbox mounts busybox as every POSIX utility (see .bazelrc.sandbox_linux), so
# `sed` (the probes.h dummy generator) is present in every action without being
# a declared input, exactly like the dirname / mkdir / mktemp the other genrules
# already call.
_PATH_TOOLS = ["sed"]

# config_info.c build-string defines, the values pg_config reports. The
# introspect bakes the meson build's own flag strings into -DVAL_*, interleaving
# portable PG-semantic flags with cc_toolchain-injected ones carrying sanitized,
# non-portable paths. The native values are computed (see
# render_config_info_vals) and force-included as a header rather than passed as
# -D defines, since a -D with embedded spaces does not survive clang's
# response-file parser.
_VAL_DEFINES = [
    "VAL_CC",
    "VAL_CPPFLAGS",
    "VAL_CFLAGS",
    "VAL_CFLAGS_SL",
    "VAL_LDFLAGS",
    "VAL_LDFLAGS_EX",
    "VAL_LDFLAGS_SL",
    "VAL_LIBS",
]

# The generated header carrying the native VAL_* defines, force-included into
# the config_info libs. Lands under src/common (on their include path) and rides
# pg_generated_headers so it stages into the compile.
_CONFIG_INFO_VALS_H = "src/common/config_info_vals.h"

# The hermetic python distribution's full file set (interpreter + stdlib),
# arch-selected by the rules_python toolchain-aliases repo. `@python_3_11`
# exposes only the binary by default; the sandbox does not materialize its
# stdlib from runfiles, so the pgflex wrapper's interpreter needs `:files` named
# as a direct input.
_PYTHON_FILES = "@python_3_11//:files"

# The libc sysroot bison / flex / m4 (and the hermetic python) were built
# against, as the exec-config make-var instance. Listed in a genrule's
# `toolchains`, it both provides `$(LIBC_SYSROOT_EXEC_DIR)` /
# `$(LIBC_SYSROOT_EXEC_MULTIARCH)` and (via the rule's forwarded DefaultInfo)
# stages the sysroot tree into the action, so the loader finds those tools'
# NEEDED libs (libm, libc) in the hermetic sandbox.
_LIBC_EXEC_DIR = "@monogres//toolchains/libc_sysroot:libc_sysroot_exec_dir"

# fix-old-flex-code.pl, the perl post-processor pgflex runs (via --srcdir) on
# every generated scanner; not named on the command line, so stage it explicitly
# for flex genrules.
_FLEX_FIX_SCRIPT = "src/tools/fix-old-flex-code.pl"

# Perl generators rendered as genrules unconditionally (the bison / flex
# generators are discovered through the producer index from each lib's
# `generated_sources`, so they are not listed here). These produce headers,
# textually-included bodies, or install-tree data no lib lists as a compiled
# source, so nothing else would pull them in.
CODEGEN_TARGETS = [
    "errcodes",
    "kwlist",
    "fmgrtab",
    "generated_catalog_headers",
    "nodetags.h",
    "lwlocknames",
    # The backend includes utils/probes.h through pg_trace.h; with dtrace off it
    # is a dummy header sed-generated from probes.d. No lib lists it as a
    # compiled source, so render it like the perl header generators.
    "probes.h",
    # snowball_create.sql, the text-search config bootstrap initdb runs; a data
    # file installed to share/, produced by a perl generator.
    "snowball_create",
    # plpgsql's generated headers (plerrcodes.h from the backend errcodes,
    # pl_reserved_kwlist_d.h / pl_unreserved_kwlist_d.h from its keyword lists).
    # plpgsql.so #includes them from its own dir; no lib compiles them, so
    # render them like the other perl header generators.
    "plerrcodes",
    "pl_reserved_kwlist",
    "pl_unreserved_kwlist",
    # The interpreter PLs' generated headers: plperl's perlchunks.h (the perl
    # bootstrap chunks macro-ified by text2macro.pl), plpython3's
    # spiexceptions.h and pltcl's pltclerrcodes.h (both perl-generated from the
    # backend errcodes). Each PL #includes its own from its dir.
    "perlchunks.h",
    "plperl_opmask.h",
    "spiexceptions.h",
    "pltclerrcodes.h",
    # ecpg's keyword lists: gen_keywordlist.pl emits c_kwlist_d.h (the C
    # keywords) and ecpg_kwlist_d.h (the ecpg keywords); the ecpg preprocessor
    # #includes them from its own dir and no lib compiles them.
    "c_kwlist_d.h",
    "ecpg_kwlist_d.h",
    # contrib generators with no compiled consumer: fuzzystrmatch #includes the
    # perl-generated daitch_mokotoff.h textually, and sepgsql's extension SQL is
    # sed-generated from sepgsql.sql.in (installed to share/extension/, not
    # compiled). cube's / seg's bison + flex scanners are compiled sources, so
    # the producer index discovers them from the module's generated_sources.
    "daitch_mokotoff",
    "sepgsql.sql",
]

# Extra input globs per perl generator: modules loaded via `use lib` / FindBin
# and the catalog data files read through `--include-path`, none of which appear
# in the target's `sources`. The hermetic sandbox stages only declared inputs,
# so the scripts cannot reach their siblings unless these are named. `*.h` /
# `*.dat` under the catalog dir subsume the listed `@INPUT@` headers, so those
# are dropped from the explicit src list to avoid duplicate labels.
_CODEGEN_EXTRA_SRCS = {
    # gen_keywordlist.pl loads PerfectHash.pm for the ecpg keyword lists too.
    "c_kwlist_d.h": ["src/tools/*.pm"],
    "ecpg_kwlist_d.h": ["src/tools/*.pm"],
    # Gen_fmgrtab.pl and genbki.pl load Catalog.pm and read the pg_*.dat files;
    # Catalog.pm's ParseHeader follows the catalog headers' #includes (e.g.
    # access/transam.h), so the whole src/include header tree must be staged.
    "fmgrtab": [
        "src/backend/catalog/*.pm",
        "src/include/catalog/*.dat",
        "src/include/**/*.h",
    ],
    "generated_catalog_headers": [
        "src/backend/catalog/*.pm",
        "src/include/catalog/*.dat",
        "src/include/**/*.h",
    ],
    # gen_keywordlist.pl loads PerfectHash.pm from src/tools (the backend
    # keyword list and plpgsql's reserved / unreserved lists all run it).
    "kwlist": ["src/tools/*.pm"],
    # gen_node_support.pl loads Catalog.pm via FindBin (`../catalog`).
    "nodetags.h": ["src/backend/catalog/*.pm"],
    "pl_reserved_kwlist": ["src/tools/*.pm"],
    "pl_unreserved_kwlist": ["src/tools/*.pm"],
    # create_help.pl scans the SQL-command reference SGML (--docdir
    # @SOURCE_ROOT@/doc/src/sgml/ref) to build psql's sql_help; the sources are
    # not listed on the target, so stage the whole ref/ tree.
    "psql_help": ["doc/src/sgml/ref/*.sgml"],
    # snowball_create.pl reads snowball.sql.in from its source dir
    # (@CURRENT_SOURCE_DIR@); it also probes stopwords/<lang>.stop there to emit
    # a `StopWords = <lang>` clause per language whose file it finds, so stage
    # the stopword list too (else the english config drops no stop words).
    "snowball_create": [
        "src/backend/snowball/*.sql.in",
        "src/backend/snowball/stopwords/*.stop",
    ],
}

def _genrule_name(out0_rel):
    """Collision-proof genrule name slugged from the first output path."""
    slug = out0_rel.replace("/", "_").replace(".", "_").replace("-", "_")
    return "gen_" + slug

def _covered(path, patterns):
    """Whether a glob pattern already stages `path` (so it isn't listed twice).

    Handles the two pattern shapes the codegen extras use: `dir/**/*.ext`
    (recursive) and `dir/*.ext` (direct child).
    """
    for p in patterns:
        if "/**/*." in p:
            d, ext = p.split("/**/*.", 1)
            if path.startswith(d + "/") and path.endswith("." + ext):
                return True
        elif "/*." in p:
            d, ext = p.split("/*.", 1)
            if path.startswith(d + "/"):
                child = path[len(d) + 1:]
                if "/" not in child and path.endswith("." + ext):
                    return True
    return False

def _srcs_node(explicit, extra):
    """Render a genrule `srcs` value, concatenating a glob when present."""
    if extra and explicit:
        return Star.binop("+", explicit, Star.glob(extra))
    if extra:
        return Star.glob(extra)
    return explicit

def _perl_env_prologue():
    """Prologue lines making the @perl_sysroot interpreter runnable.

    Derived the way `pg_build.bzl` derives it for the meson build:
    PERL_SYSROOT_DIR is three dirnames up from the interpreter binary;
    LD_LIBRARY_PATH points the loader at the sysroot's NEEDED libs and PERL5LIB
    at its @INC module dirs (the paths Debian compiled in do not exist in the
    hermetic sandbox). `$(PERL_MULTIARCH)` comes from the perl toolchain. Paths
    are anchored at `$$EXECROOT` (an absolute prefix set earlier) so they
    survive the pgflex wrapper's chdir, which would otherwise break a
    sandbox-relative LD_LIBRARY_PATH / PERL5LIB for the perl it spawns.
    """
    return [
        ('PERL_SYSROOT_DIR="$$EXECROOT/' +
         '$$(dirname $$(dirname $$(dirname $(execpath %s))))"') % _PERL_BIN,
        ('export LD_LIBRARY_PATH="%s' +
         '$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"') % ":".join([
            "$$PERL_SYSROOT_DIR/lib/$(PERL_MULTIARCH)",
            "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)",
        ]),
        'export PERL5LIB="%s"' % ":".join([
            "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl-base",
            "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl/" + _PERL_VERSION,
            "$$PERL_SYSROOT_DIR/usr/share/perl/" + _PERL_VERSION,
        ]),
    ]

_SHELL_META = "$ ()|*?&;<>'\"`"

def _needs_quoting(t):
    """Whether a literal arg token carries shell metacharacters."""
    for c in _SHELL_META.elems():
        if c in t:
            return True
    return False

def _pattern_base(pattern):
    """The literal directory prefix of a glob pattern (before the first `*`)."""
    head = pattern.split("*", 1)[0]
    return head.rsplit("/", 1)[0] if "/" in head else ""

def _fg_name(rel):
    """A filegroup name slugged from a (package-relative) glob pattern."""
    slug = rel.replace(
        "/",
        "_",
    ).replace("*", "_").replace(".", "_").replace("-", "_")
    return "cg_" + slug

def render_codegen_filegroups(needs):
    """Render the filegroups relocated genrules stage cross-package inputs by.

    A codegen extra-input glob (the src/tools scripts, the doc SGML, the catalog
    perl modules) that falls outside a relocated genrule's package can no longer
    be globbed locally; it is staged through a filegroup in the package that
    owns the glob, which the genrule references by label. The scripts find their
    siblings by their own path logic (perl FindBin, pgflex `--srcdir`), so
    staging at the overlay-relative path is all that is needed.

    Args:
        needs: a {owner_pkg: {filegroup_name: package-relative pattern}} dict
            accumulated while rendering the genrules.

    Returns:
        A {owner_pkg: [filegroup nodes]} dict (empty when no genrule needed
        one).
    """
    by_pkg = {}
    for owner in sorted(needs):
        nodes = []
        for name in sorted(needs[owner]):
            nodes.append(Star.igen(Star.fn(
                "filegroup",
                name = name,
                srcs = Star.glob([needs[owner][name]]),
            )))
        by_pkg[owner] = nodes
    return by_pkg

def codegen_genrule(target, packages, exports, needs):
    """Translate one codegen `custom` target into a genrule node + its outputs.

    Handles the perl (header generators), bison (parser .c/.h), and flex (via
    the pgflex python wrapper, scanner .c) tools. The genrule renders in its
    output directory's package (an introspect codegen target writes to exactly
    one directory), so `outs` are declared package-relative and every
    `$(execpath ...)` references the input by its resolved label. Rewrites every
    recorded tool path (compiler[0] and embedded ones like pgflex's --flex /
    --perl) to its `$(execpath ...)` label and substitutes the meson
    placeholders: `@INPUT@` -> the sources as `$(execpath ...)` in order;
    `@OUTPUT@` / `@OUTPUT0@` -> the first declared output; `@OUTDIR@` -> the
    genfiles output dir; `@BUILD_ROOT@` -> `$(RULEDIR)` (pgflex's --builddir is
    unused, so any abspath suffices); `@PRIVATE_DIR@` -> a fresh scratch dir;
    `@DEPFILE@` -> a throwaway path (Bazel tracks inputs itself);
    `@SOURCE_ROOT@` -> the overlay source root (recovered at action time by
    stripping a staged file's overlay-relative suffix from its execpath, which
    is package-independent). If no output placeholder appears, the tool writes
    to stdout, so the output is redirected. Each tool's runtime env is exported
    inline (genrules have no `env` attr).

    Args:
        target: a `custom` introspect target (perl, bison, or flex tool).
        packages: the active overlay package set.
        exports: the cross-package source-export accumulator (see `src_label`).
        needs: a {filegroup_name: glob_pattern} accumulator for the root
            filegroups a relocated genrule stages cross-package inputs by.

    Returns:
        A (home_pkg, genrule_node, outputs) tuple; outputs are overlay-relative
        paths (for the producer index), `home_pkg` the package the node renders
        in.
    """
    ts = target["target_sources"][0]
    compiler = ts["compiler"]
    outs_full = [rel_out(f) for f in target["filename"]]

    out0_full = outs_full[0]
    out0_dir = out0_full.rsplit("/", 1)[0] if "/" in out0_full else ""
    home = longest_pkg_prefix(packages, out0_dir)

    # In-package outputs are declared package-relative; `$(execpath ...)` and
    # `$(RULEDIR)` resolve to the same genfiles paths either way.
    outs = [gen_label(packages, o, home) for o in outs_full]
    out0 = outs[0]
    outdir_sub = out0.rsplit("/", 1)[0] if "/" in out0 else ""

    # A source is either checked-in (a `/gh/` path -> its source label) or
    # itself generated by another codegen target (a build-dir path -> the
    # producer's output by label): the ecpg preprocessor grammar is generated,
    # so bison reads preproc.y, which the perl parse.pl emits from the backend
    # gram.y.
    sources_full = []
    sources = []
    for s in ts["sources"]:
        if "introspect.build_tmpdir/" in s:
            rel = rel_out(s)
            sources.append(gen_label(packages, rel, home))
        else:
            rel = rel_src(s)
            sources.append(src_label(packages, exports, rel, home))
        sources_full.append(rel)

    base0 = compiler[0].split("/")[-1]
    lead = _TOOL_BIN.get(base0)
    lead_from_path = base0 in _PATH_TOOLS
    if not lead and not lead_from_path:
        fail(
            "codegen genrule: unsupported tool %r for %r" % (compiler[0], target["name"]),
        )
    lead_cmd = ("$(execpath %s)" % lead) if lead else base0

    input_expansion = " ".join(["$(execpath %s)" % s for s in sources])

    used = {}
    if lead:
        used[lead] = True
    scripts = []
    scripts_full = []
    args = []
    uses_outdir = False
    uses_srcroot = False
    uses_private = False
    uses_depfile = False
    saw_output = False
    for tok in compiler[1:]:
        if tok == "@INPUT@":
            args.append(input_expansion)
            continue
        if tok == "@INPUT0@":
            args.append("$(execpath %s)" % sources[0])
            continue
        base = tok.split("/")[-1]
        if "/" in tok and "/gh/" not in tok and base in _TOOL_BIN:
            # An embedded tool binary (pgflex's `--flex <bin>` / `--perl
            # <bin>`).
            lbl = _TOOL_BIN[base]
            used[lbl] = True
            args.append("$(execpath %s)" % lbl)
            continue
        if "/gh/" in tok:
            rel = rel_src(tok)
            lbl = src_label(packages, exports, rel, home)
            scripts.append(lbl)
            scripts_full.append(rel)
            args.append("$(execpath %s)" % lbl)
            continue
        if "perl_sysroot/" in tok:
            # A tool / data file inside the perl sysroot (plperl's xsubpp and
            # its typemap): reference it under the PERL_SYSROOT_DIR the perl
            # prologue computes, dropping the `<distro>/<ver>/<arch>/` prefix.
            # The tree is already staged (perl is the lead, so _PERL_SYSROOT
            # rides along). What is left still carries the sanitizer's
            # placeholders (`usr/share/perl/<PERL_VERSION>/ExtUtils/xsubpp`);
            # unresolved, bash reads `<PERL_VERSION>` as a redirection and the
            # action dies on "PERL_VERSION: No such file or directory".
            rel = tok.split("perl_sysroot/", 1)[1].split("/", 3)[-1]
            args.append("$$PERL_SYSROOT_DIR/" + resolve_sysroot(rel))
            continue
        t = tok
        if "@OUTDIR@" in t:
            t = t.replace("@OUTDIR@", "$$OUTDIR")
            uses_outdir = True
            saw_output = True
        if "@OUTPUT0@" in t:
            t = t.replace("@OUTPUT0@", "$(execpath %s)" % out0)
            saw_output = True
        if "@OUTPUT@" in t:
            t = t.replace("@OUTPUT@", "$(execpath %s)" % out0)
            saw_output = True
        if "@BUILD_ROOT@" in t:
            t = t.replace("@BUILD_ROOT@", "$(RULEDIR)")
        if "@PRIVATE_DIR@" in t:
            t = t.replace("@PRIVATE_DIR@", "$$PRIVATE")
            uses_private = True
        if "@DEPFILE@" in t:
            # meson's incremental-rebuild depfile. Bazel tracks inputs
            # explicitly, so the generator only needs a writable path; give it a
            # throwaway one.
            t = t.replace("@DEPFILE@", "$$DEPFILE")
            uses_depfile = True
        if "@SOURCE_ROOT@" in t:
            t = t.replace("@SOURCE_ROOT@", "$$SRCROOT")
            uses_srcroot = True
        if "@CURRENT_SOURCE_DIR@" in t:
            # The target's meson source dir: the directory holding its script
            # (snowball_create.pl reads snowball.sql.in from there).
            srcdir = scripts_full[0].rsplit("/", 1)[0] if scripts_full else ""
            t = t.replace("@CURRENT_SOURCE_DIR@", "$$SRCROOT/" + srcdir)
            uses_srcroot = True

        # A literal pass-through arg (no injected `$(...)` / `$$` expansion)
        # with shell metacharacters needs single-quoting, and any literal `$`
        # doubled so Bazel passes it through (text2macro.pl's `--strip` regex
        # anchor).
        if "$(" not in t and "$$" not in t and _needs_quoting(t):
            t = "'" + t.replace("$", "$$") + "'"
        args.append(t)

    # pgflex chdir's into its private dir, so every exported env path must be
    # absolute; anchor them at the execroot (the action's cwd at start).
    prologue = ['EXECROOT="$$(pwd)"']
    if uses_srcroot:
        # Recover the overlay source root from a staged file's execpath by
        # stripping its known overlay-relative suffix (the `$(execpath ...)`
        # uses the resolved label; the suffix stripped is the overlay-relative
        # path, so this holds whatever package the genrule renders in). Prefer a
        # real source; fall back to the generator script (create_help.pl reads
        # its inputs from @SOURCE_ROOT@ and lists no `sources`).
        anchor_lbl = (sources + scripts)[0]
        anchor_full = (sources_full + scripts_full)[0]
        prologue.append('SRCROOT="$(execpath %s)"' % anchor_lbl)
        prologue.append('SRCROOT="$${SRCROOT%%/%s}"' % anchor_full)
    if uses_outdir:
        out_dir = "$(RULEDIR)/" + outdir_sub if outdir_sub else "$(RULEDIR)"
        prologue.append('OUTDIR="%s"' % out_dir)
        prologue.append('mkdir -p "$$OUTDIR"')
    if uses_private:
        prologue.append('PRIVATE="$$(mktemp -d)"')
    if uses_depfile:
        prologue.append('DEPFILE="$$(mktemp)"')

    tool_inputs = list(used.keys())
    toolchains = []
    extra = list(_CODEGEN_EXTRA_SRCS.get(target["name"], []))

    # The perl interpreter (lead, or invoked by pgflex via --perl) needs its
    # @INC modules and NEEDED libs from @perl_sysroot, which the hermetic
    # sandbox does not materialize from runfiles; name the tree as a direct
    # input and export the loader/@INC env.
    if _PERL_BIN in used:
        tool_inputs.append(_PERL_SYSROOT)
        toolchains.append(_PERL_TOOLCHAIN)
        prologue.extend(_perl_env_prologue())

    # bison and flex are dynamically linked against @libc_sysroot and shell out
    # to m4; stage that sysroot (via the toolchains make-var dep, which forwards
    # its files), point the loader at it, and point them at the hermetic m4.
    if _BISON_BIN in used or _FLEX_BIN in used:
        tool_inputs.append(_M4_BIN)
        toolchains.append(_LIBC_EXEC_DIR)
        prologue.append(
            ('export LD_LIBRARY_PATH="%s' +
             '$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"') % ":".join([
                "$$EXECROOT/$(LIBC_SYSROOT_EXEC_DIR)/lib/$(LIBC_SYSROOT_EXEC_MULTIARCH)",
                "$$EXECROOT/$(LIBC_SYSROOT_EXEC_DIR)/usr/lib/$(LIBC_SYSROOT_EXEC_MULTIARCH)",
            ]),
        )
        prologue.append('export M4="$$EXECROOT/$(execpath %s)"' % _M4_BIN)

    # The pgflex wrapper runs under the hermetic python: stage its stdlib and
    # point PYTHONHOME at the staged interpreter root (the binary's baked-in
    # prefix does not exist in the sandbox). pgflex also runs
    # fix-old-flex-code.pl off --srcdir, so stage that script.
    if _PYTHON_BIN in used:
        tool_inputs.append(_PYTHON_FILES)
        prologue.append(
            ('export PYTHONHOME="$$EXECROOT/' +
             '$$(dirname $$(dirname $(execpath %s)))"') % _PYTHON_BIN,
        )
    if _FLEX_BIN in used:
        extra.append(_FLEX_FIX_SCRIPT)

    cmd_line = "%s %s" % (lead_cmd, " ".join(args))
    if not saw_output:
        cmd_line += " > $(execpath %s)" % out0
    cmd = "\n".join(prologue + [cmd_line]) + "\n"

    # An extra-input glob under this genrule's package stays a local glob (made
    # package-relative); one under a non-package directory is staged by a root
    # filegroup (recorded in `needs`). `explicit` srcs already covered by a
    # local glob are dropped to avoid duplicate labels.
    local_globs = []
    fg_labels = []
    for pat in extra:
        owner = longest_pkg_prefix(packages, _pattern_base(pat))
        if owner == home:
            local_globs.append(pat[len(home) + 1:] if home else pat)
        else:
            rel = pat[len(owner) + 1:] if owner else pat
            fg = _fg_name(rel)
            needs.setdefault(owner, {})[fg] = rel
            fg_labels.append(("//%s:%s" % (owner, fg)) if owner else "//:" + fg)

    # `sources`/`scripts` (labels) run parallel to `sources_full`/`scripts_full`
    # (overlay paths); dedup by label and drop any already covered by an extra
    # glob (matched on the overlay path).
    all_lbls = sources + scripts
    all_fulls = sources_full + scripts_full
    explicit = []
    seen = {}
    for i in range(len(all_lbls)):
        lbl = all_lbls[i]
        if lbl in seen:
            continue
        seen[lbl] = True
        if not _covered(all_fulls[i], extra):
            explicit.append(lbl)

    node = Star.igen(Star.fn(
        "genrule",
        name = _genrule_name(out0),
        srcs = _srcs_node(sorted(explicit) + sorted(fg_labels), local_globs),
        outs = sorted(outs),
        cmd = Star.tstr(cmd),
        tools = sorted(dedup(tool_inputs)),
        toolchains = toolchains,
    ))
    return home, node, outs_full

def render_config_info_vals(params, packages):
    """Render config_info_vals.h: the native VAL_* build strings pg_config reports.

    config_info.c expects the VAL_* macros as -D string-literal defines. meson's
    are sanitized and non-portable, and a -D value with embedded spaces does not
    survive clang's response-file parser, so compute the native values and emit
    them as a force-included header (where the C string literals need no
    escaping): VAL_CC -> the conventional `cc` (the build wrapper path is not
    meaningful post-install); VAL_CFLAGS / VAL_LDFLAGS reconciled by
    reconcile_build_flags; the rest verbatim (already portable). The header
    lands under src/common (force-included into the config_info libs via
    -Isrc/common), so the genrule renders in that package when the split is
    active.

    Args:
        params: a config_info lib's introspect `parameters` (carrying -DVAL_*).
        packages: the active overlay package set.

    Returns:
        A (home_pkg, genrule_node, header_path) tuple; header_path is the
        overlay-relative output (for pg_generated_headers).
    """
    home = longest_pkg_prefix(packages, _CONFIG_INFO_VALS_H.rsplit("/", 1)[0])
    raw = {}
    for p in params:
        if not p.startswith("-DVAL_"):
            continue
        kv = p[len("-D"):].split("=", 1)
        value = kv[1] if len(kv) > 1 else ""
        if value.startswith("\"") and value.endswith("\""):
            value = value[1:-1]
        raw[kv[0]] = value

    lines = []
    for name in _VAL_DEFINES:
        v = raw.get(name, "")
        if name == "VAL_CC":
            v = "cc"
        elif name == "VAL_CFLAGS" or name == "VAL_LDFLAGS":
            v = reconcile_build_flags(v)
        lines.append('#define %s "%s"' % (name, v))

    cmd = "cat > $@ <<'PG_CONFIG_VALS'\n" + "\n".join(
        lines,
    ) + "\nPG_CONFIG_VALS\n"
    node = Star.igen(Star.fn(
        "genrule",
        name = "config_info_vals",
        outs = [gen_label(packages, _CONFIG_INFO_VALS_H, home)],
        cmd = Star.tstr(cmd),
    ))
    return home, node, _CONFIG_INFO_VALS_H
