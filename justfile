# This is a justfile. See https://github.com/casey/just
# This is only used for local development. The builds made on the Fedora
# infrastructure are run in Pungi.

# Set a default for some recipes
default_variant := "silverblue"
# Default to unified compose now that it works for Silverblue & Kinoite builds
unified_core := "true"
# unified_core := "false"
force_nocache := "true"
# force_nocache := "false"

# Default is to compose Silverblue and Kinoite
all:
    just compose silverblue
    just compose kinoite
    just compose vauxite
    just compose base

# Basic validation to make sure the manifests are not completely broken
validate:
    ./ci/validate

# Sync the manifests with the content of the comps groups
comps-sync:
    #!/bin/bash
    set -euxo pipefail

    if [[ ! -d fedora-comps ]]; then
        git clone https://pagure.io/fedora-comps.git
    else
        pushd fedora-comps > /dev/null || exit 1
        git fetch
        git reset --hard origin/main
        popd > /dev/null || exit 1
    fi

    default_variant={{default_variant}}
    version="$(rpm-ostree compose tree --print-only --repo=repo fedora-${default_variant}.yaml | jq -r '."automatic-version-prefix"')"
    ./comps-sync.py --save fedora-comps/comps-f${version}.xml.in

# Output the processed manifest for a given variant (defaults to Silverblue)
manifest variant=default_variant:
    #!/bin/bash
    set -euxo pipefail

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            ;;
        "base")
            variant_pretty="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    rpm-ostree compose tree --print-only --repo=repo fedora-{{variant}}.yaml

# Compose a specific variant of Fedora (defaults to Silverblue)
compose variant=default_variant:
    #!/bin/bash
    set -euxo pipefail

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            ;;
        "base")
            variant_pretty="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    on_failure() {
        just archive {{variant}} repo
    }
    trap "on_failure" ERR

    ./ci/validate > /dev/null || (echo "Failed manifest validation" && exit 1)

    just prep

    buildid="$(date '+%Y%m%d.0')"
    timestamp="$(date --iso-8601=sec)"
    echo "${buildid}" > .buildid

    # TODO: Pull latest build for the current release
    # ostree pull ...

    version="$(rpm-ostree compose tree --print-only --repo=repo fedora-${variant}.yaml | jq -r '."mutate-os-release"')"

    echo "Composing ${variant_pretty} ${version}.${buildid} ..."
    # To debug with gdb, use: gdb --args ...

    ARGS="--repo=repo --cachedir=cache"
    if [[ {{unified_core}} == "true" ]]; then
        ARGS+=" --unified-core"
    else
        ARGS+=" --workdir=tmp"
        rm -rf ./tmp
        mkdir -p tmp
        export RPM_OSTREE_I_KNOW_NON_UNIFIED_CORE_IS_DEPRECATED=1
        # TODO: Check if this is still needed
        export SYSTEMD_OFFLINE=1
    fi
    if [[ {{force_nocache}} == "true" ]]; then
        ARGS+=" --force-nocache"
    fi
    CMD="rpm-ostree"
    if [[ ${EUID} -ne 0 ]]; then
        SUDO="sudo rpm-ostree"
    fi

    ${CMD} compose tree ${ARGS} \
        --add-metadata-string="version=${variant_pretty} ${version}.${buildid}" \
        "fedora-${variant}.yaml" \
            |& tee "logs/${variant}_${version}_${buildid}.${timestamp}.log"

    if [[ ${EUID} -ne 0 ]]; then
        if [[ {{unified_core}} == "false" ]]; then
            sudo chown --recursive "$(id --user --name):$(id --group --name)" tmp
        fi
        sudo chown --recursive "$(id --user --name):$(id --group --name)" repo cache
    fi

    ostree summary --repo=repo --update

