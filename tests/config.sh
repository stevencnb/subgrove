#!/usr/bin/env bash
# Remote-test fixture URLs. Filled in once by the maintainer after creating
# the dedicated test repos on GitHub. Committed to the repository so every
# checkout knows which repos to use for remote tests.
#
# Examples:
#   SUBGROVE_TEST_SUPER_URL="git@github.com:you/subgrove-test-super.git"
#   SUBGROVE_TEST_SM_URL="git@github.com:you/subgrove-test-sm.git"
#   SUBGROVE_TEST_SM_URL2="git@github.com:you/subgrove-test-sm2.git"
#   SUBGROVE_TEST_SUPER_NO_SM_URL="git@github.com:you/subgrove-test-super-no-sm.git"
#
# Two submodule URLs are required so the with-sm remote tests can exercise
# multi-submodule paths over the wire (peer propagation across submodules,
# push=true advancing multiple origins, partial-merge skip lists, etc.).
# The fixture's submodules are named sm-a (URL) and sm-b (URL2), matching
# the local tests' naming.
#
# SUBGROVE_TEST_SUPER_NO_SM_URL drives the no-submodule remote tier
# (tests/remote-no-sm/). That tier has no separate init script — its
# fixture lazily pushes the baseline on first use. See
# docs/design/testing-remote-no-sm.md.
#
# Empty values cause the corresponding remote tier to fail loudly with a
# remediation hint. Run `tests/run.sh --local-only` to skip ALL remote
# tiers (e.g. in CI or from a contributor's fork without push access).
#
# These can also be overridden via env vars for one-off runs against a
# different remote without editing this file.

SUBGROVE_TEST_SUPER_URL="git@github.com:stevencnb/subgrove-test-super.git"
SUBGROVE_TEST_SM_URL="git@github.com:stevencnb/subgrove-test-sm-a.git"
SUBGROVE_TEST_SM_URL2="git@github.com:stevencnb/subgrove-test-sm-b.git"
SUBGROVE_TEST_SUPER_NO_SM_URL="git@github.com:stevencnb/subgrove-test-super-no-sm.git"
