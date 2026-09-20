#!/usr/bin/env bash

# Regenerate ports/<module>/{vcpkg.json,portfile.cmake} for every DUNE module
# listed in scripts/module_list.bash. See README.md for the pin policy.
#
# The generated ports are not meant to be hand-edited: to move a pin, edit
# scripts/module_list.bash and rerun this script, then run
# scripts/update-versions.py and commit both.

set -euo pipefail

# Ensure the script can be called from any directory
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REGISTRY_ROOT=$(cd "$SCRIPT_DIR/../" && pwd)

cd "$REGISTRY_ROOT"

# Ensure the tmp directory exists
mkdir -p tmp

# Source the submodule info from module_list.bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/module_list.bash"

# Pre-defined map of additional dependencies for specific ports
declare -A PORT_DEPENDENCIES

# dune-common needs BLAS/LAPACK available at build time so that HAVE_LAPACK is
# defined and the LAPACK wrappers (e.g. eigenValuesNonsymLapackCall) are
# compiled into libdunecommon. vcpkg builds each port in isolation, so this must
# be declared on the port itself, not only in the consuming manifest.
PORT_DEPENDENCIES[dune-common]="lapack openblas"
PORT_DEPENDENCIES[dune-alugrid]="dune-grid"
PORT_DEPENDENCIES[dune-uggrid]="dune-common"
PORT_DEPENDENCIES[dune-grid]="dune-common dune-geometry"
PORT_DEPENDENCIES[dune-geometry]="dune-common"
PORT_DEPENDENCIES[dune-grid-glue]="dune-grid"
PORT_DEPENDENCIES[dune-istl]="dune-common"
PORT_DEPENDENCIES[dune-localfunctions]="dune-geometry"
PORT_DEPENDENCIES[dune-testtools]="dune-common"

# Define features and their dependencies
declare -A PORT_FEATURES
PORT_FEATURES[dune-grid]="alberta:Support for Alberta grid implementation;uggrid:Support for UG grid implementation"