# Compose an OCI image
compose-image variant=default_variant:
    #!/bin/bash
    set -euxo pipefail

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            ;;
        "base")
            variant_pretty="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    # on_failure() {
    #     just archive {{variant}} repo
    # }
    # trap "on_failure" ERR

    ./ci/validate > /dev/null || (echo "Failed manifest validation" && exit 1)

    just prep

    buildid="$(date '+%Y%m%d.0')"
    timestamp="$(date --iso-8601=sec)"
    echo "${buildid}" > .buildid

    # TODO: Pull latest build for the current release
    # ostree pull ...

    version="$(rpm-ostree compose tree --print-only --repo=repo fedora-${variant}.yaml | jq -r '."mutate-os-release"')"

    echo "Composing ${variant_pretty} ${version}.${buildid} ..."
    # To debug with gdb, use: gdb --args ...

    ARGS="--cachedir=cache --initialize"
    if [[ {{force_nocache}} == "true" ]]; then
        ARGS+=" --force-nocache"
    fi
    CMD="rpm-ostree"
    if [[ ${EUID} -ne 0 ]]; then
        SUDO="sudo rpm-ostree"
    fi

    ${CMD} compose image ${ARGS} \
         --label="quay.expires-after=16w" \
        "fedora-${variant}.yaml" \
        "fedora-${variant}.ociarchive" \
            |& tee "logs/${variant}_${version}_${buildid}.${timestamp}.log"

# Last steps from the compose recipe that can easily fail when the sudo timeout is reached
compose-finalise:
    #!/bin/bash
    set -euxo pipefail

    if [[ ${EUID} -ne 0 ]]; then
        sudo chown --recursive "$(id --user --name):$(id --group --name)" repo cache
    fi
    ostree summary --repo=repo --update

# Get ostree repo log for a given variant
log variant=default_variant:
    ostree log --repo repo fedora/rawhide/x86_64/{{variant}}

# Get the diff between two ostree commits
diff target origin:
    ostree diff --repo repo --fs-diff {{target}} {{origin}}

# Serve the generated commit for testing
serve:
    # See https://github.com/TheWaWaR/simple-http-server
    simple-http-server --index --ip 192.168.122.1 --port 8000 --silent

# Preparatory steps before starting a compose. Also ensure the ostree repo is initialized
prep:
    #!/bin/bash
    set -euxo pipefail

    mkdir -p repo cache logs
    if [[ ! -f "repo/config" ]]; then
        pushd repo > /dev/null || exit 1
        ostree init --repo . --mode=archive
        popd > /dev/null || exit 1
    fi
    # Set option to reduce fsync for transient builds
    ostree --repo=repo config set 'core.fsync' 'false'

# Clean up everything
clean-all:
    just clean-repo
    just clean-cache

# Only clean the ostree repo
clean-repo:
    rm -rf ./repo

# Only clean the package and repo caches
clean-cache:
    rm -rf ./cache

# Run from inside a container
podman:
    podman run --rm -ti --volume $PWD:/srv:rw --workdir /srv --privileged quay.io/fedora-ostree-desktops/buildroot

# Update the container image
podman-pull:
    podman pull quay.io/fedora-ostree-desktops/buildroot

