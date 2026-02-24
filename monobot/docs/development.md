# Development

Monobot is built with [Quarkus](https://quarkus.io/) and requires Java 21+.

## Prerequisites

- Java 21 (e.g., [Azul Zulu](https://www.azul.com/downloads/))
- Maven

## Dev Mode

Run the application in dev mode with live reload:

```sh
configDir=/path/to/config \
workdir=/tmp/monobot \
monogresRepo=/path/to/monogres \
  mvn quarkus:dev
```

## Packaging

Build the application:

```sh
mvn package
```

This produces `target/quarkus-app/quarkus-run.jar` (not an uber-jar;
dependencies are in `target/quarkus-app/lib/`).

Run it:

```sh
java -jar target/quarkus-app/quarkus-run.jar
```

To build an uber-jar instead:

```sh
mvn package -Dquarkus.package.jar.type=uber-jar
java -jar target/*-runner.jar
```

## Native Executable

Build a native executable with GraalVM:

```sh
mvn package -Dnative
./target/monobot-1.0.0-SNAPSHOT-runner
```

Or build in a container (no local GraalVM needed):

```sh
mvn package -Dnative -Dquarkus.native.container-build=true
```

See the [Quarkus Maven tooling guide](https://quarkus.io/guides/maven-tooling)
for more details.
