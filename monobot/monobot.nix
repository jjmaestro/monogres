{ pkgs }:
let
  # The JDK major is declared once, in pom.xml's maven.compiler.release, and
  # read back here so this shell cannot put a JDK on PATH other than the one
  # the build targets. maven-enforcer-plugin asserts the same property from the
  # maven side, covering builds that run outside this shell.
  javaRelease =
    let
      lines = builtins.filter builtins.isString
        (builtins.split "\n" (builtins.readFile ./pom.xml));
      hits = builtins.filter (m: m != null) (map
        (l: builtins.match
          "[[:space:]]*<maven\\.compiler\\.release>([0-9]+)</maven\\.compiler\\.release>[[:space:]]*"
          l)
        lines);
    in
    if builtins.length hits == 1 then
      builtins.head (builtins.head hits)
    else
      throw ("monobot.nix: expected one maven.compiler.release in pom.xml, found "
        + toString (builtins.length hits));

  jdk = pkgs."jdk${javaRelease}";

  # mvnd ships a complete Maven under mvnd-home/mvn. Taking `mvn` from there
  # rather than from pkgs.maven leaves exactly one Maven in the project, so a
  # goal cannot behave differently depending on whether the daemon or the plain
  # client ran it. It picks the JDK up from JAVA_HOME, set below.
  maven = pkgs.runCommand "maven-from-mvnd" { } ''
    test -x ${pkgs.mvnd}/mvnd-home/mvn/bin/mvn \
      || { echo "mvnd no longer bundles maven at mvnd-home/mvn" >&2; exit 1; }
    mkdir -p $out/bin
    ln -s ${pkgs.mvnd}/mvnd-home/mvn/bin/mvn $out/bin/mvn
  '';
in
if !builtins.pathExists ./pom.xml then
  {
    packages = [ ];
    env = { };
  }
else
  {
    # Maven drives everything monobot: the Quarkus build and run, plus the
    # spotless formatter and checkstyle linter the pre-commit hooks call.
    #
    # We use mvnd rather than mvn for performance. OpenRewrite spends its time
    # building a type-attributed model of the module, which is compute the JIT
    # needs to warm up for; a fresh JVM per hook run never gets there. Reusing
    # the daemon's warm JVM reduces the execution time from ~15-20s to ~5s.
    packages = [
      jdk
      maven
      pkgs.mvnd
    ];

    env = {
      JAVA_HOME = "${jdk}";
    };
  }
