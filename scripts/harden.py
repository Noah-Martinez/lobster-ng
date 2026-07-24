#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_exact(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"maintenance transform failed for {label}: expected exactly one match, found {count}"
        )
    return text.replace(old, new, 1)


path = Path(sys.argv[1] if len(sys.argv) > 1 else "lobster.sh")
text = path.read_text()

text = replace_exact(
    text,
    r'''tmp_dir="${TMPDIR:-/tmp}/lobster" && mkdir -p "$tmp_dir"
lobster_socket="${TMPDIR:-/tmp}/lobster.sock" # Used by mpv (check the play_video function)
lobster_logfile="${TMPDIR:-/tmp}/lobster.log"''',
    r'''tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lobster.XXXXXXXX") || exit 1
chmod 700 "$tmp_dir"
lobster_socket="$tmp_dir/mpv.sock" # Used by mpv (check the play_video function)
lobster_logfile="$tmp_dir/lobster.log"''',
    "private temporary directory",
)

text = replace_exact(
    text,
    r'''dep_ch() {
    for dep; do
        if ! command -v "$dep" >/dev/null; then
            send_notification "Program \"$dep\" not found. Please install it."
            exit 1
        fi
    done
}
''',
    r'''dep_ch() {
    for dep; do
        if ! command -v "$dep" >/dev/null; then
            send_notification "Program \"$dep\" not found. Please install it."
            exit 1
        fi
    done
}

validate_https_url() {
    url=$1

    case "$url" in
        https://*) ;;
        *) return 1 ;;
    esac

    case "$url" in
        *"$nl"*) return 1 ;;
    esac

    return 0
}

validate_https_lines() {
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        validate_https_url "$url" || return 1
    done
}
''',
    "URL validators",
)

text = replace_exact(
    text,
    r'''        embed_link=$(curl -s "https://${base}/ajax/episode/sources/${episode_id}" | $sed -nE "s_.*\"link\":\"([^\"]*)\".*_\1_p")
        if [ -z "$embed_link" ]; then
            send_notification "Error" "Could not get embed link"
            exit 1
        fi
''',
    r'''        embed_link=$(curl -s "https://${base}/ajax/episode/sources/${episode_id}" | $sed -nE "s_.*\"link\":\"([^\"]*)\".*_\1_p")
        if [ -z "$embed_link" ]; then
            send_notification "Error" "Could not get embed link"
            exit 1
        fi
        if ! validate_https_url "$embed_link"; then
            send_notification "Error" "Rejected an unsafe embed URL"
            exit 1
        fi
''',
    "embed URL validation",
)

text = replace_exact(
    text,
    r'''        [ -n "$quality" ] && video_link=$(printf "%s" "$video_link" | sed -e "s|/playlist.m3u8|/$quality/index.m3u8|")

        [ "$json_output" = "true" ] && printf "%s\n" "$json_data" && exit 0
''',
    r'''        [ -n "$quality" ] && video_link=$(printf "%s" "$video_link" | sed -e "s|/playlist.m3u8|/$quality/index.m3u8|")

        if ! validate_https_url "$video_link"; then
            send_notification "Error" "Rejected an unsafe video URL"
            exit 1
        fi

        [ "$json_output" = "true" ] && printf "%s\n" "$json_data" && exit 0
''',
    "video URL validation",
)

text = replace_exact(
    text,
    r'''            if [ -z "$subs_links" ]; then
                send_notification "No subtitles found for language '$subs_language'"
                subs_arg=""
            else
                subs_arg="--sub-file"
''',
    r'''            if [ -z "$subs_links" ]; then
                send_notification "No subtitles found for language '$subs_language'"
                subs_arg=""
            else
                if ! printf '%s\n' "$subs_links" | validate_https_lines; then
                    send_notification "Error" "Rejected an unsafe subtitle URL"
                    exit 1
                fi
                subs_arg="--sub-file"
''',
    "subtitle URL validation",
)

text = replace_exact(
    text,
    r'''                player_cmd="$player"
                [ -n "$resume_from" ] && player_cmd="$player_cmd --start='$resume_from'"
                [ -n "$subs_links" ] && player_cmd="$player_cmd $subs_arg='$subs_links'"
                # Escape ' symbols in titles to prevent unterminated string error
                escaped_title=$(printf "%s" "$displayed_title" | "$sed" "s/'/'\\\\''/g")
                player_cmd="$player_cmd --force-media-title='$escaped_title' '$video_link'"
                case "$(uname -s)" in
                    MINGW* | *Msys) player_cmd="$player_cmd --write-filename-in-watch-later-config --save-position-on-quit --quiet" ;;
                    *) player_cmd="$player_cmd --watch-later-directory='$watchlater_dir' --write-filename-in-watch-later-config --save-position-on-quit --quiet" ;;
                esac

                # Check if the system supports Unix domain sockets
                if command -v nc >/dev/null 2>&1 && [ -S "$lobster_socket" ] 2>/dev/null; then
                    player_cmd="$player_cmd --input-ipc-server='$lobster_socket'"
                fi

                # Use eval to properly handle spaces in the command
                eval "$player_cmd" >&3 &
''',
    r'''                set -- "$player"
                [ -n "$resume_from" ] && set -- "$@" "--start=$resume_from"
                [ -n "$subs_links" ] && set -- "$@" "$subs_arg=$subs_links"
                set -- "$@" "--force-media-title=$displayed_title" "$video_link"
                case "$(uname -s)" in
                    MINGW* | *Msys) ;;
                    *)
                        set -- "$@" "--watch-later-directory=$watchlater_dir"
                        set -- "$@" "--input-ipc-server=$lobster_socket"
                        ;;
                esac
                set -- "$@" --write-filename-in-watch-later-config --save-position-on-quit --quiet

                "$@" >&3 &
''',
    "MPV command execution",
)

start = text.find('    update_script() {\n')
end_marker = '    # download_video [url] [title] [download_dir] [json_data] [thumbnail_file (only when image_preview is enabled)]\n'
end = text.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit("maintenance transform failed for updater: block not found")

safe_updater = r'''    update_script() {
        which_lobster=$(command -v lobster)
        if [ -z "$which_lobster" ]; then
            send_notification "Can't find lobster in PATH"
            exit 1
        fi

        case "$which_lobster" in
            /nix/store/*)
                send_notification "Lobster is managed by Nix; update your flake input instead"
                exit 1
                ;;
        esac

        update_file="$tmp_dir/lobster-update.sh"
        if ! curl --fail --silent --show-error --location \
            --proto '=https' --tlsv1.2 \
            https://raw.githubusercontent.com/Noah-Martinez/lobster-ng/main/lobster.sh \
            --output "$update_file"; then
            send_notification "Could not download the latest Lobster-ng version"
            exit 1
        fi

        if ! sh -n "$update_file"; then
            send_notification "Downloaded update failed the shell syntax check"
            exit 1
        fi

        if grep -Eq '(^|[^[:alnum:]_])eval[[:space:]]' "$update_file"; then
            send_notification "Downloaded update failed the security check"
            exit 1
        fi

        if cmp -s "$which_lobster" "$update_file"; then
            send_notification "Lobster-ng is up to date :)"
            exit 0
        fi

        chmod +x "$update_file"
        if cat "$update_file" >"$which_lobster"; then
            send_notification "Lobster-ng has been updated!"
        else
            send_notification "Could not replace $which_lobster; check its permissions"
            exit 1
        fi
        exit 0
    }
'''

text = text[:start] + safe_updater + text[end:]
path.write_text(text)
