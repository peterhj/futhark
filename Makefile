# This Makefile mostly serves to abbreviate build commands that are
# unnecessarily obtuse or longwinded.  It depends on the underlying
# build tool (cabal) to actually do anything incrementally.
# Configuration is mostly read from cabal.project.

PREFIX?=$(HOME)/.local

UNAME:=$(shell uname)

# Disable all implicit rules.
.SUFFIXES:

.PHONY: all configure dev dev-build dev-install build install docs check check-commit clean

all: build

configure:
	cabal update
	cabal configure

configure-profile:
	cabal configure --enable-profiling --profiling-detail=toplevel-functions

dev: dev-build

dev-build:
	cabal build

dev-install: dev-build
	install -d $(PREFIX)/bin/
	install "$$(cabal -v0 list-bin exe:cacti-futhark)" $(PREFIX)/bin/cacti-futhark

build: install

install:
	cabal install exe:cacti-futhark --overwrite-policy=always

docs:
	cabal haddock \
		--enable-documentation \
		--haddock-html \
		--haddock-options=--show-all \
		--haddock-options=--quickjump \
		--haddock-options=--show-all \
		--haddock-options=--hyperlinked-source

check:
	tools/style-check.sh src unittests

check-commit:
	tools/style-check.sh $$(git diff-index --cached --ignore-submodules=all --name-status HEAD | awk '$$1 != "D" { print $$2 }')

unittest:
	cabal run unit

clean:
	cabal clean