# Build an ISO
lorax variant=default_variant:
    #!/bin/bash
    set -euxo pipefail

    rm -rf iso
    # Do not create the iso directory or lorax will fail
    mkdir -p tmp cache/lorax

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            volid_sub="SB"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            volid_sub="Knt"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            volid_sub="Vxt"
            ;;
        "base")
            variant_pretty="Base"
            volid_sub="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    on_failure() {
        # Archive both repo & iso here as we only archive the repo after the
        # lorax step in the non-failing case
        just archive {{variant}} repo
        just archive {{variant}} iso
    }
    trap "on_failure" ERR

    if [[ ! -d fedora-lorax-templates ]]; then
        git clone https://pagure.io/fedora-lorax-templates.git
    else
        pushd fedora-lorax-templates > /dev/null || exit 1
        git fetch
        git reset --hard origin/main
        popd > /dev/null || exit 1
    fi

    version_number="$(rpm-ostree compose tree --print-only --repo=repo fedora-${variant}.yaml | jq -r '."mutate-os-release"')"
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || [[ -f "fedora-rawhide.repo" ]]; then
        version_pretty="Rawhide"
        version="rawhide"
    else
        version_pretty="${version_number}"
        version="${version_number}"
    fi
    source_url="https://kojipkgs.fedoraproject.org/compose/${version}/latest-Fedora-${version_pretty}/compose/Everything/x86_64/os/"
    volid="Fedora-${volid_sub}-ostree-x86_64-${version_pretty}"

    buildid=""
    if [[ -f ".buildid" ]]; then
        buildid="$(< .buildid)"
    else
        buildid="$(date '+%Y%m%d.0')"
        echo "${buildid}" > .buildid
    fi

    # Stick to the latest stable runtime available here
    flatpak_remote_refs="runtime/org.fedoraproject.Platform/x86_64/f36"
    flatpak_apps=(
        "app/org.fedoraproject.MediaWriter/x86_64/stable"
        "app/org.gnome.Calculator/x86_64/stable"
        "app/org.gnome.Calendar/x86_64/stable"
        "app/org.gnome.Characters/x86_64/stable"
        "app/org.gnome.Connections/x86_64/stable"
        "app/org.gnome.Contacts/x86_64/stable"
        "app/org.gnome.Evince/x86_64/stable"
        "app/org.gnome.Extensions/x86_64/stable"
        "app/org.gnome.Logs/x86_64/stable"
        "app/org.gnome.Maps/x86_64/stable"
        "app/org.gnome.NautilusPreviewer/x86_64/stable"
        "app/org.gnome.TextEditor/x86_64/stable"
        "app/org.gnome.Weather/x86_64/stable"
        "app/org.gnome.baobab/x86_64/stable"
        "app/org.gnome.clocks/x86_64/stable"
        "app/org.gnome.eog/x86_64/stable"
        "app/org.gnome.font-viewer/x86_64/stable"
    )
    for ref in ${flatpak_refs[@]}; do
        flatpak_remote_refs+=" ${ref}"
    done

    pwd="$(pwd)"

    lorax \
        --product=Fedora \
        --version=${version_pretty} \
        --release=${buildid} \
        --source="${source_url}" \
        --variant="${variant_pretty}" \
        --nomacboot \
        --isfinal \
        --buildarch=x86_64 \
        --volid="${volid}" \
        --logfile=${pwd}/logs/lorax.log \
        --tmp=${pwd}/tmp \
        --cachedir=cache/lorax \
        --rootfs-size=8 \
        --add-template=${pwd}/fedora-lorax-templates/ostree-based-installer/lorax-configure-repo.tmpl \
        --add-template=${pwd}/fedora-lorax-templates/ostree-based-installer/lorax-embed-repo.tmpl \
        --add-template=${pwd}/fedora-lorax-templates/ostree-based-installer/lorax-embed-flatpaks.tmpl \
        --add-template-var=ostree_install_repo=file://${pwd}/repo \
        --add-template-var=ostree_update_repo=file://${pwd}/repo \
        --add-template-var=ostree_osname=fedora \
        --add-template-var=ostree_oskey=fedora-${version_number}-primary \
        --add-template-var=ostree_contenturl=mirrorlist=https://ostree.fedoraproject.org/mirrorlist \
        --add-template-var=ostree_install_ref=fedora/${version}/x86_64/${variant} \
        --add-template-var=ostree_update_ref=fedora/${version}/x86_64/${variant} \
        --add-template-var=flatpak_remote_name=fedora \
        --add-template-var=flatpak_remote_url=oci+https://registry.fedoraproject.org \
        --add-template-var=flatpak_remote_refs="${flatpak_remote_refs}" \
        ${pwd}/iso/linux

