PROJECT_NAME := monogres
REPO := $(abspath $(lastword $(MAKEFILE_LIST))/../..)

DOCKER := $(shell command -v docker || which docker)

ifndef DOCKER
$(error Can't find docker)
endif

DOCKERFILE := debian
BASE_NAME := debian
TARGET ?= rbe
DOCKER_TARGET := $(if $(TARGET),$(BASE_NAME)-$(TARGET),$(BASE_NAME))
DOCKER_TARGET_LOCK := .$(DOCKER_TARGET).lock
IMAGE_NAME := $(PROJECT_NAME)/$(DOCKER_TARGET)

REGISTRY := ghcr.io
GH_ORG := monogres
GH_REPO_URL := https://github.com/$(GH_ORG)/$(PROJECT_NAME)
TAG := $(REGISTRY)/$(GH_ORG)/$(IMAGE_NAME):latest

ARCH ?= $(shell uname -m)
USERNAME = postgres

BUILD_PLATFORMS ?= "linux/amd64,linux/arm64"
USE_CACHE ?= false

BASE_IMAGE=debian
# https://hub.docker.com/_/debian/tags
BASE_IMAGE_TAG=stable-20250113-slim
# https://github.com/bazelbuild/bazel
BAZEL_VERSION := $(shell cat $(REPO)/.bazelversion 2>/dev/null || echo 8.4.2)
# https://github.com/reproducible-containers/repro-sources-list.sh
REPRODUCIBLE_CONTAINERS_VERSION ?= 0.1.4
# https://github.com/bazelbuild/bazelisk
BAZELISK_VERSION ?= 1.27.0

DEPS_CC_TOOLCHAIN = \
	clang-14 \
	libc++-14-dev \
	libc++abi-14-dev \
	libc6-dev \
	libclang-rt-14-dev \
	libunwind-14-dev \
	lld-14 \
	llvm-14 \
	llvm-14-dev

# rules_distroless: xz-utils
DEPS_NON_HERMETIC_BAZEL_RULES = \
	xz-utils

DOCKER_BUILD_ARGS = \
	--platform "$(BUILD_PLATFORMS)" \
	--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
	--build-arg BASE_IMAGE_TAG="$(BASE_IMAGE_TAG)" \
	--build-arg REPRODUCIBLE_CONTAINERS_VERSION="$(REPRODUCIBLE_CONTAINERS_VERSION)" \
	--build-arg BAZELISK_VERSION="$(BAZELISK_VERSION)" \
	--build-arg BAZEL_VERSION="$(BAZEL_VERSION)" \
	--build-arg DEPS_CC_TOOLCHAIN="$(DEPS_CC_TOOLCHAIN)" \
	--build-arg DEPS_NON_HERMETIC_BAZEL_RULES="$(DEPS_NON_HERMETIC_BAZEL_RULES)" \
	--build-arg USERNAME="$(USERNAME)" \
	--build-arg HOMEDIR="/$(USERNAME)" \
	--label org.opencontainers.image.source="$(GH_REPO_URL)" \
	--target "$(DOCKER_TARGET)" \
	--tag "$(IMAGE_NAME)"

ifneq ($(USE_CACHE),false)
CACHE_MOUNTS := --mount type=volume,src=bazel-cache,dst=/cache

# initialize cache volume and symlink into $HOME
CACHE_SETUP_SCRIPT := \
	mkdir -p /cache/bazel-cache; \
	if [ ! -f /cache/.seeded ]; then \
		cp -a /$(USERNAME)/.cache/. /cache/bazel-cache/.; \
		touch /cache/.seeded; \
	fi; \
	rm -rf /$(USERNAME)/.cache; \
	ln -sf /cache/bazel-cache /$(USERNAME)/.cache; \
	touch /cache/bash_history; \
	ln -sf /cache/bash_history /$(USERNAME)/.bash_history; \
	touch /cache/bazelrc; \
	ln -sf /cache/bazelrc /$(USERNAME)/.bazelrc; \
	chown -R $(USERNAME) /cache;
else
CACHE_MOUNTS :=
CACHE_SETUP_SCRIPT :=
endif

# The container starts as root (--user root) so the entrypoint can run the
# cache setup. It then drops privileges to $(USERNAME) via setpriv.
#
# NOTE: HOME must be set explicitly because the container starts as root,
# so HOME defaults to /root. Without this, bash sources /root/.bashrc which
# the non-root user can't read. Setting HOME to the user's actual home dir
# (e.g. /postgres) fixes .bashrc, .cache, and other dotfile lookups.
#
# NOTE: Docker must run WITHOUT rootless mode and WITHOUT userns-remap, so
# that host UIDs map 1:1 to container UIDs. The host user's GID is passed
# via HOST_GID and added to the supplementary groups, ensuring the container
# user can access bind-mounted files owned by the host user's group.
ENTRYPOINT_SCRIPT := \
	set -xeuo pipefail; \
	$(CACHE_SETUP_SCRIPT) \
	USER_UID=$$(getent passwd $(USERNAME) | cut -d: -f3); \
	USER_GID=$$(getent passwd $(USERNAME) | cut -d: -f4); \
	export HOME=$$(getent passwd $(USERNAME) | cut -d: -f6); \
	exec setpriv \
		--reuid=$$USER_UID \
		--regid=$$USER_GID \
		--groups=$$USER_GID,0,$$HOST_GID \
		-- /bin/bash

all:
	@echo $(REPO)
	@echo "Run make gen-image to generate $(TARGET) image and "
	@echo "make gen-image TARGET=debug to make the debug image "
	@echo "(it will build all the rest since debug depends on "
	@echo "all of the previous images)"

.PHONY: all

run-image:
	# NOTE:
    # MUST RUN --privileged so that Bazel --experimental_use_hermetic_linux_sandbox works!
    # OTHERWISE IT JUST SILENTLY CONTINUES WITHOUT HERMETIC SANDBOX!!?
	$(DOCKER) run \
		--platform "linux/$(ARCH)" \
		--name "sandbox_$(PROJECT_NAME)_$(ARCH)" \
		--privileged \
		--rm \
		--tty \
		--interactive \
		--user "root" \
		--group-add root \
		--group-add "$(shell id -g)" \
		--env HOST_GID="$(shell id -g)" \
		--volume "$(REPO)":/src/repo:ro \
		--volume "$(REPO)":/src/workspace:rw \
		--volume "$(REPO)/../.git":/src/.git:ro \
		$(CACHE_MOUNTS) \
		--workdir /src/workspace \
		--entrypoint /bin/bash \
		$(TAG) \
		-c '$(ENTRYPOINT_SCRIPT)'

.PHONY: run-image

gen-image: $(DOCKER_TARGET_LOCK)

.PHONY: gen-image

$(DOCKER_TARGET_LOCK): Dockerfile.$(DOCKERFILE) $(MAKEFILE_LIST) $(REPO)/.bazelversion
	$(DOCKER) build --file "$<" $(DOCKER_BUILD_ARGS) . && \
	$(DOCKER) image tag $(IMAGE_NAME) $(TAG) && \
	touch "$@"

# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
# https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
# https://docs.github.com/en/packages/learn-github-packages/connecting-a-repository-to-a-package
push-image: gen-image
	echo "\n\nEnter a GH Personal Access Token with (at least) write:packages scope:\n\n" && \
	$(DOCKER) login --username $(USER) $(REGISTRY)  && \
	$(DOCKER) push $(TAG)

.PHONY: push-image

pull-image:
	@echo "\n\nEnter a GH Personal Access Token with (at least) read:packages scope:\n\n" && \
	$(DOCKER) login --username $(USER) $(REGISTRY)  && \
	$(DOCKER) pull $(TAG)

.PHONY: pull-image

test:
	@echo "No tests — run project-level tests instead"

.PHONY: test

clean:
	rm -f .*.lock

.PHONY: clean
