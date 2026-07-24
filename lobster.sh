#!/usr/bin/env sh

LOBSTER_VERSION="4.7.0"

### General Variables ###
config_file="$HOME/.config/lobster/lobster_config.sh"
lobster_editor=${VISUAL:-${EDITOR}}
tmp_dir="${TMPDIR:-/tmp}/lobster" && mkdir -p "$tmp_dir"
lobster_socket="${TMPDIR:-/tmp}/lobster.sock" # Used by mpv (check the play_video function)
lobster_logfile="${TMPDIR:-/tmp}/lobster.log"
applications="$HOME/.local/share/applications/lobster" # Used for external menus (for now just rofi)
images_cache_dir="$tmp_dir/lobster-images"             # Used for storing downloaded images of movie covers
STATE=""                                               # Used for main state machine

# Constants
nl='
' # Literal newline for use in pattern matching
# These are not arbitrary, but determined by rofi kb-custom-1 and kb-custom-2 exit codes
BACK_CODE=10
FORWARD_CODE=11
API_URL="https://dec.eatmynerds.live"
API_FALLBACK_URL="https://decrypt.broggl.farm"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)

### Notifications ###
command -v notify-send >/dev/null 2>&1 && notify="true" || notify="false" # check if notify-send is installed
# send_notification [message] [timeout] [icon] [title]
send_notification() {
    [ "$json_output" = "true" ] && return
    if [ "$use_external_menu" = "false" ] || [ -z "$use_external_menu" ]; then
        [ -z "$4" ] && printf "\33[2K\r\033[1;34m%s\n\033[0m" "$1" && return
        [ -n "$4" ] && printf "\33[2K\r\033[1;34m%s - %s\n\033[0m" "$1" "$4" && return
    fi
    [ -z "$2" ] && timeout=3000 || timeout="$2" # default timeout is 3 seconds
    if [ "$notify" = "true" ]; then
        [ -z "$3" ] && notify-send "$1" "$4" -t "$timeout" -h string:x-dunst-stack-tag:vol # the -h string:x-dunst-stack-tag:vol is used for overriding previous notifications
        [ -n "$3" ] && notify-send "$1" "$4" -t "$timeout" -i "$3" -h string:x-dunst-stack-tag:vol
    fi
}

### HTML Decoding ###

### Discord Rich Presence Variables ###
# Note: experimental feature
presence_client_id="1239340948048187472" # Discord Client ID
# shellcheck disable=SC2154
discord_ipc="${XDG_RUNTIME_DIR}/discord-ipc-0" # Discord IPC Socket (Could also be discord-ipc-1 if using arRPC afaik)
handshook="$tmp_dir/handshook"                 # Indicates if the RPC handshake has been done
ipclog="$tmp_dir/ipclog"                       # Logs the RPC events
presence="$tmp_dir/presence"                   # Used by the rich presence function
small_image="https://www.pngarts.com/files/9/Juvenile-American-Lobster-PNG-Transparent-Image.png"

### OS Specific Variables ###
separator=':'             # default value
path_thing="\\"           # default value
sed='sed'                 # default value
ueberzugpp_tmp_dir="/tmp" # for some reason ueberzugpp only uses $TMPDIR on Darwin
# shellcheck disable=SC2249
case "$(uname -s)" in
    MINGW* | *Msys) separator=';' && path_thing='' ;;
    *arwin) sed="gsed" && ueberzugpp_tmp_dir="${TMPDIR:-/tmp}" ;;
esac

# Checks if any of the provided arguments are -e or --edit
# If so, it will edit the config file
# This was added for pure convenience (for me)
if printf "%s" "$*" | grep -qE "\-\-edit|\-e" 2>/dev/null; then
    #shellcheck disable=1090
    . "${config_file}"
    [ -z "$lobster_editor" ] && lobster_editor="nano"
    "$lobster_editor" "$config_file"
    exit 0
fi

### Cleanup Functions ###
rpc_cleanup() {
    pkill -f "nc -U $discord_ipc" >/dev/null
    pkill -f "tail -f $presence" >/dev/null
    rm "$handshook" "$ipclog" "$presence" >/dev/null
}
cleanup() {
    [ "$debug" != "true" ] && rm -rf "$tmp_dir"
    [ "$remove_tmp_lobster" = "true" ] && rm -rf "$tmp_dir"

    if [ "$image_preview" = "true" ] && [ "$use_external_menu" = "false" ] && [ "$use_ueberzugpp" = "true" ]; then
        killall ueberzugpp 2>/dev/null
        rm -f "$ueberzugpp_tmp_dir"/ueberzugpp-*
    fi
    set +x && exec 2>&-
}
trap cleanup EXIT INT TERM

