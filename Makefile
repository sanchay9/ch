SHELL := /usr/bin/env bash

lint-sh:
	shfmt -f . | grep -v jdtls | xargs shellcheck

style-sh:
	shfmt -f . | grep -v jdtls | xargs shfmt -i 2 -ci -bn -l -d
