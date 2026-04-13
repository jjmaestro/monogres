package Config_overrides;
use strict;
use Config;

# `%Config` shim loaded into @perl_sysroot's perl via `PERL5OPT='-MConfig_overrides'`.
#
# Postgres meson's plperl detection reads `$Config{archlibexp}` (for the
# libperl link path), `$Config{privlibexp}` (for the `ExtUtils/typemap`
# location used by `xsubpp`), `$Config{useshrplib}`, and `$Config{libperl}`.
# @perl_sysroot is a Debian perl-base install so `useshrplib='true'` and
# `libperl='libperl.so.5.36'` are already correct; the overrides for those
# are defensive no-ops.
#
# `archlib` / `archlibexp` get rewritten to the per-PG sysroot's libperl-dev
# `CORE/` parent dir (`PERL_DEBIAN_ARCHLIB` env var). `ExtUtils::Embed::ldopts`
# then emits `-L<per-PG sysroot>/usr/lib/<cpu>-linux-gnu/perl/5.36/CORE
# -lperl`, which resolves to the libperl.so symlinked into `CORE/` by
# `sysroot_setup.sh`.
#
# `privlib` / `privlibexp` get rewritten to @perl_sysroot's
# `usr/share/perl/5.36` (`PERL_SYSROOT_DIR` env var + suffix). plperl's
# `meson.build` derives the typemap path as `<privlibexp>/ExtUtils/typemap`;
# without this override, xsubpp gets handed Debian's compiled-in HOST path
# `/usr/share/perl/5.36/ExtUtils/typemap` which does NOT exist in the
# hermetic sandbox.
#
# The interpreter (@perl_sysroot's perl 5.36), the libperl.so + perl.h
# (per-PG sysroot's libperl-dev 5.36), and the runtime libperl.so.5.36
# (per-PG sysroot's libperl5.36) all share the same Debian snapshot, so
# the plperl extension lifecycle stays on a single perl 5.36 ABI track.

my $debian_archlib = $ENV{PERL_DEBIAN_ARCHLIB}
    or die "Config_overrides: PERL_DEBIAN_ARCHLIB env var must be set";

my $perl_sysroot = $ENV{PERL_SYSROOT_DIR}
    or die "Config_overrides: PERL_SYSROOT_DIR env var must be set";

# Perl MAJOR.MINOR from the running interpreter, so this shim tracks whatever
# Debian perl `@perl_sysroot` ships without a hardcoded version pin.
my ($perl_version) = $Config{version} =~ /^(\d+\.\d+)/;

my $perl_privlib = "$perl_sysroot/usr/share/perl/$perl_version";

# `%Config` is tied to a read-only hash via Config's XS layer; STORE silently
# discards writes. Replace the tied hash with a regular hash so the overrides
# stick across reads from anywhere in the perl process.
my %override = %Config;
$override{useshrplib} = 'true';
$override{libperl}    = "libperl.so.$perl_version";
$override{archlib}    = $debian_archlib;
$override{archlibexp} = $debian_archlib;
$override{privlib}    = $perl_privlib;
$override{privlibexp} = $perl_privlib;
untie %Config::Config;
%Config::Config = %override;

1;
