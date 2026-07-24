#!/usr/bin/env sh

set -u

provider_name="IMDb"
user_agent="${LOBSTER_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36}"
tmp_file="${TMPDIR:-/tmp}/lobster-imdb-$$.html"
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

    status=$(curl -L -sS --compressed -A "$user_agent" \
        -H 'Accept-Language: en-US,en;q=0.8' \
        -o "$tmp_file" -w '%{http_code}' "$url" "$@") ||
        fail 3 "request failed; check your internet connection"

    case "$status" in
        2??) ;;
        403 | 429) fail 3 "request was blocked (HTTP $status)" ;;
        *) fail 3 "request failed with HTTP $status" ;;
    esac
}

decode_json_text() {
    sed 's/\\u0026/\&/g; s/\\u0027/'"'"'/g; s/\\"/"/g; s/\\n/ /g; s/\\\//\//g'
}

map_media_type() {
    case "$1" in
        movie | tvMovie | short | video) printf 'movie\n' ;;
        tvSeries | tvMiniSeries | tvEpisode | tvSpecial | podcastSeries) printf 'tv\n' ;;
        *) printf 'movie\n' ;;
    esac
}

emit_results() {
    records=$(tr '\n' ' ' <"$tmp_file" | sed 's/{"id":"tt/\n{"id":"tt/g')
    results=""

    while IFS= read -r record; do
        case "$record" in
            '{"id":"tt'*) ;;
            *) continue ;;
        esac

        imdb_id=$(printf '%s\n' "$record" | sed -nE 's@^\{"id":"(tt[0-9]+)".*@\1@p' | head -n 1)
        title=$(printf '%s\n' "$record" | sed -nE 's@.*"titleText":\{"text":"([^"]+)".*@\1@p' | head -n 1)
        type_id=$(printf '%s\n' "$record" | sed -nE 's@.*"titleType":\{"id":"([^"]+)".*@\1@p' | head -n 1)
        year=$(printf '%s\n' "$record" | sed -nE 's@.*"releaseYear":\{"year":([0-9]{4}).*@\1@p' | head -n 1)
        poster=$(printf '%s\n' "$record" | sed -nE 's@.*"primaryImage":\{"id":"[^"]+","url":"([^"]+)".*@\1@p' | head -n 1)
        [ -z "$imdb_id" ] && continue
        [ -z "$title" ] && continue

        title=$(printf '%s' "$title" | decode_json_text)
        poster=$(printf '%s' "$poster" | decode_json_text)
        media_type=$(map_media_type "$type_id")
        [ -n "$year" ] && display_title="$title [$year]" || display_title="$title"
        results="${results}${poster}\timdb:${imdb_id}\t${media_type}\t${display_title}\timdb\n"
    done <<EOF_RECORDS
$records
EOF_RECORDS

    if [ -z "$results" ]; then
        anchors=$(tr '\n' ' ' <"$tmp_file" | sed 's@<a @\n<a @g' |
            sed -nE \
                -e 's@.*href="/title/(tt[0-9]+)/[^"]*"[^>]*>([^<]+)</a>.*@\1\t\2@p' \
                -e 's@.*aria-label="([^"]+)"[^>]*href="/title/(tt[0-9]+)/[^"]*".*@\2\t\1@p' |
            awk -F '\t' '!seen[$1]++')

        while IFS="$(printf '\t')" read -r imdb_id title; do
            [ -z "$imdb_id" ] && continue
            title=$(printf '%s' "$title" | sed 's/<[^>]*>//g')
            [ -z "$title" ] && title="$imdb_id"
            results="${results}\timdb:${imdb_id}\tmovie\t${title}\timdb\n"
        done <<EOF_ANCHORS
$anchors
EOF_ANCHORS
    fi

    printf '%b' "$results"
}

require_imdb_ref() {
    ref=${1:-}
    case "$ref" in
        imdb:tt[0-9]*) printf '%s\n' "${ref#imdb:}" ;;
        *) fail 5 "does not support media reference '$ref'" ;;
    esac
}

case "${1:-}" in
    search)
        shift
        [ "$#" -gt 0 ] || fail 64 "missing search query"
        query=$*
        fetch_page "https://www.imdb.com/find/" -G --data-urlencode "q=$query"
        output=$(emit_results)
        if [ -z "$output" ]; then
            if grep -qiE 'no results|did not find' "$tmp_file"; then
                fail 2 "no matching movies or TV shows found"
            fi
            fail 4 "the search page loaded, but its results could not be parsed"
        fi
        printf '%s\n' "$output"
        ;;
    trending | recent)
        fail 5 "does not provide this discovery action"
        ;;
    seasons)
        imdb_id=$(require_imdb_ref "${2:-}")
        fetch_page "https://www.imdb.com/title/$imdb_id/episodes/"
        seasons=$(grep -oE '"seasonNumber"[[:space:]]*:[[:space:]]*[0-9]+' "$tmp_file" |
            grep -oE '[0-9]+' |
            sort -n -u)
        [ -n "$seasons" ] || seasons=$(grep -oE 'season=[0-9]+' "$tmp_file" | cut -d= -f2 | sort -n -u)
        [ -n "$seasons" ] || fail 4 "the episode page loaded, but no seasons could be parsed"
        printf '%s\n' "$seasons" | while IFS= read -r season; do
            printf 'Season %s\t%s\n' "$season" "$season"
        done
        ;;
    episodes)
        imdb_id=$(require_imdb_ref "${2:-}")
        season=${3:-}
        case "$season" in
            *[!0-9]* | '') fail 64 "invalid season '$season'" ;;
        esac
        fetch_page "https://www.imdb.com/title/$imdb_id/episodes/" -G --data-urlencode "season=$season"
        episodes=$(grep -oE '"episodeNumber"[[:space:]]*:[[:space:]]*(\{"episodeNumber"[[:space:]]*:[[:space:]]*)?[0-9]+' "$tmp_file" |
            sed -nE 's@.*[^0-9]([0-9]+)$@\1@p' |
            sort -n -u)
        [ -n "$episodes" ] || episodes=$(grep -oE "episodes/[^\"']+" "$tmp_file" |
            sed -nE 's@.*episode-([0-9]+).*@\1@p' |
            sort -n -u)
        [ -n "$episodes" ] || fail 4 "the season page loaded, but no episodes could be parsed"
        printf '%s\n' "$episodes" | while IFS= read -r episode; do
            printf 'Episode %s\t%s\n' "$episode" "$episode"
        done
        ;;
    *) fail 64 "unsupported action '${1:-}'" ;;
esac
