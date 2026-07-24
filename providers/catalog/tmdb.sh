#!/usr/bin/env sh

set -u

provider_name="TMDB"
user_agent="${LOBSTER_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36}"
tmp_file="${TMPDIR:-/tmp}/lobster-tmdb-$$.html"
trap 'rm -f "$tmp_file"' EXIT INT TERM

fail() {
    code=$1
    shift
    printf '%s: %s\n' "$provider_name" "$*" >&2
    exit "$code"
}

fetch_page() {
    url=$1
    shift

    if [ -n "${LOBSTER_FIXTURE_FILE:-}" ]; then
        cp "$LOBSTER_FIXTURE_FILE" "$tmp_file" || fail 3 "could not read fixture"
        return
    fi

    status=$(curl -L -sS --compressed -A "$user_agent" -o "$tmp_file" -w '%{http_code}' "$url" "$@") ||
        fail 3 "request failed; check your internet connection"

    case "$status" in
        2??) ;;
        403 | 429) fail 3 "request was blocked (HTTP $status)" ;;
        *) fail 3 "request failed with HTTP $status" ;;
    esac
}

decode_html() {
    if command -v hxunent >/dev/null 2>&1; then
        hxunent
    else
        sed 's/&amp;/\&/g; s/&#39;/'"'"'/g; s/&quot;/"/g; s/&lt;/</g; s/&gt;/>/g'
    fi
}

emit_cards() {
    cards=$(tr '\n' ' ' <"$tmp_file" | sed 's/<div class="card v4 tight"/\n<div class="card v4 tight"/g')
    results=""

    while IFS= read -r card; do
        [ -z "$card" ] && continue
        media_path=$(printf '%s\n' "$card" |
            sed -nE 's@.*href="/(movie|tv)/([0-9]+)[^"]*".*@\1\t\2@p' |
            head -n 1)
        [ -z "$media_path" ] && continue

        media_type=$(printf '%s' "$media_path" | cut -f1)
        media_id=$(printf '%s' "$media_path" | cut -f2)
        title=$(printf '%s\n' "$card" |
            sed -nE 's@.*href="/(movie|tv)/[0-9]+[^"]*"[^>]*title="([^"]+)".*@\2@p' |
            head -n 1)
        [ -z "$title" ] && title=$(printf '%s\n' "$card" | sed -nE 's@.*<h2[^>]*>([^<]+)</h2>.*@\1@p' | head -n 1)
        [ -z "$title" ] && continue

        poster=$(printf '%s\n' "$card" |
            sed -nE 's@.*(data-src|src)="(https?://[^\"]+|/t/p/[^\"]+)".*@\2@p' |
            head -n 1)
        case "$poster" in
            /t/p/*) poster="https://image.tmdb.org${poster}" ;;
        esac
        year=$(printf '%s\n' "$card" |
            sed -nE 's@.*class="release_date"[^>]*>.*([0-9]{4}).*@\1@p' |
            head -n 1)
        title=$(printf '%s' "$title" | decode_html)
        [ -n "$year" ] && display_title="$title [$year]" || display_title="$title"

        results="${results}${poster}\ttmdb:${media_id}\t${media_type}\t${display_title}\ttmdb\n"
    done <<EOF_CARDS
$cards
EOF_CARDS

    if [ -z "$results" ]; then
        anchors=$(tr '\n' ' ' <"$tmp_file" | sed 's/<a /\n<a /g' |
            sed -nE \
                -e 's@.*href="/(movie|tv)/([0-9]+)[^"]*"[^>]*title="([^"]+)".*@\1\t\2\t\3@p' \
                -e 's@.*title="([^"]+)"[^>]*href="/(movie|tv)/([0-9]+)[^"]*".*@\2\t\3\t\1@p' |
            awk -F '\t' '!seen[$1 FS $2]++')

        while IFS="$(printf '\t')" read -r media_type media_id title; do
            [ -z "$media_id" ] && continue
            title=$(printf '%s' "$title" | decode_html)
            results="${results}\ttmdb:${media_id}\t${media_type}\t${title}\ttmdb\n"
        done <<EOF_ANCHORS
$anchors
EOF_ANCHORS
    fi

    printf '%b' "$results"
}

require_tmdb_ref() {
    ref=${1:-}
    case "$ref" in
        tmdb:[0-9]*) printf '%s\n' "${ref#tmdb:}" ;;
        *) fail 5 "does not support media reference '$ref'" ;;
    esac
}

case "${1:-}" in
    search)
        shift
        [ "$#" -gt 0 ] || fail 64 "missing search query"
        query=$*
        fetch_page "https://www.themoviedb.org/search" -G --data-urlencode "query=$query"
        output=$(emit_cards)
        if [ -z "$output" ]; then
            if grep -qiE 'no results|nothing found|did not find' "$tmp_file"; then
                fail 2 "no matching movies or TV shows found"
            fi
            fail 4 "the search page loaded, but its results could not be parsed"
        fi
        printf '%s\n' "$output"
        ;;
    trending)
        fetch_page "https://www.themoviedb.org/trending"
        output=$(emit_cards)
        [ -n "$output" ] || fail 4 "the trending page loaded, but its results could not be parsed"
        printf '%s\n' "$output"
        ;;
    recent)
        media_type=${2:-}
        case "$media_type" in
            movie) url="https://www.themoviedb.org/movie/now-playing" ;;
            tv) url="https://www.themoviedb.org/tv/on-the-air" ;;
            *) fail 64 "recent requires 'movie' or 'tv'" ;;
        esac
        fetch_page "$url"
        output=$(emit_cards)
        [ -n "$output" ] || fail 4 "the recent-$media_type page loaded, but its results could not be parsed"
        printf '%s\n' "$output"
        ;;
    seasons)
        media_id=$(require_tmdb_ref "${2:-}")
        fetch_page "https://www.themoviedb.org/tv/$media_id"
        seasons=$(grep -oE "/tv/${media_id}[^\"']*/season/[0-9]+" "$tmp_file" |
            sed -nE 's@.*/season/([0-9]+).*@\1@p' |
            sort -n -u)
        [ -n "$seasons" ] || fail 4 "the title page loaded, but no seasons could be parsed"
        printf '%s\n' "$seasons" | while IFS= read -r season; do
            printf 'Season %s\t%s\n' "$season" "$season"
        done
        ;;
    episodes)
        media_id=$(require_tmdb_ref "${2:-}")
        season=${3:-}
        case "$season" in
            *[!0-9]* | '') fail 64 "invalid season '$season'" ;;
        esac
        fetch_page "https://www.themoviedb.org/tv/$media_id/season/$season"
        episodes=$(grep -oE "/tv/${media_id}[^\"']*/season/${season}/episode/[0-9]+" "$tmp_file" |
            sed -nE 's@.*/episode/([0-9]+).*@\1@p' |
            sort -n -u)
        [ -n "$episodes" ] || fail 4 "the season page loaded, but no episodes could be parsed"
        printf '%s\n' "$episodes" | while IFS= read -r episode; do
            printf 'Episode %s\t%s\n' "$episode" "$episode"
        done
        ;;
    *) fail 64 "unsupported action '${1:-}'" ;;
esac
