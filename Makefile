python := python3
snapcraft := SNAPCRAFT_BUILD_INFO=1 snapcraft -v

BIN_DIR := bin
VENV := .ve

# PPA used by MAAS dependencies. It can be overridden by the env.
#
# This uses an explicit empty check (rather than ?=) since Jenkins defines
# variables for parameters even when not passed.
ifeq ($(MAAS_PPA),)
	MAAS_PPA = ppa:maas-committers/latest-deps
endif

export PATH := $(PWD)/$(BIN_DIR):$(PATH)

# pkg_resources makes some incredible noise about version numbers. They
# are not indications of bugs in MAAS so we silence them everywhere.
export PYTHONWARNINGS = \
  ignore:You have iterated over the result:RuntimeWarning:pkg_resources:

# If offline has been selected, attempt to further block HTTP/HTTPS
# activity by setting bogus proxies in the environment.
ifneq ($(offline),)
export http_proxy := broken
export https_proxy := broken
endif

# Prefix commands with this when they need access to the database.
# Remember to add a dependency on bin/database from the targets in
# which those commands appear.
dbrun := bin/database --preserve run --

# Default PostgreSQL tools to use the maas database
export PGDATABASE := maas

.DEFAULT_GOAL := build

define BIN_SCRIPTS
bin/maas \
bin/maas-apiserver \
bin/maas-common \
bin/maas-power \
bin/maas-rack \
bin/maas-region \
bin/maas-sampledata \
bin/postgresfixture \
bin/pytest \
bin/rackd \
bin/regiond \
bin/subunit-1to2 \
bin/subunit2junitxml \
bin/subunit2pyunit \
bin/test.parallel \
bin/test.rack \
bin/test.region \
bin/test.region.legacy
endef

UI_BUILD := src/maasui/build

OFFLINE_DOCS := src/maas-offline-docs/src

swagger-dist := src/maasserver/templates/dist/
swagger-js: file := src/maasserver/templates/dist/swagger-ui-bundle.js
swagger-js: url := "https://unpkg.com/swagger-ui-dist@latest/swagger-ui-bundle.js"
swagger-css: file := src/maasserver/templates/dist/swagger-ui.css
swagger-css: url := "https://unpkg.com/swagger-ui-dist@latest/swagger-ui.css"

build: \
  $(VENV) \
  $(BIN_SCRIPTS) \
  bin/py
.PHONY: build

all: build ui go-bins doc
.PHONY: all

# Install all packages required for MAAS development & operation on
# the system. This may prompt for a password.
install-dependencies: required_deps_files := base dev
# list package names from a required-packages/ file
install-dependencies: list_packages = $(shell sort -u required-packages/$1 | sed '/^\#/d')
install-dependencies: apt := sudo DEBIAN_FRONTEND=noninteractive apt -y
install-dependencies: apt_install := $(apt) install --no-install-recommends
install-dependencies:
	$(apt_install) software-properties-common gpg-agent
ifneq ($(MAAS_PPA),)
	sudo apt-add-repository -y $(MAAS_PPA)
endif
	$(apt) build-dep .
	$(apt_install) $(foreach deps,$(required_deps_files),$(call list_packages,$(deps)))
	$(apt) purge $(call list_packages,forbidden)
	if [ -x /usr/bin/snap ]; then xargs -L1 sudo snap install < required-packages/snaps; fi
.PHONY: install-dependencies

$(VENV):
	python3 -m venv --system-site-packages --clear $@
	$(VENV)/bin/pip install -e .[testing]

bin:
	mkdir $@

$(BIN_SCRIPTS): $(VENV) bin
	ln -sf ../$(VENV)/$@ $@

bin/py: $(VENV) bin
	ln -sf ../$(VENV)/bin/ipython3 $@

bin/database: bin/postgresfixture
	ln -sf $(notdir $<) $@

ui: $(UI_BUILD)
.PHONY: ui

$(UI_BUILD):
	$(MAKE) -C src/maasui build

$(OFFLINE_DOCS):
	$(MAKE) -C src/maas-offline-docs

$(swagger-dist):
	mkdir $@

swagger-js: $(swagger-dist)
	wget -O $(file) $(url)
.PHONY: swagger-js

