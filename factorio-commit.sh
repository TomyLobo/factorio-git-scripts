#!/bin/bash

set -e
set -o pipefail
shopt -s failglob

export LC_ALL=C

playtime() {
    local archive="$1"

    local ticks_hex="$(
        unzip -p "$archive" '*/level.dat' |
            hexdump -v -n 1000 -e '1/1 "%02x "' |
            sed -rn 's/^(00 ([0-9a-f]{2} ){4}).*62 61 73 65 \100 ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}).*$/\6\5\4\3/p'
    )"

    printf '%d' "0x$ticks_hex"
}

format_playtime() {
    local ticks="$1"

    local nanos="$(( ticks * 1000000000 / 60 ))"
    local hours="$(( ticks / 60**3 ))"

    local seconds="$(sed -r 's/.{9}$/.\0/' <<< "$nanos")"
    printf '%s' "$hours:$(date -d @"$seconds" -u +'%M:%S.%N')"
}

save_base_path="$(cygpath "$APPDATA")/Factorio/saves"

echo 'Scanning saves...'

args=()
maxticks=0
maxbasename=
for archive in "$save_base_path"/*.zip; do
    basename="$(basename "$archive" .zip)"
    ticks="$(playtime "$archive")"
    playtime="$(format_playtime "$ticks")"

    if [ "$ticks" -gt "$maxticks" ]; then
        maxticks="$ticks"
        maxbasename="$basename"
    fi

    args=("${args[@]}" "$basename" "$playtime")
done

if ! type -p dialog > /dev/null; then
    echo >&2 'Tool "dialog" not found - using fallback dialog'
    dialog() {
        local default="$4"
        local default_index=
        local prompt="$6"
        shift 9

        local args=()
        local index=1
        local tag item
        while [ "$#" -gt 0 ]; do
            tag="$1"
            item="$2"

            if [ "$tag" = "$default" ]; then
                item="$item (default)"
                default_index="$index"
            fi

            printf '%s: %s - %s\n' "$index" "$tag" "$item" >&2
            args=("${args[@]}" "$tag")
            
            (( ++index ))
            shift 2
        done

        read -ei "$default_index" -p "$prompt: " index

        tag="${args["$index"]}"
        if [ -z "$tag" ]; then
            return 1
        fi

        printf '%s' "$tag"
    }
fi

if ! save_game_name=$(dialog --keep-tite --stdout --default-item "$maxbasename" --menu 'Select a saved game to commit' 17 100 10 "${args[@]}") 2>&1; then
    echo >&2 'User cancelled.'
    exit 1
fi

archive="$save_base_path/$save_game_name.zip"
playtime="$(format_playtime "$(playtime "$archive")")"

export GIT_INDEX_FILE="$(mktemp -u)"

cleanup() {
    rm -f "$GIT_INDEX_FILE"
}

trap cleanup EXIT

# Initialize temporary index from HEAD
git reset --mixed

unzip -Z1 "$archive" |
    while read zip_filename; do
        # Cut off initial component
        git_filename="${zip_filename#*/}"

        # Create blob object
        blob_hash="$(
            unzip -p "$archive" "$zip_filename" |
                git hash-object -t blob -w --stdin --no-filters
        )"

        # Add blob object to index
        git update-index --add --cacheinfo 100644,"$blob_hash","$git_filename"
    done

# Commit modified index
git commit -m "Play time: $playtime

Created from $(basename "$archive")"

cleanup
