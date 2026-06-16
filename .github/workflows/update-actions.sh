#!/usr/bin/env bash
# Fetches the latest release/tag for each GitHub Action used in these workflows,
# resolves each to its full commit SHA for supply-chain security pinning, and
# updates every affected .yml file in place.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- helpers ----------------------------------------------------------

latest_release() {
    gh api "repos/$1/releases/latest" --jq '.tag_name'
}

latest_tag() {
    # Falls back to tags when a repo has no formal releases
    gh api "repos/$1/tags" --jq 'first | .name'
}

sha_for_tag() {
    # Resolves a tag to its commit SHA, dereferencing annotated tags if needed.
    local repo="$1" tag="$2"
    local info type sha
    info=$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[.object.type, .object.sha] | join(" ")')
    type="${info%% *}"
    sha="${info##* }"
    if [[ "$type" == "tag" ]]; then
        # Annotated tag — follow the tag object to the commit
        gh api "repos/$repo/git/tags/$sha" --jq '.object.sha'
    else
        echo "$sha"
    fi
}

sha_for_branch() {
    # Returns the full commit SHA for the HEAD of a branch.
    gh api "repos/$1/commits/$2" --jq '.sha'
}

replace_in() {
    local file="$DIR/$1" action="$2" new_sha="$3" tag_label="$4"
    if [[ -z "$new_sha" ]]; then
        printf '  %-55s WARNING: no SHA found, skipping\n' "$action"
        return
    fi
    # Detect the current ref already in the file (stops at whitespace/end-of-line)
    local old
    old=$(grep -o "${action}@[a-zA-Z0-9._+-]*" "$file" 2>/dev/null | head -1 | cut -d@ -f2-)
    if [[ -z "$old" ]]; then
        return  # action not present in this file
    fi
    if [[ "$old" == "$new_sha" ]]; then
        printf '  %-55s already %s  # %s\n' "$action" "${new_sha:0:16}..." "$tag_label"
        return
    fi
    # Replace action@<any-ref> (with optional trailing comment) with SHA + tag comment
    sed -i '' -E "s|${action}@[a-zA-Z0-9._+-]+([[:space:]]+#.*)?$|${action}@${new_sha}  # ${tag_label}|" "$file"
    printf '  %-55s %s → %s  # %s\n' "$action" "${old:0:12}..." "${new_sha:0:12}..." "$tag_label"
}

# ---------- fetch latest versions and SHAs -----------------------------------

echo "Fetching latest versions and commit SHAs from GitHub API..."
echo ""

V_CHECKOUT=$(latest_release "actions/checkout")
SHA_CHECKOUT=$(sha_for_tag "actions/checkout" "$V_CHECKOUT")

V_UPLOAD=$(latest_release "actions/upload-artifact")
SHA_UPLOAD=$(sha_for_tag "actions/upload-artifact" "$V_UPLOAD")

V_CODEQL=$(gh api "repos/github/codeql-action/releases" \
    --jq '[.[] | select(.tag_name | test("^v[0-9]")) | .tag_name] | first')
SHA_CODEQL=$(sha_for_tag "github/codeql-action" "$V_CODEQL")

V_NASM=$(latest_release "ilammy/setup-nasm")
SHA_NASM=$(sha_for_tag "ilammy/setup-nasm" "$V_NASM")

V_MSBUILD=$(latest_release "microsoft/setup-msbuild")
SHA_MSBUILD=$(sha_for_tag "microsoft/setup-msbuild" "$V_MSBUILD")

V_JUNIT=$(latest_release "mikepenz/action-junit-report")
SHA_JUNIT=$(sha_for_tag "mikepenz/action-junit-report" "$V_JUNIT")

V_MSYS2=$(latest_release "msys2/setup-msys2")
SHA_MSYS2=$(sha_for_tag "msys2/setup-msys2" "$V_MSYS2")

V_SW=$(latest_tag "egorpugin/sw-action" 2>/dev/null || echo "master")
if [[ "$V_SW" == "master" ]]; then
    SHA_SW=$(sha_for_branch "egorpugin/sw-action" "master")
