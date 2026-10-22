#!/bin/sh

image_json_value() {
    printf '%s' "$1" | jsonfilter -e "$2" 2>/dev/null
}

registry_manifest() {
    curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 20 \
        -H "Authorization: Bearer $registry_token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry-1.docker.io/v2/xream/sub-store/manifests/$1"
}

# Return the remote image's config digest and the immutable reference for the
# local container's exact OS, architecture, and variant.
remote_image_info() {
    command -v curl >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1 || return 1
    image_metadata="$(docker image inspect -f '{{json .}}' "$1")" || return 1
    image_arch="$(image_json_value "$image_metadata" '@.Architecture')" || return 1
    image_os="$(image_json_value "$image_metadata" '@.Os')" || return 1
    image_variant="$(image_json_value "$image_metadata" '@.Variant' || true)"
    [ -n "$image_arch" ] && [ -n "$image_os" ] || return 1
    [ "$image_arch" != arm64 ] || image_variant="${image_variant:-v8}"

    token_response="$(curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 20 \
        'https://auth.docker.io/token?service=registry.docker.io&scope=repository:xream/sub-store:pull')" || return 1
    registry_token="$(image_json_value "$token_response" '@.token')" || return 1
    case "$registry_token" in ''|*[!A-Za-z0-9._=-]*) return 1 ;; esac
    remote_manifest="$(registry_manifest latest)" || return 1
    remote_ref=xream/sub-store:latest
    remote_config="$(image_json_value "$remote_manifest" '@.config.digest' || true)"
    if [ -z "$remote_config" ]; then
        # Select this image's platform, ignoring other architectures and attestations.
        manifest_index=0
        matching_manifests=0
        while [ "$manifest_index" -lt 128 ]; do
            descriptor="$(image_json_value "$remote_manifest" "@.manifests[$manifest_index]" || true)"
            [ -n "$descriptor" ] || break
            descriptor_arch="$(image_json_value "$descriptor" '@.platform.architecture' || true)"
            descriptor_os="$(image_json_value "$descriptor" '@.platform.os' || true)"
            descriptor_variant="$(image_json_value "$descriptor" '@.platform.variant' || true)"
            [ "$descriptor_arch" != arm64 ] || descriptor_variant="${descriptor_variant:-v8}"
            if [ "$descriptor_arch" = "$image_arch" ] && [ "$descriptor_os" = "$image_os" ] &&
                { [ -z "$image_variant" ] || [ "$descriptor_variant" = "$image_variant" ]; }; then
                selected_digest="$(image_json_value "$descriptor" '@.digest')" || return 1
                matching_manifests=$((matching_manifests + 1))
            fi
            manifest_index=$((manifest_index + 1))
        done
        [ "$manifest_index" -lt 128 ] && [ "$matching_manifests" -eq 1 ] || return 1
        printf '%s\n' "$selected_digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || return 1
        remote_ref="xream/sub-store@$selected_digest"
        remote_manifest="$(registry_manifest "$selected_digest")" || return 1
        remote_config="$(image_json_value "$remote_manifest" '@.config.digest')" || return 1
    fi
    printf '%s\n' "$remote_config" | grep -Eq '^sha256:[0-9a-f]{64}$' || return 1
    printf '%s %s\n' "$remote_config" "$remote_ref"
}
