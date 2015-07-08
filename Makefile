# Copyright 2014 The Cockroach Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License. See the AUTHORS file
# for names of contributors.
#
# Author: Andrew Bonventre (andybons@gmail.com)
# Author: Shawn Morel (shawnmorel@gmail.com)
# Author: Spencer Kimball (spencer.kimball@gmail.com)

# Cockroach build rules.
GO ?= go
# Allow setting of go build flags from the command line.
GOFLAGS :=
# Set to 1 to use static linking for all builds (including tests).
STATIC :=
# The cockroach image to be used for starting Docker containers
# during acceptance tests. Usually cockroachdb/cockroach{,-dev}
# depending on the context.
COCKROACH_IMAGE :=

RUN := run

# Variables to be overridden on the command line, e.g.
#   make test PKG=./storage TESTFLAGS=--vmodule=multiraft=1
PKG          := ./...
TAGS         :=
TESTS        := ".*"
TESTTIMEOUT  := 30s
CPUS         := 1
RACETIMEOUT  := 5m
BENCHTIMEOUT := 5m
TESTFLAGS    :=

ifeq ($(STATIC),1)
# The netgo build tag instructs the net package to try to build a
# Go-only resolver.
TAGS += netgo
# The installsuffix makes sure we actually get the netgo build, see
# https://github.com/golang/go/issues/9369#issuecomment-69864440
GOFLAGS += -installsuffix netgo
LDFLAGS += -extldflags "-static"
endif

.PHONY: all
all: build test

# On a release build, rebuild everything (except stdlib)
# to make sure that the 'release' build tag is taken
# into account.
.PHONY: release
release: TAGS += release
release: GOFLAGS += -a
release: build

.PHONY: build
build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTag "$(shell git describe --dirty)"
build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTime "$(shell date -u '+%Y/%m/%d %H:%M:%S')"
build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildDeps "$(shell GOPATH=${GOPATH} build/depvers.sh)"
build:
	$(GO) build -tags '$(TAGS)' $(GOFLAGS) -ldflags '$(LDFLAGS)' -v -i -o cockroach

.PHONY: install
install: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTag "$(shell git describe --dirty)"
install: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTime "$(shell date -u '+%Y/%m/%d %H:%M:%S')"
install: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildDeps "$(shell GOPATH=${GOPATH} build/depvers.sh)"
install:
	$(GO) install -tags '$(TAGS)' $(GOFLAGS) -ldflags '$(LDFLAGS)' -v

# Similar to "testrace", we want to cache the build before running the
# tests.
.PHONY: test
test:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -run $(TESTS) -cpu $(CPUS) $(PKG) -timeout $(TESTTIMEOUT) $(TESTFLAGS)

.PHONY: testslow
testslow: TESTFLAGS += -v
testslow:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -run $(TESTS) -cpu $(CPUS) $(PKG) -timeout $(TESTTIMEOUT) $(TESTFLAGS) | grep -F ': Test' | sed -E 's/(--- PASS: |\(|\))//g' | awk '{ print $$2, $$1 }' | sort -rn | head -n 10

.PHONY: testraceslow
testraceslow: TESTFLAGS += -v
testraceslow:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -race -run $(TESTS) -cpu $(CPUS) $(PKG) -timeout $(RACETIMEOUT) $(TESTFLAGS) | grep -F ': Test' | sed -E 's/(--- PASS: |\(|\))//g' | awk '{ print $$2, $$1 }' | sort -rn | head -n 10

# "go test -i" builds dependencies and installs them into GOPATH/pkg, but does not run the
# tests. Run it as a part of "testrace" since race-enabled builds are not covered by
# "make build", and so they would be built from scratch every time (including the
# slow-to-compile cgo packages).
.PHONY: testrace
testrace:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -race -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -race -run $(TESTS) -cpu $(CPUS) $(PKG) -timeout $(RACETIMEOUT) $(TESTFLAGS)

.PHONY: bench
bench:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -run $(TESTS) -cpu $(CPUS) -bench $(TESTS) $(PKG) -timeout $(BENCHTIMEOUT) $(TESTFLAGS)

.PHONY: coverage
coverage:
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -i $(PKG)
	$(GO) test -tags '$(TAGS)' $(GOFLAGS) -cover -run $(TESTS) -cpu $(CPUS) $(PKG) $(TESTFLAGS)

# Build, but do not run the tests. This is used to verify the deployable
# Docker image which comes without the build environment. See ./build/deploy
# for details.
.PHONY: testbuild
testbuild:
	for p in $(shell $(GO) list $(PKG)); do \
	  $(GO) test -tags '$(TAGS)' $(GOFLAGS) -c -i $$p || exit $?; \
	done

.PHONY: acceptance
acceptance:
	@acceptance/run.sh

.PHONY: check
check:
	! git grep -F '"path"' -- '*.go'
	errcheck -ignore 'bytes:Write.*,io:(Close|Write),net:Close,net/http:(Close|Write),net/rpc:Close,os:Close,database/sql:Close,github.com/spf13/cobra:Usage' $(PKG)
	! go-nyet $(PKG) | grep -vE '(Weird type of StarExpr|Unknown types|`matchIndex`|`c`|cannot process directory \.git)' # TODO(tamird): https://github.com/barakmich/go-nyet/pull/10
	# https://golang.org/pkg/database/sql/driver/#Result :(
	! golint $(PKG) | grep -vE '(\.pb\.go|embedded\.go|yyEofCode|_string\.go|LastInsertId)'
	! gofmt -s -l . | grep -vF 'No Exceptions'
	! goimports -l . | grep -vF 'No Exceptions'
	! go tool vet --shadow --shadowstrict . 2>&1 |grep -vE '(\.pb\.go|declaration of err shadows)'

.PHONY: clean
clean:
	$(GO) clean -tags '$(TAGS)' $(GOFLAGS) -i github.com/cockroachdb/...
	find . -name '*.test' -type f -exec rm -f {} \;
	rm -rf build/deploy/build

# Store all of the dependencies which are not part of the standard
# library or cockroachdb/cockroach in build/devbase/deps
.PHONY: storedeps
storedeps:
	go list -f '{{range .Deps}}{{printf "%s\n" .}}{{end}}' ./... | sort | uniq | \
	 grep -E '[^/]+\.[^/]+/' | grep -vF 'github.com/cockroachdb/cockroach' > build/devbase/deps

GITHOOKS := $(subst githooks/,.git/hooks/,$(wildcard githooks/*))
.git/hooks/%: githooks/%
	@echo installing $<
	@rm -f $@
	@mkdir -p $(dir $@)
	@ln -s ../../$(basename $<) $(dir $@)

# Update the git hooks and run the bootstrap script whenever any
# of them (or their dependencies) change.
.bootstrap: $(GITHOOKS) build/devbase/godeps.sh GLOCKFILE
	@build/devbase/godeps.sh
	@touch $@

-include .bootstrap
