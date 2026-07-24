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
        cp "$LOBSTER_FIXTURE_FILE" "$tmp_file" || fail 3 "could not read fixture file"
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

decode_html() {
    if command -v hxunent >/dev/null 2>&1; then
        hxunent
    else
        sed 's/&amp;/\&/g; s/&#39;/'"'"'/g; s/&quot;/"/g; s/&lt;/</g; s/&gt;/>/g'
    fi
}

emit_media_cards() {
    records=$(tr '\n' ' ' <"$tmp_file" |
        sed 's/class="comp:media-card/\nclass="comp:media-card/g')
    results=""

    while IFS= read -r record; do
        case "$record" in
            'class="comp:media-card'*) ;;
            *) continue ;;
        esac

        media_data=$(printf '%s\n' "$record" |
            sed -nE 's@.*data-media-type="(movie|tv)"[^>]*href="/(movie|tv)/([0-9]+)[^"]*".*@\1\t\3@p' |
            head -n 1)
        [ -n "$media_data" ] || continue

        media_type=$(printf '%s' "$media_data" | cut -f1)
        media_id=$(printf '%s' "$media_data" | cut -f2)
        title=$(printf '%s\n' "$record" |
            sed -nE 's@.*<h2[^>]*>[^<]*<span>([^<]+)</span>.*@\1@p' |
            head -n 1)
        [ -n "$title" ] || title=$(printf '%s\n' "$record" |
            sed -nE 's@.*<h2[^>]*>([^<]+)</h2>.*@\1@p' |
            head -n 1)
        [ -n "$title" ] || continue

        poster=$(printf '%s\n' "$record" | sed 's/<img/\n<img/g' |
            sed -nE 's@.*src="(https://media\.themoviedb\.org/t/p/[^\"]+)".*@\1@p' |
            head -n 1)
        year=$(printf '%s\n' "$record" | sed 's/<span/\n<span/g' |
            grep 'class="release_date' | grep -oE '[12][0-9]{3}' | head -n 1)
        title=$(printf '%s' "$title" | decode_html)
        [ -n "$year" ] || year="unknown"

        results="${results}${poster}\ttmdb-${media_id}\t${media_type}\t${title} [${year}]\ttmdb:${media_id}\ttmdb\n"
    done <<EOF_RECORDS
$records
EOF_RECORDS

    printf '%b' "$results"
}

require_tmdb_ref() {
    ref=${1:-}
    case "$ref" in
        tmdb:[0-9]*) printf '%s\n' "${ref#tmdb:}" ;;
        *) fail 5 "does not support media reference '$ref'" ;;
    esac
}

emit_numbered_links() {
    kind=$1
    prefix=$2
    numbers=$(grep -oE "${prefix}[0-9]+" "$tmp_file" |
        sed -nE "s@.*${kind}/([0-9]+).*@\\1@p" |
        sort -n -u)
    [ -n "$numbers" ] || return 1

    printf '%s\n' "$numbers" | while IFS= read -r number; do
        case "$kind" in
            season) printf 'Season %s\t%s\n' "$number" "$number" ;;
            episode) printf 'Episode %s\t%s\n' "$number" "$number" ;;
        esac
    done
}

case "${1:-}" in
    search)
        shift
        [ "$#" -gt 0 ] || fail 64 "missing search query"
        fetch_page "https://www.themoviedb.org/search" -G --data-urlencode "query=$*"
        output=$(emit_media_cards)
        if [ -z "$output" ]; then
            if grep -q 'class="comp:media-card' "$tmp_file"; then
                fail 4 "the search page loaded, but its result cards could not be parsed"
            fi
            fail 2 "no matching movies or TV shows found"
        fi
        printf '%s\n' "$output"
        ;;
    trending)
        fetch_page "https://www.themoviedb.org/trending"
        output=$(emit_media_cards)
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
        output=$(emit_media_cards)
        [ -n "$output" ] || fail 4 "the recent-$media_type page loaded, but its results could not be parsed"
        printf '%s\n' "$output"
        ;;
    seasons)
        media_id=$(require_tmdb_ref "${2:-}")
        fetch_page "https://www.themoviedb.org/tv/$media_id/seasons"
        emit_numbered_links season "/season/" ||
            fail 4 "the seasons page loaded, but no seasons could be parsed"
        ;;
    episodes)
        media_id=$(require_tmdb_ref "${2:-}")
        season=${3:-}
        case "$season" in
            *[!0-9]* | '') fail 64 "invalid season '$season'" ;;
        esac
        fetch_page "https://www.themoviedb.org/tv/$media_id/season/$season"
        emit_numbered_links episode "/episode/" ||
            fail 4 "the season page loaded, but no episodes could be parsed"
        ;;
    *) fail 64 "unsupported action '${1:-}'" ;;
esac
