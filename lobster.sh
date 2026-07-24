#!/usr/bin/env sh

LOBSTER_VERSION="4.7.0"

config_file="${XDG_CONFIG_HOME:-$HOME/.config}/lobster/lobster_config.sh"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/lobster"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/lobster"
mkdir -p "$data_dir" "$cache_dir"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lobster.XXXXXX") || exit 1
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

catalog_provider="${catalog_provider:-auto}"
stream_provider="${stream_provider:-auto}"
catalog_provider_order="${catalog_provider_order:-tmdb imdb}"
stream_provider_order="${stream_provider_order:-vidapi vidcore}"
player="${player:-mpv}"
quality="${quality:-}"
subs_language="${subs_language:-en}"
no_subs="${no_subs:-false}"
json_output="${json_output:-false}"
debug="${debug:-false}"
download="false"
download_dir="$PWD"
recent=""
trending="false"
query=""
select_first="false"

extractor_urls="${extractor_urls:-https://dec.eatmynerds.live https://decrypt.broggl.farm}"

if [ -f "$config_file" ]; then
    # shellcheck disable=SC1090
    . "$config_file"
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ -n "${LOBSTER_PROVIDER_DIR:-}" ]; then
    provider_dir=$LOBSTER_PROVIDER_DIR
elif [ -d "$script_dir/providers" ]; then
    provider_dir="$script_dir/providers"
else
    provider_dir="${XDG_DATA_HOME:-$HOME/.local/share}/lobster/providers"
fi