swagger-css: $(swagger-dist)
	wget -O $(file) $(url)
.PHONY: swagger-css

go-bins:
	$(MAKE) -j -C src/host-info build
	$(MAKE) -j -C src/maasagent build
.PHONY: go-bins

test: test-missing-migrations test-py lint-oapi test-go
.PHONY: test

test-missing-migrations: bin/database bin/maas-region
	$(dbrun) bin/maas-region makemigrations --check --dry-run
.PHONY: test-missing-migrations

test-py: bin/test.parallel bin/subunit-1to2 bin/subunit2junitxml bin/subunit2pyunit bin/pytest
	@utilities/run-py-tests-ci
.PHONY: test-py

test-go:
	@find src -maxdepth 3 -type f -name go.mod -execdir sh -c "make test" {} +
.PHONY: test-go

test-perf: bin/pytest
	GIT_BRANCH=$(shell git rev-parse --abbrev-ref HEAD) \
	GIT_HASH=$(shell git rev-parse HEAD) \
	bin/pytest src/perftests
.PHONY: test-perf

test-perf-quiet: bin/pytest
	GIT_BRANCH=$(shell git rev-parse --abbrev-ref HEAD) \
	GIT_HASH=$(shell git rev-parse HEAD) \
	bin/pytest -q --disable-warnings --show-capture=no --no-header --no-summary src/perftests
.PHONY: test-perf-quiet

update-initial-sql: bin/database bin/maas-region cleandb
	$(dbrun) utilities/update-initial-sql src/maasserver/testing/initial.maas_test.sql
.PHONY: update-initial-sql

lint: lint-py lint-py-imports lint-py-linefeeds lint-go lint-shell
.PHONY: lint

lint-py:
	@tox -e lint
.PHONY: lint-py

lint-py-imports:
	@utilities/check-imports
.PHONY: lint-py-imports

# Only Unix line ends should be accepted
lint-py-linefeeds:
	@find src/ -name \*.py -exec file "{}" ";" | \
		awk '/CRLF/ { print $0; count++ } END {exit count}' || \
		(echo "Lint check failed; run make format to fix DOS linefeeds."; false)
.PHONY: lint-py-linefeeds

# Open API Spec
lint-oapi: openapi.yaml
	@tox -e oapi
.PHONY: lint-oapi

# Go fmt
lint-go: $(BIN_DIR)/golangci-lint
	@find src -maxdepth 3 -type f -name go.mod -execdir \
		sh -c "golangci-lint run $(if $(LINT_AUTOFIX),--fix,) ./..." {} +
.PHONY: lint-go

lint-go-fix: LINT_AUTOFIX=true
lint-go-fix: lint-go
.PHONY: lint-go-fix