else
    SHA_SW=$(sha_for_tag "egorpugin/sw-action" "$V_SW")
fi

SHA_OSS_FUZZ=$(sha_for_branch "google/oss-fuzz" "master")

printf '  %-45s %-12s  →  %s\n' "actions/checkout"             "$V_CHECKOUT"  "${SHA_CHECKOUT:0:16}..."
printf '  %-45s %-12s  →  %s\n' "actions/upload-artifact"      "$V_UPLOAD"    "${SHA_UPLOAD:0:16}..."
printf '  %-45s %-12s  →  %s\n' "github/codeql-action"         "$V_CODEQL"    "${SHA_CODEQL:0:16}..."
printf '  %-45s %-12s  →  %s\n' "ilammy/setup-nasm"            "$V_NASM"      "${SHA_NASM:0:16}..."
printf '  %-45s %-12s  →  %s\n' "microsoft/setup-msbuild"      "$V_MSBUILD"   "${SHA_MSBUILD:0:16}..."
printf '  %-45s %-12s  →  %s\n' "mikepenz/action-junit-report" "$V_JUNIT"     "${SHA_JUNIT:0:16}..."
printf '  %-45s %-12s  →  %s\n' "msys2/setup-msys2"            "$V_MSYS2"     "${SHA_MSYS2:0:16}..."
printf '  %-45s %-12s  →  %s\n' "egorpugin/sw-action"          "$V_SW"        "${SHA_SW:0:16}..."
printf '  %-45s %-12s  →  %s\n' "google/oss-fuzz (master)"     "master"       "${SHA_OSS_FUZZ:0:16}..."
echo ""

# ---------- apply updates ----------------------------------------------------

echo "Updating workflow files..."
echo ""

# actions/checkout
for f in autotools-macos.yml autotools-openmp.yml autotools.yml cmake-win64.yml \
          cmake.yml codeql-analysis.yml installer-for-windows.yml msys2.yml \
          sw.yml unittest-disablelegacy.yml unittest-macos.yml unittest.yml vcpkg.yml; do
    replace_in "$f" "actions/checkout" "$SHA_CHECKOUT" "$V_CHECKOUT"
done

echo ""

# actions/upload-artifact
for f in autotools.yml cifuzz.yml cmake-win64.yml installer-for-windows.yml sw.yml; do
    replace_in "$f" "actions/upload-artifact" "$SHA_UPLOAD" "$V_UPLOAD"
done

echo ""

# github/codeql-action/*
replace_in "codeql-analysis.yml" "github/codeql-action/init"    "$SHA_CODEQL" "$V_CODEQL"
replace_in "codeql-analysis.yml" "github/codeql-action/analyze" "$SHA_CODEQL" "$V_CODEQL"

echo ""

# ilammy/setup-nasm
replace_in "cmake-win64.yml" "ilammy/setup-nasm" "$SHA_NASM" "$V_NASM"

# microsoft/setup-msbuild
replace_in "cmake-win64.yml" "microsoft/setup-msbuild" "$SHA_MSBUILD" "$V_MSBUILD"

# mikepenz/action-junit-report
replace_in "sw.yml" "mikepenz/action-junit-report" "$SHA_JUNIT" "$V_JUNIT"

# msys2/setup-msys2
replace_in "msys2.yml" "msys2/setup-msys2" "$SHA_MSYS2" "$V_MSYS2"

echo ""

# egorpugin/sw-action
replace_in "sw.yml" "egorpugin/sw-action" "$SHA_SW" "$V_SW"

echo ""

# google/oss-fuzz monorepo actions (always pin to latest master SHA)
replace_in "cifuzz.yml" \
    "google/oss-fuzz/infra/cifuzz/actions/build_fuzzers" "$SHA_OSS_FUZZ" "master"
replace_in "cifuzz.yml" \
    "google/oss-fuzz/infra/cifuzz/actions/run_fuzzers"   "$SHA_OSS_FUZZ" "master"

echo ""
echo "Done."