### Help Function ###
usage() {
    printf "
  Usage: %s [options] [query]
  If a query is provided, it will be used to search for a Movie/TV Show

  Options:
    -c, --continue
      Continue watching from current history
    -d, --download [path]
      Downloads movie or episode that is selected (if no path is provided, it defaults to the current directory)
    --discord, --discord-presence, --rpc, --presence
      Enables discord rich presence (beta feature, but should work fine on Linux)
    -e, --edit
      Edit config file using an editor defined with lobster_editor in the config (\$EDITOR by default)
    -h, --help
      Show this help message and exit
    -i, --image-preview
      Shows image previews during media selection (requires chafa, you can optionally use ueberzugpp)
    -j, --json
      Outputs the json containing video links, subtitle links, referrers etc. to stdout
    -l, --language [language]
      Specify the subtitle language (if no language is provided, it defaults to english)
    --rofi, --external-menu
      Use rofi instead of fzf
    -n, --no-subs
      Disable subtitles
    --catalog-provider [provider]
      Force a catalog provider instead of automatic fallback (currently supported: tmdb, imdb)
    -p, --provider, --stream-provider [provider]
      Force a stream provider instead of automatic fallback (currently supported: vidapi, vidcore)
    --list-providers
      Show installed catalog and stream providers and their fallback order
    -q, --quality
      Specify the video quality (if no quality is provided, it defaults to 1080)
    -r, --recent [movies|tv]
      Lets you select from the most recent movies or tv shows (if no argument is provided, it defaults to movies)
    -s, --syncplay
      Use Syncplay to watch with friends
    -t, --trending
      Lets you select from the most popular movies and shows
    -u, -U, --update
      Update the script
    -v, -V, --version
      Show the version of the script
    -x, --debug
      Enable debug mode (prints out debug info to stdout and also saves it to \$TEMPDIR/lobster.log)

  Note:
    All arguments can be specified in the config file as well.
    If an argument is specified in both the config file and the command line, the command line argument will be used.

  Some example usages:
    ${0##*/} -i a silent voice --rofi
    ${0##*/} -l spanish -q 720 fight club -i -d
    ${0##*/} -l spanish blade runner --json

" "${0##*/}"
}

### Dependencies Check ###
dep_ch() {
    for dep; do
        if ! command -v "$dep" >/dev/null; then
            send_notification "Program \"$dep\" not found. Please install it."
            exit 1
        fi
    done
}

### Default Configuration ###
# this function is ran after the user's config file is "checked" (source'd)
configuration() {
    [ -n "$XDG_CONFIG_HOME" ] && config_dir="$XDG_CONFIG_HOME/lobster" || config_dir="$HOME/.config/lobster"
    [ -n "$XDG_DATA_HOME" ] && data_dir="$XDG_DATA_HOME/lobster" || data_dir="$HOME/.local/share/lobster"
    [ ! -d "$config_dir" ] && mkdir -p "$config_dir"
    [ ! -d "$data_dir" ] && mkdir -p "$data_dir"
    #shellcheck disable=1090
    [ -f "$config_file" ] && . "${config_file}" # source the user's config file
    [ -z "$player" ] && player="mpv"
    [ -z "$download_dir" ] && download_dir="$PWD"
    [ -z "$catalog_provider" ] && catalog_provider="auto"
    [ -z "$stream_provider" ] && stream_provider="auto"
    [ -z "$catalog_provider_order" ] && catalog_provider_order="tmdb imdb"
    [ -z "$stream_provider_order" ] && stream_provider_order="vidapi vidcore"
    [ -z "$subs_language" ] && subs_language="en"
    if [ -n "${LOBSTER_PROVIDER_DIR:-}" ]; then
        provider_dir="$LOBSTER_PROVIDER_DIR"
    elif [ -d "$script_dir/providers" ]; then
        provider_dir="$script_dir/providers"
    else
        provider_dir="$data_dir/providers"
    fi
    [ -z "$histfile" ] && histfile="$data_dir/lobster_history.txt" && mkdir -p "$(dirname "$histfile")"
    [ -z "$history" ] && history=false
    [ -z "$use_external_menu" ] && use_external_menu="false"
    [ -z "$image_preview" ] && image_preview="false"
    [ -z "$high_quality_image_preview" ] && high_quality_image_preview="false"
    [ -z "$debug" ] && debug="false"
    [ -z "$preview_window_size" ] && preview_window_size=right:60%:wrap
    if [ -z "$use_ueberzugpp" ]; then
        use_ueberzugpp="false"
    elif [ "$use_ueberzugpp" = "true" ]; then
        [ -z "$ueberzug_x" ] && ueberzug_x=10
        [ -z "$ueberzug_y" ] && ueberzug_y=3
        [ -z "$ueberzug_max_width" ] && ueberzug_max_width=$(($(tput lines) / 2))
        [ -z "$ueberzug_max_height" ] && ueberzug_max_height=$(($(tput lines) / 2))
    fi
    [ -z "$remove_tmp_lobster" ] && remove_tmp_lobster="true"
    [ -z "$json_output" ] && json_output="false"
    [ -z "$discord_presence" ] && discord_presence="false"
    case "$(uname -s)" in
        MINGW* | *Msys)
            if [ -z "$watchlater_dir" ]; then
                # shellcheck disable=SC2154
                case "$(command -v "$player")" in
                    *scoop*) watchlater_dir="$HOMEPATH/scoop/apps/mpv/current/portable_config/watch_later/" ;;
                    *) watchlater_dir="$LOCALAPPDATA/mpv/watch_later" ;;
                esac
            fi
            ;;
        *) [ -z "$watchlater_dir" ] && watchlater_dir="$tmp_dir/watchlater" && mkdir -p "$watchlater_dir" ;;
    esac
}

