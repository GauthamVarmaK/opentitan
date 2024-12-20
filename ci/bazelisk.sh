#!/bin/bash
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# In GitHub actions, we configure Bazel using ~/.bazelisk using .github/actions/prepare-env
# So execute bazelisk.sh directly.
if [[ -n "$GITHUB_ACTIONS" ]]; then
    exec "$(dirname $0)"/../bazelisk.sh "$@"
fi

# This is the CI version of `bazelisk.sh`, which calls into the "usual" wrapper,
# but adds various flags to produce CI-friendly output. It does so by prociding a
# command-line specified .bazelrc (that is applied alongside //.bazelrc).

if [[ -n "${PWD_OVERRIDE}" ]]; then
    cd "${PWD_OVERRIDE}" || exit
fi

echo "Running bazelisk in $(pwd)." >&2

# An additional bazelrc must be synthesized to specify precisely how to use the
# GCP bazel cache.
GCP_CREDS_FILE="$GCP_BAZEL_CACHE_KEY_SECUREFILEPATH"
GCP_BAZELRC="$(mktemp /tmp/XXXXXX.bazelrc)"
trap 'rm ${GCP_BAZELRC}' EXIT

if [[ -n "$GCP_CREDS_FILE" && -f "$GCP_CREDS_FILE" ]]; then
    echo "Applying GCP cache key; will upload to the cache." >&2
    echo "build --google_credentials=${GCP_CREDS_FILE}" >> "${GCP_BAZELRC}"
else
    echo "No key/invalid path to key. Download from cache only." >&2
    echo "build --remote_upload_local_results=false" >> "${GCP_BAZELRC}"
fi

# Inject the OS version into a parameter used in the action key computation to
# avoid collisions between different operating systems in the caches.
# See #14695 for more information.
echo "build --remote_default_exec_properties=OSVersion=\"$(lsb_release -ds)\"" >> "${GCP_BAZELRC}"

"$(dirname $0)"/../bazelisk.sh \
  --bazelrc="${GCP_BAZELRC}" \
  --bazelrc="$(dirname $0)"/.bazelrc \
  "$@"