lint-shell:
	@shellcheck -x \
		package-files/usr/lib/maas/beacon-monitor \
		package-files/usr/lib/maas/unverified-ssh \
		snap/hooks/* \
		snap/local/tree/bin/* \
		src/metadataserver/builtin_scripts/commissioning_scripts/maas-get-fruid-api-data \
		src/metadataserver/builtin_scripts/commissioning_scripts/maas-kernel-cmdline \
		src/provisioningserver/refresh/20-maas-03-machine-resources \
		src/provisioningserver/refresh/maas-list-modaliases \
		src/provisioningserver/refresh/maas-lshw \
		src/provisioningserver/refresh/maas-serial-ports \
		src/provisioningserver/refresh/maas-support-info \
		utilities/build_custom_ubuntu_image \
		utilities/build_custom_ubuntu_image_no_kernel \
		utilities/configure-vault \
		utilities/connect-snap-interfaces \
		utilities/gen-db-schema-svg \
		utilities/ldap-setup \
		utilities/maas-lxd-environment \
		utilities/package-version \
		utilities/run-perf-tests-ci \
		utilities/run-performanced \
		utilities/run-py-tests-ci \
		utilities/schemaspy \
		utilities/update-initial-sql
.PHONY: lint-shell

format.parallel:
	@$(MAKE) -s -j format
.PHONY: format.parallel

# Apply automated formatting to all Python, Sass and Javascript files.
format: format-py format-go
.PHONY: format

format-py:
	@tox -e format
.PHONY: format-py

format-go:
	@$(MAKE) -C src/host-info format
.PHONY: format-go

check: clean test
.PHONY: check

api-docs.rst: bin/maas-region src/maasserver/api/doc_handler.py syncdb
	bin/maas-region generate_api_doc > $@

openapi.yaml: bin/maas-region src/maasserver/api/doc_handler.py syncdb
	bin/maas-region generate_oapi_spec > $@

doc: api-docs.rst openapi.yaml swagger-css swagger-js
.PHONY: doc

clean-ui:
	$(MAKE) -C src/maasui clean
.PHONY: clean-ui

clean-ui-build:
	$(MAKE) -C src/maasui clean-build
.PHONY: clean-build

clean-go-bins:
	$(MAKE) -C src/host-info clean
	$(MAKE) -C src/maasagent clean
.PHONY: clean-go-bins

clean: clean-ui clean-go-bins
	find . -type f -name '*.py[co]' -print0 | xargs -r0 $(RM)
	find . -type d -name '__pycache__' -print0 | xargs -r0 $(RM) -r
	find . -type f -name '*~' -print0 | xargs -r0 $(RM)
	$(RM) src/maasserver/data/templates.py
	$(RM) *.log
	$(RM) api-docs.rst
	$(RM) -r .hypothesis
	$(RM) -r bin include lib local
	$(RM) -r eggs develop-eggs
	$(RM) -r build dist logs/* parts
	$(RM) tags TAGS .installed.cfg
	$(RM) -r *.egg *.egg-info src/*.egg-info
	$(RM) -r .run
	$(RM) junit*.xml
	$(RM) xunit.*.xml
	$(RM) .noseids
	$(RM) .failed
	$(RM) -r $(VENV)
	$(RM) -r .tox
.PHONY: clean

#
# Local database
#

dbshell: bin/database
	bin/database --preserve shell
.PHONY: dbshell

syncdb: bin/maas-region bin/database
	$(dbrun) bin/maas-region dbupgrade $(DBUPGRADE_ARGS)
.PHONY: syncdb

dumpdb: DB_DUMP ?= maasdb.dump
dumpdb: bin/database
	$(dbrun) pg_dump $(PGDATABASE) --format=custom -f $(DB_DUMP)
.PHONY: dumpdb

cleandb:
	while fuser db --kill -TERM; do sleep 1; done
	$(RM) -r db
	$(RM) .db.lock
.PHONY: cleandb

sampledata: SAMPLEDATA_MACHINES ?= 100
sampledata: syncdb bin/maas-sampledata
	$(dbrun) bin/maas-sampledata --machine $(SAMPLEDATA_MACHINES)
.PHONY: sampledata

#
# deb packages building
#

packaging-build-area := $(abspath ../build-area)
packaging-version := $(shell utilities/package-version)
packaging-dir := maas_$(packaging-version)
packaging-orig-tar := $(packaging-dir).orig.tar
packaging-orig-targz := $(packaging-dir).orig.tar.gz

$(packaging-build-area):
	mkdir -p $@

-packaging-clean:
	rm -rf $(packaging-build-area)
.PHONY: -packaging-clean

-packaging-export-tree:
ifeq ($(packaging-export-uncommitted),true)
	git ls-files --others --exclude-standard --cached | grep -v '^debian' | \
		xargs tar --transform 's,^,$(packaging-dir)/,' \
			-cf $(packaging-build-area)/$(packaging-orig-tar)
else
	git archive --format=tar $(packaging-export-extra) \
		--prefix=$(packaging-dir)/ \
		-o $(packaging-build-area)/$(packaging-orig-tar) HEAD
endif
.PHONY: -packaging-export-tree

-packaging-tarball:
	tar -rf $(packaging-build-area)/$(packaging-orig-tar) $(UI_BUILD) $(OFFLINE_DOCS) \
		--transform 's,^,$(packaging-dir)/,'
	$(MAKE) -C src/host-info vendor
	tar -rf $(packaging-build-area)/$(packaging-orig-tar) src/host-info/vendor \
		--transform 's,^,$(packaging-dir)/,'
	$(MAKE) -C src/maasagent vendor
	tar -rf $(packaging-build-area)/$(packaging-orig-tar) src/maasagent/vendor \
		--transform 's,^,$(packaging-dir)/,'
	gzip -f $(packaging-build-area)/$(packaging-orig-tar)
.PHONY: -packaging-tarball

-package-tree: changelog := $(packaging-build-area)/$(packaging-dir)/debian/changelog
-package-tree: $(UI_BUILD) $(OFFLINE_DOCS) $(packaging-build-area) -packaging-export-tree -packaging-tarball
	(cd $(packaging-build-area) && tar xfz $(packaging-orig-targz))
	cp -r debian $(packaging-build-area)/$(packaging-dir)
	echo "maas (1:$(packaging-version)-0ubuntu1) UNRELEASED; urgency=medium" \
		> $(changelog)
	tail -n +2 debian/changelog >> $(changelog)
.PHONY: -package-tree

package-tree: -packaging-clean -package-tree

package: package-tree
	(cd $(packaging-build-area)/$(packaging-dir) && debuild -uc -us)
	@echo Binary packages built, see $(packaging-build-area).
.PHONY: package

package-dev:
	$(MAKE) packaging-export-uncommitted=true package
.PHONY: package-dev

package-clean: patterns := *.deb *.udeb *.dsc *.build *.changes
package-clean: patterns += *.debian.tar.xz *.orig.tar.gz
package-clean:
	$(RM) -f $(addprefix $(packaging-build-area)/,$(patterns))
.PHONY: package-clean

#
# Snap building
#

snap-clean:
	$(snapcraft) clean
.PHONY: snap-clean

snap:
	$(snapcraft)
.PHONY: snap

SNAP_DEV_DIR = dev-snap
SNAP_UNPACKED_DIR = $(SNAP_DEV_DIR)/tree
SNAP_UNPACKED_DIR_MARKER = $(SNAP_DEV_DIR)/tree.marker
SNAP_FILE = $(SNAP_DEV_DIR)/maas.snap

snap-tree: $(SNAP_UNPACKED_DIR_MARKER)
.PHONY: snap-tree

snap-tree-clean:
	rm -rf $(SNAP_DEV_DIR)
.PHONY: snap-tree-clean

$(SNAP_UNPACKED_DIR_MARKER): $(SNAP_FILE)
	mkdir -p $(SNAP_DEV_DIR)
	unsquashfs -f -d $(SNAP_UNPACKED_DIR) $^
	touch $@

$(SNAP_FILE):
	$(snapcraft) -o $(SNAP_FILE)

snap-tree-sync: RSYNC := rsync -v -r -u -l -t -W -L
snap-tree-sync: $(UI_BUILD) go-bins $(SNAP_UNPACKED_DIR_MARKER)
	$(RSYNC) --exclude 'maastesting' --exclude 'tests' --exclude 'testing' \
		--exclude 'maasui' --exclude 'maasagent' --exclude 'machine-resources' \
		--exclude 'host-info' --exclude 'maas-offline-docs' \
		--exclude '*.pyc' --exclude '__pycache__' \
		src/ \
		$(SNAP_UNPACKED_DIR)/lib/python3.10/site-packages/
	$(RSYNC) \
		$(UI_BUILD)/ \
		$(SNAP_UNPACKED_DIR)/usr/share/maas/web/static/
	$(RSYNC) \
		$(OFFLINE_DOCS)/production-html-snap/ \
		$(SNAP_UNPACKED_DIR)/usr/share/maas/web/static/docs/
	$(RSYNC) \
		snap/local/tree/ \
		$(SNAP_UNPACKED_DIR)/
	$(RSYNC) \
		src/host-info/bin/ \
		$(SNAP_UNPACKED_DIR)/usr/share/maas/machine-resources/
	$(RSYNC) \
		src/maasagent/build/ \
		$(SNAP_UNPACKED_DIR)/usr/sbin/
.PHONY: snap-tree-sync

$(BIN_DIR)/golangci-lint: GOLANGCI_VERSION=1.53.1
$(BIN_DIR)/golangci-lint: utilities/get_golangci-lint | $(BIN_DIR)
	GOBIN="$(realpath $(dir $@))"
	sh utilities/get_golangci-lint "v$(GOLANGCI_VERSION)"
	touch $@