upload-container variant=default_variant:
    #!/bin/bash
    set -euxo pipefail

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            ;;
        "base")
            variant_pretty="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    if [[ -z ${CI_REGISTRY_USER+x} ]] || [[ -z ${CI_REGISTRY_PASSWORD+x} ]]; then
        echo "Skipping artifact archiving: Not in CI"
        exit 0
    fi
    if [[ "${CI}" != "true" ]]; then
        echo "Skipping artifact archiving: Not in CI"
        exit 0
    fi

    version=""
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || [[ -f "fedora-rawhide.repo" ]]; then
        version="rawhide"
    else
        version="$(rpm-ostree compose tree --print-only --repo=repo fedora-${variant}.yaml | jq -r '."mutate-os-release"')"
    fi

    image="quay.io/fedora-ostree-desktops/${variant}"
    buildid=""
    if [[ -f ".buildid" ]]; then
        buildid="$(< .buildid)"
    else
        buildid="$(date '+%Y%m%d.0')"
        echo "${buildid}" > .buildid
    fi

    git_commit=""
    if [[ -n "${CI_COMMIT_SHORT_SHA}" ]]; then
        git_commit="${CI_COMMIT_SHORT_SHA}"
    else
        git_commit="$(git rev-parse --short HEAD)"
    fi

    skopeo login --username "${CI_REGISTRY_USER}" --password "${CI_REGISTRY_PASSWORD}" quay.io
    # Copy fully versioned tag (major version, build date/id, git commit)
    skopeo copy --retry-times 3 "oci-archive:fedora-${variant}.ociarchive" "docker://${image}:${version}.${buildid}.${git_commit}"
    # Update "un-versioned" tag (only major version)
    skopeo copy --retry-times 3 "docker://${image}:${version}.${buildid}.${git_commit}" "docker://${image}:${version}"
    if [[ "${variant}" == "kinoite-nightly" ]] || [[ "${variant}" == "kinoite-beta" ]]; then
        # Update latest tag for kinoite-nightly only
        skopeo copy --retry-times 3 "docker://${image}:${version}.${buildid}.${git_commit}" "docker://${image}:latest"
    fi

# Make a container image with the artifacts
archive variant=default_variant kind="repo":
    #!/bin/bash
    set -euxo pipefail

    if [[ -z ${CI_REGISTRY_USER+x} ]] || [[ -z ${CI_REGISTRY_PASSWORD+x} ]]; then
        echo "Skipping artifact archiving: Not in CI"
        exit 0
    fi
    if [[ "${CI}" == "true" ]]; then
        rm -rf cache
    fi

    variant={{variant}}
    case "${variant}" in
        "silverblue")
            variant_pretty="Silverblue"
            ;;
        "kinoite"|"kinoite-nightly"|"kinoite-beta")
            variant_pretty="Kinoite"
            ;;
        "vauxite")
            variant_pretty="Vauxite"
            ;;
        "base")
            variant_pretty="Base"
            ;;
        "*")
            echo "Unknown variant"
            exit 1
            ;;
    esac

    kind={{kind}}
    case "${kind}" in
        "repo")
            echo "Archiving repo"
            ;;
        "iso")
            echo "Archiving iso"
            ;;
        "*")
            echo "Unknown kind"
            exit 1
            ;;
    esac

    version=""
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || [[ -f "fedora-rawhide.repo" ]]; then
        version="rawhide"
    else
        version="$(rpm-ostree compose tree --print-only --repo=repo fedora-${variant}.yaml | jq -r '."mutate-os-release"')"
    fi

    if [[ "${kind}" == "repo" ]]; then
        tar --create --file repo.tar.zst --zstd repo
        if [[ "${CI}" == "true" ]]; then
            rm -rf repo
        fi
    fi
    if [[ "${kind}" == "iso" ]]; then
        tar --create --file iso.tar.zst --zstd iso
        if [[ "${CI}" == "true" ]]; then
            rm -rf iso
        fi
    fi

    container="$(buildah from scratch)"
    if [[ "${kind}" == "repo" ]]; then
        buildah copy "${container}" repo.tar.zst /
    fi
    if [[ "${kind}" == "iso" ]]; then
        buildah copy "${container}" iso.tar.zst /
    fi
    buildah config --label "quay.expires-after=2w" "${container}"
    commit="$(buildah commit ${container})"

    image="quay.io/fedora-ostree-desktops/${variant}"
    buildid=""
    if [[ -f ".buildid" ]]; then
        buildid="$(< .buildid)"
    else
        buildid="$(date '+%Y%m%d.0')"
        echo "${buildid}" > .buildid
    fi

    git_commit=""
    if [[ -n "${CI_COMMIT_SHORT_SHA}" ]]; then
        git_commit="${CI_COMMIT_SHORT_SHA}"
    else
        git_commit="$(git rev-parse --short HEAD)"
    fi

    buildah login -u "${CI_REGISTRY_USER}" -p "${CI_REGISTRY_PASSWORD}" quay.io
    buildah push "${commit}" "docker://${image}:${version}.${buildid}.${git_commit}.${kind}"