# The reason I use additional file descriptors is because of the use of tee
# which when piped into would hijack the terminal, which was unwanted behavior
# since there are SSH use cases for mpv and since I wanted to have a logging mechanism
exec 3>&1 4>&2 1>"$lobster_logfile" 2>&1
{
    # check that the necessary programs are installed
    dep_ch "grep" "$sed" "curl" "fzf" "jq" || true
    if [ "$use_external_menu" = "true" ]; then
        dep_ch "rofi" || true
    fi
    if [ "$player" = "mpv" ]; then
        dep_ch "awk" "nc" || true
    fi

    ### Launchers stuff (rofi, fzf, etc.) ###
    generate_desktop() {
        cat <<EOF
[Desktop Entry]
Name=$1
Exec=echo %k %c
Icon=$2
Type=Application
Categories=lobster;
EOF
    }
    # A launcher is a utility used to select an option from a list (fzf, rofi)
    # launcher [prompt] [columns-to-display]
    launcher() {
        case "$use_external_menu" in
            "true")
                [ -z "$2" ] && rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -sort -dmenu -i -width 1500 -p "" -mesg "$1"
                [ -n "$2" ] && rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -sort -dmenu -i -width 1500 -p "" -mesg "$1" -display-columns "$2"
                # Gives rc=10 on pressing kb-custom-1 and rc=11 on pressing kb-custom-2
                rc=$?
                ;;
            *)
                [ -z "$2" ] && fzf_out=$(fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --prompt "$1")
                [ -n "$2" ] && fzf_out=$(fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --prompt "$1" --with-nth "$2" -d "\t")
                rc=$?
                # Uses fzf expect to look for back button press
                case $fzf_out in
                    shift-left"$nl"*)
                        rc="$BACK_CODE"
                        fzf_out=${fzf_out#*"$nl"}
                        ;;
                    "$nl"*) fzf_out=${fzf_out#"$nl"} ;;
                    *) exit 1 ;; # Should not reach here
                esac
                printf '%s\n' "$fzf_out"
                ;;
        esac
        return "$rc"
    }
    # helper function to be able to display only an "nth" column in fzf/rofi without altering the stdin
    nth() {
        stdin=$(cat -)
        [ -z "$stdin" ] && return 1
        prompt="$1"
        [ $# -ne 1 ] && shift
        line=$(printf "%s" "$stdin" | $sed -nE "s@^(.*)\t[0-9:]*\t[0-9]*\t(tv|movie)(.*)@\1 (\2)\t\3@p" | cut -f1-3,6,7 | tr '\t' '|' | launcher "$prompt" | cut -d "|" -f 1)
        [ -n "$line" ] && printf "%s" "$stdin" | $sed -nE "s@^$line\t(.*)@\1@p" || exit 1
    }

    ### Provider orchestration ###
    provider_script() {
        printf "%s/%s/%s.sh\n" "$provider_dir" "$1" "$2"
    }
    provider_names() {
        if [ "$1" = "auto" ]; then
            printf "%s\n" "$2"
        else
            printf "%s\n" "$1"
        fi
    }
    validate_provider() {
        kind=$1
        name=$2
        [ "$name" = "auto" ] && return 0
        script=$(provider_script "$kind" "$name")
        if [ ! -x "$script" ]; then
            send_notification "Error" "5000" "" "Unknown $kind provider '$name'"
            printf "Available %s providers:\n" "$kind" >&2
            list_provider_files "$kind" | sed 's/^/  - /' >&2
            exit 1
        fi
    }
    list_provider_files() {
        kind=$1
        [ -d "$provider_dir/$kind" ] || return 0
        for script in "$provider_dir/$kind"/*.sh; do
            [ -f "$script" ] || continue
            basename "$script" .sh
        done
    }
    list_providers() {
        printf "Catalog fallback order: %s\n" "$catalog_provider_order"
        list_provider_files catalog | sed 's/^/  - /'
        printf "Stream fallback order: %s\n" "$stream_provider_order"
        list_provider_files stream | sed 's/^/  - /'
    }
    run_provider() {
        provider_kind=$1
        provider_name=$2
        shift 2
        provider_path=$(provider_script "$provider_kind" "$provider_name")
        provider_stdout="$tmp_dir/provider.out"
        provider_stderr="$tmp_dir/provider.err"
        : >"$provider_stdout"
        : >"$provider_stderr"

        if [ ! -x "$provider_path" ]; then
            printf "%s provider is not installed at %s\n" "$provider_name" "$provider_path" >"$provider_stderr"
            provider_status=127
        else
            "$provider_path" "$@" >"$provider_stdout" 2>"$provider_stderr"
            provider_status=$?
        fi
        provider_message=$(cat "$provider_stderr")
        if [ "$debug" = "true" ] && [ -n "$provider_message" ]; then
            printf "[%s/%s] %s\n" "$provider_kind" "$provider_name" "$provider_message" >&2
        fi
        return "$provider_status"
    }
    append_provider_error() {
        provider_errors="${provider_errors}${1}: ${2}\n"
    }
    print_provider_errors() {
        printf '%b' "$provider_errors" | sed 's/^/  - /' >&2
    }
    catalog_request() {
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
                    return 0
                fi
                provider_status=4
                provider_message="$name returned an empty response"
            fi
            [ "$provider_status" -eq 2 ] || all_no_results="false"
            [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
            append_provider_error "$name" "$provider_message"
        done

        if [ "$all_no_results" = "true" ]; then
            send_notification "Error" "5000" "" "No matching movies or TV shows were found"
        else
            send_notification "Error" "5000" "" "Catalog lookup failed"
        fi
        print_provider_errors
        printf "Try --catalog-provider NAME to test one provider or --debug for diagnostics.\n" >&2
        return 1
    }
    catalog_detail() {
        action=$1
        shift
        detail_response=""
        detail_error=""
        if run_provider catalog "$active_catalog_provider" "$action" "$@"; then
            detail_response=$(cat "$provider_stdout")
            [ -n "$detail_response" ] && return 0
            provider_message="$active_catalog_provider returned an empty response"
        fi
        [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
        detail_error=$provider_message
        return 1
    }
    report_detail_error() {
        send_notification "Error" "5000" "" "Could not load $1 for '$title'"
        printf "  - %s: %s\n" "$active_catalog_provider" "$detail_error" >&2
    }
    prompt_number() {
        prompt=$1
        if [ "$use_external_menu" = "true" ]; then
            number=$(printf '' | rofi -dmenu -p "$prompt")
        else
            printf "%s: " "$prompt" >&3
            read -r number
        fi
        case "$number" in
            '' | *[!0-9]*) return 1 ;;
            *) printf "%s\n" "$number" ;;
        esac
    }

    ### User Prompts ###
    prompt_to_continue() {
        if [ "$media_type" = "tv" ]; then
            continue_choice=$(printf "Next episode\nReplay episode\nExit\nSearch" | launcher "Select: ")
        else
            continue_choice=$(printf "Exit\nSearch" | launcher "Select: ")
        fi
        rc=$?
        [ "$rc" -eq "$BACK_CODE" ] && exit 0
    }

    ### Searching/Selecting ###
    get_input() {
        if [ "$use_external_menu" = "false" ]; then
            printf "Search Movie/TV Show: " && read -r query
        else
            if [ -n "$rofi_prompt_config" ]; then
                query=$(printf "" | rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -theme "$rofi_prompt_config" -sort -dmenu -i -width 1500 -p "" -mesg "Search Movie/TV Show")
            else
                query=$(printf "" | launcher "Search Movie/TV Show")
            fi
        fi
        rc=$?
        # rofi return exit code 1 when user submits custom text, so check >1 for exit
        [ "$rc" -gt 1 ] && exit 0
        if [ -z "$query" ]; then
            send_notification "Error" "1000" "" "No query provided"
            exit 1
        fi
    }
    search() {
        catalog_request search "$1" || exit 1
    }
    choose_search() {
        if [ -z "$response" ]; then
            [ -z "$query" ] && get_input
            search "$query"
            [ -z "$response" ] && exit 1
        fi
        STATE="MEDIA"
    }
    choose_media() {
        if [ "$image_preview" = "true" ]; then
            if [ "$use_external_menu" = "false" ] && [ "$use_ueberzugpp" = "true" ]; then
                command -v "ueberzugpp" >/dev/null || send_notification "Please install ueberzugpp if you want to use it for image previews"
                use_ueberzugpp="false"
            fi
            maybe_download_thumbnails "$response"
            select_desktop_entry ""
            rc=$?

            choice=$(printf "%s\n" "$response" | awk -F '\t' -v id="$media_id" '$2 == id { print; exit }')
        else
            if [ "$use_external_menu" = "true" ]; then
                choice=$(printf "%s" "$response" | rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -dmenu -i -p "" -mesg "Choose a Movie or TV Show" -display-columns 4)
                rc=$?
            else
                choice=$(printf "%s" "$response" | fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --with-nth 4 -d "\t" --header "Choose a Movie or TV Show")
                rc=$?
                case $choice in
                    shift-left"$nl"*)
                        rc="$BACK_CODE"
                        choice=${choice#*"$nl"}
                        ;;
                    "$nl"*) choice=${choice#"$nl"} ;;
                    *) exit 1 ;;
                esac
            fi
        fi

        image_link=$(printf "%s" "$choice" | cut -f1)
        media_id=$(printf "%s" "$choice" | cut -f2)
        media_type=$(printf "%s" "$choice" | cut -f3)
        title=$(printf "%s" "$choice" | cut -f4 | $sed -E 's/ \[[^]]*\]$//')
        api_media_id=$(printf "%s" "$choice" | cut -f5)
        result_catalog_provider=$(printf "%s" "$choice" | cut -f6)
        [ -n "$result_catalog_provider" ] && active_catalog_provider=$result_catalog_provider

        if [ "$rc" -eq "$BACK_CODE" ]; then
            STATE="SEARCH"
            response=""
            query=""
            choice=""
            return 0
        elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
            exit 0
        fi

        if [ "$media_type" = "tv" ]; then
            STATE="SEASON"
        else
            keep_running="true"
            STATE="PLAY"
        fi
    }
    choose_season() {
        if catalog_detail seasons "$api_media_id"; then
            season_line=$(printf "%s\n" "$detail_response" | launcher "Select a season: " "1")
            rc=$?
            if [ "$rc" -eq "$BACK_CODE" ]; then
                STATE="MEDIA"
                return 0
            elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
                exit 0
            fi
            [ -z "$season_line" ] && exit 1
            season_title=$(printf '%s' "$season_line" | cut -f1)
            season_id=$(printf '%s' "$season_line" | cut -f2)
        else
            report_detail_error "seasons"
            season_id=$(prompt_number "Enter season number manually") || exit 1
            season_title="Season $season_id"
        fi
        STATE="EPISODE"
    }
    choose_episode() {
        if catalog_detail episodes "$api_media_id" "$season_id"; then
            ep_line=$(printf "%s\n" "$detail_response" | launcher "Select an episode: " "1")
            rc=$?
            if [ "$rc" -eq "$BACK_CODE" ]; then
                STATE="SEASON"
                return 0
            elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
                exit 0
            fi
            [ -z "$ep_line" ] && exit 1
            episode_title=$(printf '%s' "$ep_line" | cut -f1)
            episode_id=$(printf '%s' "$ep_line" | cut -f2)
        else
            report_detail_error "episodes"
            episode_id=$(prompt_number "Enter episode number manually") || exit 1
            episode_title="Episode $episode_id"
        fi
        data_id=$episode_id
        keep_running="true"
        STATE="PLAY"
    }
    next_episode_exists() {
        next_episode=""
        if catalog_detail episodes "$api_media_id" "$season_id"; then
            next_episode=$(printf "%s\n" "$detail_response" | awk -F '\t' -v current="$episode_id" '$2 == current { getline; print; exit }')
            [ -n "$next_episode" ] && return
        else
            return
        fi

        if catalog_detail seasons "$api_media_id"; then
            next_season=$(printf "%s\n" "$detail_response" | awk -F '\t' -v current="$season_id" '$2 == current { getline; print; exit }')
            [ -n "$next_season" ] || return
            season_title=$(printf "%s" "$next_season" | cut -f1)
            season_id=$(printf "%s" "$next_season" | cut -f2)
            if catalog_detail episodes "$api_media_id" "$season_id"; then
                next_episode=$(printf "%s\n" "$detail_response" | head -n 1)
            fi
        fi
    }

    ### Image Preview ###
    maybe_download_thumbnails() {
        # Only downloads thumbnails again if every thumbnail is not already in images_cache_dir
        need_dl=0
        tab="$(printf '\t')"

        # keep the while-loop in the current shell
        while IFS="$tab" read -r cover_url id type title _; do
            [ -z "$cover_url" ] && continue # skip empty lines
            poster="$images_cache_dir/  $title ($type)  $id.jpg"
            [ ! -f "$poster" ] && need_dl=1 && break # one miss is enough
        done <<EOF
$1
EOF

        if [ "$need_dl" -eq 1 ]; then
            rm -f "$images_cache_dir"/* 2>/dev/null
            download_thumbnails "$1"
        fi
    }
    poster_path_for_media() {
        printf "%s/  %s (%s)  %s.jpg\n" "$images_cache_dir" "$1" "$2" "$3"
    }
    download_thumbnails() {
        pids=""
        tab="$(printf '\t')"

        # run the while-loop in the current shell
        while IFS="$tab" read -r cover_url id type title _; do
            [ -z "$cover_url" ] && continue                    # skip empty lines
            printf '%s\n' "$cover_url" >"$tmp_dir/image_links" # For Discord rich presence

            # Sets res to 1000x1000
            cover_url=$(printf '%s\n' "$cover_url" |
                sed -E 's:/[0-9]+x[0-9]+/:/1000x1000/:')

            poster_path=$(poster_path_for_media "$title" "$type" "$id")
            curl -s -o "$poster_path" "$cover_url" &
            pids="$pids $!"

            if [ "$use_external_menu" = "true" ]; then
                entry="$tmp_dir/applications/$id.desktop"
                # The reason for the spaces is so that only the title can be displayed when using rofi
                # or fzf, while still keeping the id and type in the string after it's selected
                generate_desktop "$title ($type)  $id" "$poster_path" >"$entry" &
                pids="$pids $!"
            fi
        done <<EOF
$1
EOF

        # Wait for background jobs to finish
        for pid in $pids; do
            wait "$pid" 2>/dev/null
        done
    }
    # defaults to chafa
    image_preview_fzf() {
        preview_input=$(
            printf "%s\n" "$response" |
                while IFS="$(printf '\t')" read -r cover_url id type title _; do
                    [ -z "$cover_url" ] && continue
                    poster_path=$(poster_path_for_media "$title" "$type" "$id")
                    printf "%s\t%s (%s)\t%s\t%s\t%s\n" \
                        "$poster_path" \
                        "$title" "$type" "$id" "$type" "$title"
                done
        )

        if [ "$use_ueberzugpp" = "true" ]; then
            UB_PID_FILE="$tmp_dir.$(uuidgen)"
            if [ -z "$ueberzug_output" ]; then
                ueberzugpp layer --no-stdin --silent --use-escape-codes --pid-file "$UB_PID_FILE"
            else
                ueberzugpp layer -o "$ueberzug_output" --no-stdin --silent --use-escape-codes --pid-file "$UB_PID_FILE"
            fi
            UB_PID="$(cat "$UB_PID_FILE")"
            LOBSTER_UEBERZUG_SOCKET="$ueberzugpp_tmp_dir/ueberzugpp-$UB_PID.socket"
            choice=$(printf "%s\n" "$preview_input" | fzf --bind "shift-right:accept" --expect=shift-left --cycle -i -q "$1" --cycle --preview-window="$preview_window_size" --preview="ueberzugpp cmd -s $LOBSTER_UEBERZUG_SOCKET -i fzfpreview -a add -x $ueberzug_x -y $ueberzug_y --max-width $ueberzug_max_width --max-height $ueberzug_max_height -f {1}" --reverse --with-nth 2 -d "$(printf '\t')")
            rc=$?

            case $choice in
                shift-left"$nl"*)
                    rc="$BACK_CODE"
                    choice=${choice#*"$nl"}
                    ;;
                "$nl"*) choice=${choice#*"$nl"} ;;
                *) exit 1 ;;
            esac
            ueberzugpp cmd -s "$LOBSTER_UEBERZUG_SOCKET" -a exit
        else
            dep_ch "chafa" || true
            [ "${TERM_PROGRAM:-}" = "vscode" ] && fmt="--margin-bottom 8"
            dim="-s ${chafa_dims:-40x30}"
            if [ "$high_quality_image_preview" = "true" ]; then
                chafa_cmd="chafa --animate off $fmt $dim"
            else
                chafa_cmd="chafa --format symbols --polite on --animate off $fmt $dim"
            fi
            choice=$(printf "%s\n" "$preview_input" | fzf \
                --bind "shift-right:accept" --expect=shift-left --cycle -i -q "$1" \
                --preview-window="$preview_window_size" \
                --preview="$chafa_cmd {1}" \
                --reverse --with-nth 2 -d "$(printf '\t')")
            rc=$?

            case $choice in
                shift-left"$nl"*)
                    rc="$BACK_CODE"
                    choice=${choice#*"$nl"}
                    ;;
                "$nl"*) choice=${choice#*"$nl"} ;;
                *) exit 1 ;;
            esac
        fi
        return "$rc"
    }
    select_desktop_entry() {
        if [ "$use_external_menu" = "true" ]; then
            if [ -n "$image_config_path" ]; then
                rofi_out=$(rofi -show drun -drun-categories lobster -filter "$1" -show-icons -theme "$image_config_path")
            else
                rofi_out=$(rofi -show drun -drun-categories lobster -filter "$1" -show-icons)
            fi
            rc=$?
            choice=$(echo "$rofi_out" | $sed -nE "s@.*/([^/]*)\.desktop@\1@p") 2>/dev/null

            [ -z "$choice" ] && exit 0

            media_id=$(printf "%s" "$choice" | cut -d\  -f1)
            title=$(printf "%s" "$choice" | $sed -nE "s@[^ ]* (.*) \((tv|movie)\)@\1@p")
            media_type=$(printf "%s" "$choice" | $sed -nE "s@[^ ]* (.*) \((tv|movie)\)@\2@p")
        else
            image_preview_fzf "$1"
            rc=$?
            tput reset
            media_id=$(printf "%s" "$choice" | cut -f3)
            media_type=$(printf "%s" "$choice" | cut -f4)
            title=$(printf "%s" "$choice" | cut -f5)
        fi
        return "$rc"
    }

    ### Stream provider resolution ###
    extract_embed_url() {
        embed_to_extract=$1
        extractor_errors=""
        for extractor_url in "$API_URL" "$API_FALLBACK_URL"; do
            extractor_error_file="$tmp_dir/extractor.err"
            json_data=$(curl -sS -X POST "$extractor_url" \
                -H "Content-Type: application/json" \
                -d "{\"url\": \"$embed_to_extract\", \"mediaId\": \"${api_media_id#*:}\"}" \
                2>"$extractor_error_file")
            curl_status=$?
            if [ "$curl_status" -eq 0 ]; then
                video_link=$(printf "%s" "$json_data" | jq -r '.. | objects | .file? // empty' 2>/dev/null | grep -E '\.m3u8($|\?)' | head -n 1)
                [ -n "$video_link" ] && return 0
                extractor_message=$(printf "%s" "$json_data" | jq -r '.message // .error // empty' 2>/dev/null | head -n 1)
                [ -n "$extractor_message" ] || extractor_message="returned no playable HLS source"
            else
                extractor_message=$(cat "$extractor_error_file")
                [ -n "$extractor_message" ] || extractor_message="request failed"
            fi
            extractor_errors="${extractor_errors}${extractor_url}: ${extractor_message}; "
        done
        return 1
    }
    resolve_stream() {
        provider_errors=""
        names=$(provider_names "$stream_provider" "$stream_provider_order")
        for name in $names; do
            if run_provider stream "$name" "$media_type" "$api_media_id" "$season_id" "$episode_id" "$subs_language"; then
                embed_link=$(head -n 1 "$provider_stdout")
                if [ -z "$embed_link" ]; then
                    provider_message="$name returned an empty embed URL"
                elif extract_embed_url "$embed_link"; then
                    break
                else
                    provider_message="embed URL was created, but extraction failed: $extractor_errors"
                fi
            fi
            [ -n "$provider_message" ] || provider_message="failed with exit code $provider_status"
            append_provider_error "$name" "$provider_message"
            video_link=""
        done

        if [ -z "$video_link" ]; then
            send_notification "Error" "5000" "" "No stream provider returned a playable source for '$title'"
            print_provider_errors
            printf "The catalog lookup succeeded; playback providers or extractors failed.\n" >&2
            printf "Try --stream-provider NAME to test one provider or --debug for diagnostics.\n" >&2
            return 1
        fi

        [ -n "$quality" ] && video_link=$(printf "%s" "$video_link" | sed -e "s|/playlist.m3u8|/$quality/index.m3u8|")
        [ "$json_output" = "true" ] && printf "%s\n" "$json_data" && exit 0

        if [ "$no_subs" = "true" ]; then
            send_notification "Continuing without subtitles"
        else
            subs_links=$(printf "%s" "$json_data" | tr '{' '\n' | $sed -n "s/.*\"file\":\"\([^\"]*\)\".*\"label\":\"[^\"]*${subs_language}[^\"]*\".*/\1/Ip")
            if [ -z "$subs_links" ]; then
                send_notification "No subtitles found for language '$subs_language'"
                subs_arg=""
            else
                subs_arg="--sub-file"
                num_subs=$(printf "%s" "$subs_links" | wc -l | tr -d ' ')
                if [ "$num_subs" -gt 0 ]; then
                    subs_links=$(printf "%s" "$subs_links" | sed -e "s/:/\\$path_thing:/g" -e "H;1h;\$!d;x;y/\n/$separator/" -e "s/$separator\$//")
                    subs_arg="--sub-files"
                fi
            fi
        fi
    }

    check_history() {
        if [ ! -f "$histfile" ]; then
            if [ "$image_preview" = "true" ]; then
                send_notification "Now Playing" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
            elif [ "$json_output" != "true" ]; then
                send_notification "Now Playing" "5000" "" "$title"
            fi
            return
        fi
        case $media_type in
            movie)
                if grep -q "$media_id" "$histfile"; then
                    resume_from=$(grep "$media_id" "$histfile" | cut -f2)
                    send_notification "Resuming from" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$resume_from"
                else
                    send_notification "Now Playing" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                fi
                ;;
            tv)
                if grep -q "$media_id" "$histfile"; then
                    if grep -q "$episode_id" "$histfile"; then
                        [ -z "$resume_from" ] && resume_from=$($sed -nE "s@.*\t([0-9:]*)\t$media_id\ttv\t$season_id.*@\1@p" "$histfile")
                        send_notification "$season_title" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$episode_title"
                    fi
                else
                    send_notification "$season_title" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$episode_title"
                fi
                ;;
            *) send_notification "This media type is not supported" ;;

        esac
    }

    save_history() {
        [ -z "$image_link" ] && image_link="$(grep "$media_id" "$tmp_dir/image_links" | cut -f1)"
        case $media_type in
            movie)
                if [ "$progress" -gt "90" ]; then
                    $sed -i "/$media_id/d" "$histfile"
                    send_notification "Deleted from history" "5000" "" "$title"
                else
                    if grep -q -- "$media_id" "$histfile" 2>/dev/null; then
                        $sed -i "s|^.*\t$media_id\t.*$|$title\t$position\t$media_id\t$media_type\t$image_link\t$api_media_id|" "$histfile"
                        send_notification "Saved to history" "5000" "" "$title"
                    else
                        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$title" "$position" "$media_id" "$media_type" "$image_link" "$api_media_id" >>"$histfile"
                        send_notification "Saved to history" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                    fi
                fi
                ;;
            tv)
                if [ "$progress" -gt "90" ]; then
                    next_episode_exists
                    if [ -n "$next_episode" ]; then
                        position="00:00:00"
                        episode_title=$(printf "%s" "$next_episode" | cut -f1)
                        data_id=$(printf "%s" "$next_episode" | cut -f2)
                        episode_id=$data_id
                        send_notification "Updated to next episode" "5000" "" "$episode_title"
                    else
                        $sed -i "/$media_id/d" "$histfile"
                        send_notification "Completed" "5000" "" "$title"
                        return
                    fi
                else
                    send_notification "Saved to history" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                fi

                # If entry exists in hist file then update it, otherwise append new line
                if grep -q -- "$media_id" "$histfile" 2>/dev/null; then
                    $sed -i "s|^.*\t$media_id\t.*$|$title\t$position\t$media_id\t$media_type\t$season_id\t$episode_id\t$season_title\t$episode_title\t$data_id\t$image_link\t$api_media_id|" "$histfile"
                else
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$title" "$position" "$media_id" "$media_type" \
                        "$season_id" "$episode_id" "$season_title" "$episode_title" "$data_id" "$image_link" "$api_media_id" >>"$histfile"
                fi
                ;;
            *) notify-send "Error" "Unknown media type" ;;
        esac
    }
    play_from_history() {
        [ ! -f "$histfile" ] && send_notification "No history file found" "5000" "" && exit 1
        [ "$watched_history" = 1 ] && exit 0
        watched_history=1

        if [ "$image_preview" = "true" ]; then
            test -d "$images_cache_dir" || mkdir -p "$images_cache_dir"
            if [ "$use_external_menu" = "true" ]; then
                mkdir -p "$tmp_dir/applications/"
                [ ! -L "$applications" ] && ln -sf "$tmp_dir/applications/" "$applications"
            fi
            history_response=$(
                awk -F'\t' '
                {
                    title = $1
                    id    = $3
                    type  = $4
                    cover_url = (type == "tv") ? $10 : $5
                    print cover_url "\t" id "\t" type "\t" title
                }
                ' "$histfile"
            )

            maybe_download_thumbnails "$history_response"
            select_desktop_entry ""
            line=$(grep -m1 -F "$media_id" "$histfile")
            if [ "$media_type" = "tv" ]; then
                season_id=$(printf "%s" "$line" | cut -f5)
                episode_id=$(printf "%s" "$line" | cut -f6)
                season_title=$(printf "%s" "$line" | cut -f7)
                episode_title=$(printf "%s" "$line" | cut -f8)
                data_id=$(printf "%s" "$line" | cut -f9)
                image_link=$(printf "%s" "$line" | cut -f10)
                api_media_id=$(printf "%s" "$line" | cut -f11)
            else
                api_media_id=$(printf "%s" "$line" | cut -f6)
            fi
        else
            choice=$($sed -n "1h;1!{x;H;};\${g;p;}" "$histfile" | nl -w 1 | nth "Choose an entry: ")
            [ -z "$choice" ] && exit 1
            title=$(printf "%s" "$choice" | cut -f1)
            resume_from=$(printf "%s" "$choice" | cut -f2)
            media_id=$(printf "%s" "$choice" | cut -f3)
            media_type=$(printf "%s" "$choice" | cut -f4)
            if [ "$media_type" = "tv" ]; then
                season_id=$(printf "%s" "$choice" | cut -f5)
                episode_id=$(printf "%s" "$choice" | cut -f6)
                season_title=$(printf "%s" "$choice" | cut -f7)
                episode_title=$(printf "%s" "$choice" | cut -f8)
                data_id=$(printf "%s" "$choice" | cut -f9)
                image_link=$(printf "%s" "$choice" | cut -f10)
                api_media_id=$(printf "%s" "$choice" | cut -f11)
            else
                api_media_id=$(printf "%s" "$choice" | cut -f6)
            fi
        fi

        case "$api_media_id" in
            tmdb:*) active_catalog_provider="tmdb" ;;
            imdb:*) active_catalog_provider="imdb" ;;
            *)
                send_notification "Error" "5000" "" "This history entry predates catalog provider IDs"
                printf "Search for '%s' again to migrate the history entry.\n" "$title" >&2
                exit 1
                ;;
        esac

        STATE="PLAY" && keep_running="true" && loop
    }

    ### Discord Rich Presence ###
    set_activity() {
        len=${#1}
        printf "\\001\\000\\000\\000"
        for i in 0 8 16 24; do
            len=$((len >> i))
            #shellcheck disable=SC2059
            printf "\\$(printf "%03o" "$len")"
        done
        printf "%s" "$1"
    }
    update_rich_presence() {
        state=$1
        payload='{"cmd":"SET_ACTIVITY","args":{"pid":"786","activity":{"state":"'"$state"'","details":"'"$displayed_title"'","assets":{"large_image":"'"$image_link"'","large_text":"'"$title"'","small_image":"'"$small_image"'","small_text":"powered by lobster"}}},"nonce":"'"$(date)"'"}'
        if [ ! -e "$handshook" ]; then
            handshake='{"v":1,"client_id":"'$presence_client_id'"}'
            printf "\\000\\000\\000\\000\\$(printf "%03o" "${#handshake}")\\000\\000\\000%s" "$handshake" >"$presence"
            sleep 2
            touch "$handshook"
        fi
        set_activity "$payload" >"$presence"
    }

    ### Video Playback ###
    update_discord_presence() {
        total=$(printf "%02d:%02d:%02d" $((total_duration / 3600)) $((total_duration % 3600 / 60)) $((total_duration % 60)))

        [ -z "$image_link" ] && image_link="$(grep "$media_id" "$tmp_dir/image_links" | cut -f1)"
        sleep 2

        while :; do
            if command -v nc >/dev/null 2>&1 && [ -S "$lobster_socket" ] 2>/dev/null; then
                position=$(echo '{ "command": ["get_property", "time-pos"] }' | nc -U "$lobster_socket" 2>/dev/null | head -1)
                [ -z "$position" ] && break
                position=$(printf "%s" "$position" | sed -nE "s@.*\"data\":([0-9]*)\..*@\1@p")
                position=$(printf "%02d:%02d:%02d" $((position / 3600)) $((position % 3600 / 60)) $((position % 60)))
                update_rich_presence "$(printf "%s / %s" "$position" "$total")" &
            else
                # Fallback method if nc or Unix domain sockets are not available
                sleep 5
                update_rich_presence "Watching" &
            fi
            sleep 0.5
        done

        rpc_cleanup
    }
    save_progress() {
        position=$(cat "$watchlater_dir/"* 2>/dev/null | grep -A1 "$video_link" | $sed -nE "s@start=([0-9.]*)@\1@p" | cut -d'.' -f1)
        if [ -n "$position" ]; then
            progress=$((position * 100 / total_duration))
            position=$(printf "%02d:%02d:%02d" $((position / 3600)) $((position / 60 % 60)) $((position % 60)))
            send_notification "Stopped at" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$position"
        fi
    }
    play_video() {
        [ "$media_type" = "tv" ] && displayed_title="$title - $season_title - $episode_title" || displayed_title="$title"
        case $player in
            iina | celluloid)
                if [ -n "$subs_links" ]; then
                    [ "$player" = "iina" ] && iina --no-stdin --keep-running --mpv-sub-files="$subs_links" --mpv-force-media-title="$displayed_title" "$video_link"
                    [ "$player" = "celluloid" ] && celluloid --mpv-sub-files="$subs_links" --mpv-force-media-title="$displayed_title" "$video_link" 2>/dev/null
                else
                    [ "$player" = "iina" ] && iina --no-stdin --keep-running --mpv-force-media-title="$displayed_title" "$video_link"
                    [ "$player" = "celluloid" ] && celluloid --mpv-force-media-title="$displayed_title" "$video_link" 2>/dev/null
                fi
                ;;
            vlc)
                vlc_subs_links=$(printf "%s" "$subs_links" | sed 's/https\\:/https:/g; s/:\([^\/]\)/#\1/g')
                vlc "$video_link" --meta-title "$displayed_title" --input-slave="$vlc_subs_links"
                ;;
            mpv | mpv.exe)
                [ -z "$continue_choice" ] && check_history
                set -- "$player"
                [ -n "$resume_from" ] && set -- "$@" "--start=$resume_from"
                [ -n "$subs_links" ] && set -- "$@" "$subs_arg=$subs_links"
                set -- "$@" "--force-media-title=$displayed_title" "$video_link"
                case "$(uname -s)" in
                    MINGW* | *Msys) ;;
                    *) set -- "$@" "--watch-later-directory=$watchlater_dir" ;;
                esac
                set -- "$@" --write-filename-in-watch-later-config --save-position-on-quit --quiet

                # Check if the system supports Unix domain sockets
                if command -v nc >/dev/null 2>&1 && [ -S "$lobster_socket" ] 2>/dev/null; then
                    set -- "$@" "--input-ipc-server=$lobster_socket"
                fi

                "$@" >&3 &

                if [ -z "$quality" ]; then
                    link=$(printf "%s" "$video_link" | $sed "s/\/playlist.m3u8/\/1080\/index.m3u8/g")
                else
                    link=$video_link
                fi

                content=$(curl -s "$link")
                durations=$(printf "%s" "$content" | grep -oE 'EXTINF:[0-9.]+,' | cut -d':' -f2 | tr -d ',')
                total_duration=$(printf "%s" "$durations" | xargs echo | awk '{for(i=1;i<=NF;i++)sum+=$i} END {print sum}' | cut -d'.' -f1)

                [ "$discord_presence" = "true" ] && update_discord_presence
                wait
                save_progress
                ;;
            mpv_android) nohup am start --user 0 -a android.intent.action.VIEW -d "$video_link" -n is.xyz.mpv/.MPVActivity -e "title" "$displayed_title" >/dev/null 2>&1 & ;;
            iSH)
                # Check if $subs_links is not empty
                if [ -n "$subs_links" ]; then
                    first_sub=$(printf "%s" "$subs_links" | sed 's/https\\:/https:/g; s/:\([^\/]\)/#\1/g')
                else
                    first_sub=""
                fi
                printf "\e]8;;vlc-x-callback://x-callback-url/stream?url=%s&sub=%s\a~ Tap to open VLC ~\e]8;;\a\n" "$video_link" "$first_sub"
                sleep 5
                ;;
            *yncpla*) nohup "syncplay" "$video_link" -- --force-media-title="${displayed_title}" >/dev/null 2>&1 & ;;
            *) $player "$video_link" ;;
        esac
    }

    ### Misc ###
    update_script() {
        which_lobster="$(command -v lobster)"
        [ -z "$which_lobster" ] && send_notification "Can't find lobster in PATH" && exit 1
        case "$which_lobster" in
            /nix/store/*)
                send_notification "Installed through Nix" "5000" "" "Update the lobster-ng flake input and rebuild instead"
                exit 1
                ;;
        esac

        update=$(curl -s "https://raw.githubusercontent.com/Noah-Martinez/lobster-ng/main/lobster.sh" || exit 1)
        update="$(printf '%s\n' "$update" | diff -u "$which_lobster" -)"
        if [ -n "$update" ]; then
            if ! printf '%s\n' "$update" | patch "$which_lobster" -; then
                send_notification "Error" "5000" "" "Could not update the main script"
                exit 1
            fi
        fi

        mkdir -p "$provider_dir/catalog" "$provider_dir/stream"
        for provider_path in \
            catalog/tmdb.sh catalog/imdb.sh \
            stream/vidapi.sh stream/vidcore.sh; do
            if ! curl -fsSL "https://raw.githubusercontent.com/Noah-Martinez/lobster-ng/main/providers/$provider_path" \
                -o "$provider_dir/$provider_path"; then
                send_notification "Error" "5000" "" "Could not update provider $provider_path"
                exit 1
            fi
            chmod +x "$provider_dir/$provider_path"
        done
        send_notification "Lobster and its providers have been updated!"
        exit 0
    }
    # download_video [url] [title] [download_dir] [json_data] [thumbnail_file (only when image_preview is enabled)]
    download_video() {
        title="$(printf "%s" "$2" | tr -d ':/')"
        dir="${3}/${title}"
        # ik this is dumb idc
        language=$(printf "%s" "$4" | sed -nE "s@.*\"file\":\"[^\"]*\".*\"label\":\"(.$subs_language)[,\"\ ].*@\1@p")
        num_subs="$(printf "%s" "$subs_links" | sed 's/:\([^\/]\)/\n\\1/g' | wc -l)"
        ffmpeg_subs_links=$(printf "%s" "$subs_links" | sed 's/:\([^\/]\)/\nh/g; s/\\:/:/g' | while read -r sub_link; do
            printf " -i %s" "$sub_link"
        done)

        sub_ops=""
        ffmpeg_meta=""
        ffmpeg_maps=""

        if [ "$no_subs" = "true" ]; then
            # no subtitles
            sub_ops=""
        else
            sub_ops="$ffmpeg_subs_links -map 0:v -map 0:a"
            if [ "$num_subs" -eq 0 ]; then
                sub_ops=" -i $subs_links -map 0:v -map 0:a -map 1"
                ffmpeg_meta="-metadata:s:s:0 language=$language"
            else
                for i in $(seq 1 "$num_subs"); do
                    ffmpeg_maps="$ffmpeg_maps -map $i"
                    ffmpeg_meta="$ffmpeg_meta -metadata:s:s:$((i - 1)) language=$(printf "%s_%s" "$language" "$i")"
                done
            fi
            sub_ops="$sub_ops $ffmpeg_maps -c:v copy -c:a copy -c:s srt $ffmpeg_meta"
        fi

        # shellcheck disable=SC2086
        ffmpeg -loglevel error -stats -i "$1" $sub_ops -c copy "$dir.mkv"
    }

    choose_from_trending_or_recent() {
        path=$1
        case "$path" in
            home) catalog_request trending || exit 1 ;;
            movie) catalog_request recent movie || exit 1 ;;
            tv-show) catalog_request recent tv || exit 1 ;;
            *) send_notification "Error" "5000" "" "Unknown discovery category '$path'" && exit 1 ;;
        esac
        main
    }

    ### Main ###
    loop() {
        while [ "$keep_running" = "true" ]; do
            resolve_stream || exit 1
            if [ "$download" = "true" ]; then
                if [ "$media_type" = "movie" ]; then
                    if [ "$image_preview" = "true" ]; then
                        download_video "$video_link" "$title" "$download_dir" "$json_data" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" &
                        send_notification "Finished downloading" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                    else
                        download_video "$video_link" "$title" "$download_dir" "$json_data" &
                        send_notification "Finished downloading" "5000" "" "$title"
                    fi
                else
                    if [ "$image_preview" = "true" ]; then
                        download_video "$video_link" "$title - $season_title - $episode_title" "$download_dir" "$json_data" "$images_cache_dir/  $title - $season_title - $episode_title ($media_type)  $media_id.jpg" &
                        send_notification "Finished downloading" "5000" "$images_cache_dir/  $title - $season_title - $episode_title ($media_type)  $media_id.jpg" "$title - $season_title - $episode_title"
                    else
                        download_video "$video_link" "$title - $season_title - $episode_title" "$download_dir" "$json_data" &
                        send_notification "Finished downloading" "5000" "" "$title - $season_title - $episode_title"
                    fi
                fi
                exit
            fi
            if [ "$discord_presence" = "true" ]; then
                [ -p "$presence" ] || mkfifo "$presence"
                rm -f "$handshook" >/dev/null
                tail -f "$presence" | nc -U "$discord_ipc" >"$ipclog" &
                update_rich_presence "00:00:00" &
            fi
            play_video
            next_episode=""
            if [ -n "$position" ] && [ "$history" = "true" ]; then
                save_history
            fi
            prompt_to_continue
            case "$continue_choice" in
                "Next episode")
                    resume_from=""
                    if [ -z "$next_episode" ]; then
                        next_episode_exists
                    fi
                    if [ -n "$next_episode" ]; then
                        episode_title=$(printf "%s" "$next_episode" | cut -f1)
                        data_id=$(printf "%s" "$next_episode" | cut -f2)
                        episode_id=$data_id
                        send_notification "Watching the next episode" "5000" "" "$episode_title"
                    else
                        send_notification "No more episodes" "5000" "" "$title"
                        exit 0
                    fi
                    continue
                    ;;
                "Replay episode")
                    resume_from=""
                    continue
                    ;;
                "Search")
                    rm -f "$images_cache_dir"/*
                    query=""
                    response=""
                    season_id=""
                    episode_id=""
                    episode_title=""
                    title=""
                    data_id=""
                    resume_from=""
                    main
                    ;;
                *) keep_running="false" && exit ;;
            esac
        done
    }
    main() {
        STATE="SEARCH"
        while :; do
            case "$STATE" in
                SEARCH) choose_search ;;
                MEDIA) choose_media ;;
                SEASON) choose_season ;;
                EPISODE) choose_episode ;;
                PLAY) loop ;;
                EXIT) break ;;
                *) break ;;
            esac
        done
    }

    configuration
    active_catalog_provider="${active_catalog_provider:-tmdb}"

    # Edge case for Windows and Android, just exits with dep_ch's error message if it can't find mpv.exe or not on Android either
    if [ "$player" = "mpv" ] && ! command -v mpv >/dev/null; then
        if command -v mpv.exe >/dev/null; then
            player="mpv.exe"
        elif uname -a | grep -q "ndroid" 2>/dev/null; then
            player="mpv_android"
        elif uname -a | grep -q "ish" 2>/dev/null; then
            player="iSH"
        else
            dep_ch mpv.exe
        fi
    fi

    [ "$debug" = "true" ] && set -x
    query=""
    # Command line arguments parsing
    while [ $# -gt 0 ]; do
        case "$1" in
            --)
                shift
                query="$*"
                break
                ;;
            # TODO: don't immediately exit if --continue is passed, since this ignores other arguments as soon as -c or --continue is found
            -c | --continue) play_from_history && exit ;;
            --discord | --discord-presence | --rpc | --presence) discord_presence="true" && shift ;;
            -d | --download)
                download="true"
                if [ -n "$download_dir" ]; then
                    shift
                else
                    download_dir="$2"
                    if [ -z "$download_dir" ]; then
                        download_dir="$PWD"
                        shift
                    else
                        if [ "${download_dir#-}" != "$download_dir" ]; then
                            download_dir="$PWD"
                            shift
                        else
                            shift 2
                        fi
                    fi
                fi
                ;;
            -h | --help) usage && exit 0 ;;
            -i | --image-preview) image_preview="true" && shift ;;
            -j | --json) json_output="true" && shift ;;
            -l | --language)
                subs_language="$2"
                [ -z "$subs_language" ] && send_notification "Error" "5000" "" "--language requires a value" && exit 1
                shift 2
                ;;
            --rofi | --external-menu) use_external_menu="true" && shift ;;
            --catalog-provider)
                catalog_provider="$2"
                [ -z "$catalog_provider" ] && send_notification "Error" "5000" "" "--catalog-provider requires a value" && exit 1
                shift 2
                ;;
            -p | --provider | --stream-provider)
                stream_provider="$2"
                [ -z "$stream_provider" ] && send_notification "Error" "5000" "" "--stream-provider requires a value" && exit 1
                shift 2
                ;;
            --list-providers)
                list_providers
                exit 0
                ;;
            -q | --quality)
                quality="$2"
                if [ -z "$quality" ]; then
                    quality="1080"
                    shift
                else
                    if [ "${quality#-}" != "$quality" ]; then
                        quality="1080"
                        shift
                    else
                        shift 2
                    fi
                fi
                ;;
            -r | --recent)
                recent="$2"
                if [ -z "$recent" ]; then
                    recent="movie"
                    shift
                else
                    if [ "${recent#-}" != "$recent" ]; then
                        recent="movie"
                        shift
                    else
                        shift 2
                    fi
                fi
                ;;
            -s | --syncplay) player="syncplay" && shift ;;
            -t | --trending) trending="1" && shift ;;
            -u | -U | --update) update_script ;;
            -v | -V | --version) send_notification "Lobster Version: $LOBSTER_VERSION" && exit 0 ;;
            -x | --debug)
                set -x
                debug="true"
                shift
                ;;
            -n | --no-subs)
                no_subs="true" && shift
                ;;
            *)
                if [ "${1#-}" != "$1" ]; then
                    query="$query $1"
                else
                    query="$query $1"
                fi
                shift
                ;;
        esac
    done
    query="$(printf "%s" "$query" | $sed "s/^ //g")"
    if [ "$image_preview" = "true" ]; then
        test -d "$images_cache_dir" || mkdir -p "$images_cache_dir"
        if [ "$use_external_menu" = "true" ]; then
            mkdir -p "$tmp_dir/applications/"
            [ ! -L "$applications" ] && ln -sf "$tmp_dir/applications/" "$applications"
        fi
    fi
    validate_provider catalog "$catalog_provider"
    validate_provider stream "$stream_provider"
    [ "$trending" = "1" ] && choose_from_trending_or_recent "home" "trending-movies"
    [ "$recent" = "movie" ] && choose_from_trending_or_recent "movie" ""
    [ "$recent" = "tv" ] && choose_from_trending_or_recent "tv-show" ""

    main

} 2>&1 | tee "$lobster_logfile" >&3 2>&4
exec 1>&3 2>&4