# Define feature dependencies
declare -A FEATURE_DEPENDENCIES
FEATURE_DEPENDENCIES[dune-grid,alberta]="alberta"
FEATURE_DEPENDENCIES[dune-grid,uggrid]="dune-uggrid"
# Define the submodule information
# Iterate over all submodules from the associative array
for submodule_name in "${!SUBMODULE_INFO_HASH[@]}"; do
    port_dir="ports/$submodule_name"
    mkdir -p "$port_dir"

    # Only use information from module_list.bash
    git_hash="${SUBMODULE_INFO_HASH[$submodule_name]}"
    url="${SUBMODULE_INFO_URL[$submodule_name]}"

    # Remember what the port currently pins and publishes. A registry serves
    # immutable versions: if the pin moves but dune.module still says the same
    # Version:, the port-version has to go up, or consumers that already
    # resolved this version keep building the old sources.
    previous_hash=""
    previous_version=""
    previous_port_version=0
    if [[ -f "$port_dir/portfile.cmake" ]]; then
        previous_hash=$(grep -oE 'REF[[:space:]]+[0-9a-f]{40}' "$port_dir/portfile.cmake" |
            head -n1 | grep -oE '[0-9a-f]{40}' || true)
    fi
    if [[ -f "$port_dir/vcpkg.json" ]]; then
        previous_version=$(jq -r '.version // ""' "$port_dir/vcpkg.json")
        previous_port_version=$(jq -r '."port-version" // 0' "$port_dir/vcpkg.json")
    fi

    # Try to extract version from dune.module in the remote repo
    version="0.0.1"
    tmp_clone_dir="tmp/port_clone_$submodule_name"
    [[ -d "$tmp_clone_dir" ]] || git clone "$url" "$tmp_clone_dir" &> /dev/null
    pushd "$tmp_clone_dir" &> /dev/null
    git fetch --all &> /dev/null
    git checkout "$git_hash" &> /dev/null
    if [[ -f "dune.module" ]]; then
        found_version=$(grep -E '^Version: ' "dune.module" | head -n1 | sed 's/Version: *//')
        if [[ -n "$found_version" ]]; then
            echo "Found version: $found_version for $submodule_name"
            version="$found_version"
        fi
    else
        echo "No version found in dune.module for $submodule_name, using default version: $version"
    fi
    popd &> /dev/null

    port_version=0
    if [[ -n "$previous_hash" && "$previous_hash" != "$git_hash" && "$previous_version" == "$version" ]]; then
        port_version=$((previous_port_version + 1))
        echo "  pin moved but version is still $version: bumping port-version to $port_version"
    elif [[ "$previous_version" == "$version" ]]; then
        port_version="$previous_port_version"
    fi

    homepage="$url"

    # Prepare dependencies JSON array
    dependencies='        {
            "name": "vcpkg-cmake",
            "host": true
        },
        {
            "name": "vcpkg-cmake-config",
            "host": true
        }'

    # Add extra dependencies if present in the map
    if [[ -n "${PORT_DEPENDENCIES[$submodule_name]:-}" ]]; then
        for dep in ${PORT_DEPENDENCIES[$submodule_name]}; do
            dependencies="$dependencies,
        {\"name\": \"$dep\"}"
        done
    fi

    # Prepare features section if present
    features=""
    if [[ -n "${PORT_FEATURES[$submodule_name]:-}" ]]; then
        features=',
    "features": {'
        IFS=';' read -ra feature_list <<< "${PORT_FEATURES[$submodule_name]}"
        for feature_desc in "${feature_list[@]}"; do
            feature_name="${feature_desc%%:*}"
            feature_description="${feature_desc#*:}"
            features="$features
        \"$feature_name\": {            \"description\": \"$feature_description\""
            if [[ -n "${FEATURE_DEPENDENCIES[$submodule_name,$feature_name]:-}" ]]; then
                features="$features,
            \"dependencies\": ["
                IFS=' ' read -ra feat_deps <<< "${FEATURE_DEPENDENCIES[$submodule_name,$feature_name]}"
                first_dep=true
                for feat_dep in "${feat_deps[@]}"; do
                    if [[ "$first_dep" == true ]]; then
                        first_dep=false
                    else
                        features="$features,"
                    fi
                    features="$features
                {\"name\": \"$feat_dep\"}"
                done
                features="$features
            ]"
            fi
            features="$features
        },"
        done
        features="${features%,}
    }"
    fi

    # Only emit "port-version" when it is non-zero; vcpkg treats it as 0 by
    # default and update-versions.py records it the same way.
    port_version_field=""
    if [[ "$port_version" -ne 0 ]]; then
        port_version_field="
    \"port-version\": $port_version,"
    fi

    # Create vcpkg.json
    cat > "$port_dir/vcpkg.json" << EOF
{
    "name": "$submodule_name",
    "version": "$version",$port_version_field
    "description": "DUNE module $submodule_name, pinned to a git commit",
    "homepage": "$homepage",
    "dependencies": [
$dependencies
    ]$features
}
EOF

    # Create portfile.cmake (install COPYING as copyright if present)
    cat > "$port_dir/portfile.cmake" << EOF
set(VCPKG_BUILD_TYPE release)

vcpkg_from_git(
    OUT_SOURCE_PATH SOURCE_PATH
    URL "$url"
    REF $git_hash
)

vcpkg_cmake_configure(
    SOURCE_PATH "\${SOURCE_PATH}"
    OPTIONS
        -DBUILD_TESTING=OFF
        -DCMAKE_DISABLE_FIND_PACKAGE_MPI=TRUE
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(CONFIG_PATH lib/cmake/$submodule_name)

file(REMOVE_RECURSE "\${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "\${CURRENT_PACKAGES_DIR}/debug/share")

if(EXISTS "\${SOURCE_PATH}/COPYING")
    file(INSTALL "\${SOURCE_PATH}/COPYING" DESTINATION "\${CURRENT_PACKAGES_DIR}/share/\${PORT}" RENAME "copyright")
else()
    file(WRITE "\${CURRENT_PACKAGES_DIR}/share/\${PORT}/copyright" "No license file found in the source repository. Please check the source code for license information.")
endif()
EOF
    # The heredocs above are deliberately naive; pre-commit's cmake-format and
    # clang-format (which also formats JSON) normalise the result, so that the
    # checked-in ports match what the hooks would produce anyway.
    pre-commit run cmake-format --files "$port_dir"/* &> /dev/null || \
        pre-commit run clang-format --files "$port_dir"/* &> /dev/null || true
    echo "Created port for $submodule_name"
done

echo
echo "Now run scripts/update-versions.py and commit ports/ together with versions/."