usage() {
    cat <<EOF_USAGE
Usage: ${0##*/} [options] [query]

Search for a movie or TV show, choose an episode, and open it in a media player.
Catalog and stream providers are tried automatically in fallback order.

Options:
  --catalog-provider NAME  Force a catalog provider: tmdb, imdb, or auto
  --stream-provider NAME   Force a stream provider: vidapi, vidcore, or auto
  -p, --provider NAME      Backward-compatible alias for --stream-provider
  --list-providers         Show installed providers and fallback order
  -r, --recent TYPE        Browse recent movie or tv entries
  -t, --trending           Browse trending entries
  -l, --language LANG      Preferred subtitle language (default: en)
  -q, --quality QUALITY    Prefer a stream quality such as 1080 or 720
  -n, --no-subs            Disable subtitles
  -j, --json               Print the successful extractor response
  -d, --download [DIR]     Download instead of playing
  --player COMMAND         Player command (default: mpv)
  --select-first           Select the first result without fzf (testing)
  -e, --edit               Edit the configuration file
  -x, --debug              Show provider and extractor diagnostics
  -v, --version            Print the version
  -h, --help               Show this help

Configuration variables:
  catalog_provider, stream_provider
  catalog_provider_order, stream_provider_order
  player, subs_language, extractor_urls

Examples:
  ${0##*/} "Ugly Betty"
  ${0##*/} --catalog-provider imdb "Fight Club"
  ${0##*/} --stream-provider vidcore "Blade Runner"
EOF_USAGE
}

log_debug() {
    [ "$debug" = "true" ] || return 0
    printf 'debug: %s\n' "$*" >&2
}

error() {
    printf 'Error: %s\n' "$*" >&2
}

fatal() {
    error "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required program '$1' is not installed."
}

provider_script() {
    kind=$1
    name=$2
    printf '%s/%s/%s.sh\n' "$provider_dir" "$kind" "$name"
}

validate_provider_name() {
    kind=$1
    name=$2
    [ "$name" = "auto" ] && return 0
    script=$(provider_script "$kind" "$name")
    [ -x "$script" ] || fatal "Unknown $kind provider '$name'. Run '${0##*/} --list-providers' to see available providers."
}

list_provider_files() {
    kind=$1
    dir="$provider_dir/$kind"
    [ -d "$dir" ] || return 0
    for script in "$dir"/*.sh; do
        [ -f "$script" ] || continue
        basename "$script" .sh
    done
}

list_providers() {
    printf 'Catalog fallback order: %s\n' "$catalog_provider_order"
    printf 'Installed catalog providers:\n'
    list_provider_files catalog | sed 's/^/  - /'
    printf '\nStream fallback order: %s\n' "$stream_provider_order"
    printf 'Installed stream providers:\n'
    list_provider_files stream | sed 's/^/  - /'
}

append_provider_error() {
    provider_errors="${provider_errors}${1}: ${2}\n"
}

run_provider() {
    kind=$1
    name=$2
    shift 2
    script=$(provider_script "$kind" "$name")
    provider_stdout="$tmp_dir/provider.out"
    provider_stderr="$tmp_dir/provider.err"
    : >"$provider_stdout"
    : >"$provider_stderr"

    if [ ! -x "$script" ]; then
        printf '%s provider is not installed at %s\n' "$name" "$script" >"$provider_stderr"
        provider_status=127
        provider_message=$(cat "$provider_stderr")
        return "$provider_status"
    fi

    log_debug "running $kind provider '$name': $*"
    "$script" "$@" >"$provider_stdout" 2>"$provider_stderr"
    provider_status=$?
    provider_message=$(cat "$provider_stderr")
    [ -n "$provider_message" ] && log_debug "$provider_message"
    return "$provider_status"
}

provider_names() {
    selected=$1
    defaults=$2
    if [ "$selected" = "auto" ]; then
        printf '%s\n' "$defaults"
    else
        printf '%s\n' "$selected"
    fi
}

catalog_lookup() {
    action=$1
    shift
    provider_errors=""
    all_no_results="true"

    names=$(provider_names "$catalog_provider" "$catalog_provider_order")
    for name in $names; do
        if run_provider catalog "$name" "$action" "$@"; then
            response=$(cat "$provider_stdout")
            if [ -n "$response" ]; then
                active_catalog_provider=$name
                log_debug "catalog provider '$name' returned results"
                return 0
            fi
            provider_message="$name returned an empty response"
            provider_status=4
        fi

        [ "$provider_status" -eq 2 ] || all_no_results="false"
        [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
        append_provider_error "$name" "$provider_message"
    done

    if [ "$all_no_results" = "true" ]; then
        error "No matching movies or TV shows were found by any catalog provider."
    else
        error "Catalog lookup failed. The providers reported:"
    fi
    printf '%b' "$provider_errors" | sed 's/^/  - /' >&2
    printf 'Try forcing one provider with --catalog-provider NAME, or use --debug for diagnostics.\n' >&2
    return 1
}

catalog_detail() {
    action=$1
    shift
    name=$active_catalog_provider
    if run_provider catalog "$name" "$action" "$@"; then
        detail_response=$(cat "$provider_stdout")
        [ -n "$detail_response" ] && return 0
        provider_message="$name returned an empty response"
    fi
    [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
    error "Catalog provider '$name' could not load $action for '$title': $provider_message"
    printf 'Try searching for the title with another catalog provider using --catalog-provider NAME.\n' >&2
    return 1
}

choose_line() {
    prompt=$1
    columns=$2
    input=$3

    [ -n "$input" ] || return 1
    if [ "$select_first" = "true" ]; then
        printf '%s\n' "$input" | head -n 1
        return
    fi

    require_command fzf
    printf '%s\n' "$input" | fzf --cycle --reverse --delimiter="$(printf '\t')" --with-nth="$columns" --prompt="$prompt"
}

extract_field() {
    printf '%s' "$1" | cut -f"$2"
}

select_media() {
    choice=$(choose_line 'Choose a movie or TV show: ' 4 "$response") || exit 0
    image_link=$(extract_field "$choice" 1)
    media_ref=$(extract_field "$choice" 2)
    media_type=$(extract_field "$choice" 3)
    title=$(extract_field "$choice" 4)
    result_provider=$(extract_field "$choice" 5)
    [ -n "$result_provider" ] && active_catalog_provider=$result_provider

    case "$media_type" in
        movie | tv) ;;
        *) fatal "Catalog provider '$active_catalog_provider' returned unsupported media type '$media_type'." ;;
    esac
}

select_tv_episode() {
    catalog_detail seasons "$media_ref" || exit 1
    season_choice=$(choose_line 'Choose a season: ' 1 "$detail_response") || exit 0
    season_title=$(extract_field "$season_choice" 1)
    season_number=$(extract_field "$season_choice" 2)

    catalog_detail episodes "$media_ref" "$season_number" || exit 1
    episode_choice=$(choose_line 'Choose an episode: ' 1 "$detail_response") || exit 0
    episode_title=$(extract_field "$episode_choice" 1)
    episode_number=$(extract_field "$episode_choice" 2)
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

extract_embed() {
    embed_url=$1
    media_id=$2
    extractor_errors=""

    for extractor_url in $extractor_urls; do
        extractor_out="$tmp_dir/extractor.json"
        extractor_err="$tmp_dir/extractor.err"
        escaped_embed=$(json_escape "$embed_url")
        escaped_id=$(json_escape "$media_id")
        log_debug "requesting stream extraction from $extractor_url"

        if curl -sS -X POST "$extractor_url" \
            -H 'Content-Type: application/json' \
            -d "{\"url\":\"$escaped_embed\",\"mediaId\":\"$escaped_id\"}" \
            -o "$extractor_out" 2>"$extractor_err"; then
            candidate_json=$(cat "$extractor_out")
            candidate_video=$(printf '%s' "$candidate_json" |
                sed -nE 's@.*"file":"([^"]+\.m3u8[^"]*)".*@\1@p' |
                head -n 1)
            if [ -n "$candidate_video" ]; then
                json_data=$candidate_json
                video_link=$candidate_video
                active_extractor=$extractor_url
                return 0
            fi
            message=$(printf '%s' "$candidate_json" | sed -nE 's@.*"(message|error)":"([^"]+)".*@\2@p' | head -n 1)
            [ -n "$message" ] || message="returned no playable HLS source"
        else
            message=$(cat "$extractor_err")
            [ -n "$message" ] || message="request failed"
        fi

        extractor_errors="${extractor_errors}${extractor_url}: ${message}\n"
    done

    return 1
}

resolve_stream() {
    provider_errors=""
    names=$(provider_names "$stream_provider" "$stream_provider_order")

    for name in $names; do
        provider_message=""
        if run_provider stream "$name" "$media_type" "$media_ref" "${season_number:-}" "${episode_number:-}" "$subs_language"; then
            embed_link=$(head -n 1 "$provider_stdout")
            if [ -z "$embed_link" ]; then
                provider_message="$name returned an empty embed URL"
            elif extract_embed "$embed_link" "$media_ref"; then
                active_stream_provider=$name
                log_debug "stream provider '$name' resolved through '$active_extractor'"
                return 0
            else
                provider_message="embed was created, but every extractor failed"
                if [ -n "$extractor_errors" ]; then
                    provider_message="$provider_message: $(printf '%b' "$extractor_errors" | tr '\n' ';' | sed 's/;$//')"
                fi
            fi
        fi

        [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
        append_provider_error "$name" "$provider_message"
    done

    error "No stream provider could resolve a playable source for '$title'."
    printf '%b' "$provider_errors" | sed 's/^/  - /' >&2
    printf 'The catalog result was valid; playback providers or extractors failed.\n' >&2
    printf 'Try --stream-provider NAME to test one provider, or --debug for diagnostics.\n' >&2
    return 1
}

prepare_subtitles() {
    subs_links=""
    [ "$no_subs" = "true" ] && return 0

    subs_links=$(printf '%s' "$json_data" | tr '{' '\n' |
        sed -nE "s@.*\"file\":\"([^\"]+)\".*\"label\":\"[^\"]*${subs_language}[^\"]*\".*@\1@Ip")
}

apply_quality() {
    [ -n "$quality" ] || return 0
    video_link=$(printf '%s' "$video_link" | sed "s@/playlist\.m3u8@/$quality/index.m3u8@")
}

play_or_download() {
    displayed_title=$title
    if [ "$media_type" = "tv" ]; then
        displayed_title="$title - $season_title - $episode_title"
    fi

    if [ "$json_output" = "true" ]; then
        printf '%s\n' "$json_data"
        return
    fi

    prepare_subtitles
    apply_quality

    if [ "$download" = "true" ]; then
        require_command ffmpeg
        safe_title=$(printf '%s' "$displayed_title" | tr '/:' '__')
        output_file="$download_dir/$safe_title.mkv"
        printf 'Downloading to %s\n' "$output_file"
        ffmpeg -loglevel error -stats -i "$video_link" -c copy "$output_file"
        return
    fi

    case "$player" in
        mpv | mpv.exe)
            require_command "$player"
            set -- "$player" "--force-media-title=$displayed_title"
            [ -n "$subs_links" ] && set -- "$@" "--sub-files=$(printf '%s' "$subs_links" | paste -sd: -)"
            set -- "$@" "$video_link"
            "$@"
            ;;
        *)
            require_command "$player"
            "$player" "$video_link"
            ;;
    esac
}

next_value() {
    option=$1
    value=${2:-}
    [ -n "$value" ] || fatal "$option requires a value."
    case "$value" in
        -*) fatal "$option requires a value, got '$value'." ;;
    esac
    printf '%s\n' "$value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --catalog-provider)
            catalog_provider=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        --stream-provider | -p | --provider)
            stream_provider=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        --list-providers)
            list_providers
            exit 0
            ;;
        -r | --recent)
            recent=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        -t | --trending)
            trending="true"
            shift
            ;;
        -l | --language)
            subs_language=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        -q | --quality)
            quality=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        -n | --no-subs)
            no_subs="true"
            shift
            ;;
        -j | --json)
            json_output="true"
            shift
            ;;
        -d | --download)
            download="true"
            if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
                download_dir=$2
                shift 2
            else
                shift
            fi
            ;;
        --player)
            player=$(next_value "$1" "${2:-}")
            shift 2
            ;;
        --select-first)
            select_first="true"
            shift
            ;;
        -e | --edit)
            editor=${VISUAL:-${EDITOR:-nano}}
            mkdir -p "$(dirname "$config_file")"
            [ -e "$config_file" ] || : >"$config_file"
            exec "$editor" "$config_file"
            ;;
        -x | --debug)
            debug="true"
            shift
            ;;
        -v | -V | --version)
            printf 'lobster %s\n' "$LOBSTER_VERSION"
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            query=$*
            break
            ;;
        -*) fatal "Unknown option '$1'. Run '${0##*/} --help'." ;;
        *)
            if [ -n "$query" ]; then
                query="$query $1"
            else
                query=$1
            fi
            shift
            ;;
    esac
done

validate_provider_name catalog "$catalog_provider"
validate_provider_name stream "$stream_provider"
require_command curl
require_command sed
require_command awk
require_command grep

if [ "$trending" = "true" ]; then
    catalog_lookup trending || exit 1
elif [ -n "$recent" ]; then
    case "$recent" in
        movie | movies) recent="movie" ;;
        tv | show | shows) recent="tv" ;;
        *) fatal "--recent accepts 'movie' or 'tv', got '$recent'." ;;
    esac
    catalog_lookup recent "$recent" || exit 1
else
    if [ -z "$query" ]; then
        printf 'Search Movie/TV Show: '
        IFS= read -r query
    fi
    [ -n "$query" ] || fatal "No search query was provided."
    catalog_lookup search "$query" || exit 1
fi

select_media
if [ "$media_type" = "tv" ]; then
    select_tv_episode
fi
resolve_stream || exit 1
play_or_download
