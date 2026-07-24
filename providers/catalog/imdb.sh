#!/usr/bin/env sh

set -u

provider_name="IMDb"
user_agent="${LOBSTER_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36}"
tmp_file="${TMPDIR:-/tmp}/lobster-imdb-$$.json"
trap 'rm -f "$tmp_file"' EXIT INT TERM

fail() {
    code=$1
    shift
    printf '%s: %s\n' "$provider_name" "$*" >&2
    exit "$code"
}

fetch_json() {
    url=$1

    if [ -n "${LOBSTER_FIXTURE_FILE:-}" ]; then
        cp "$LOBSTER_FIXTURE_FILE" "$tmp_file" || fail 3 "could not read fixture file"
        return
    fi

    status=$(curl -L -sS --compressed -A "$user_agent" \
        -H 'Accept-Language: en-US,en;q=0.8' \
        -o "$tmp_file" -w '%{http_code}' "$url") ||
        fail 3 "request failed; check your internet connection"

    case "$status" in
        2??) ;;
        403 | 429) fail 3 "request was blocked (HTTP $status)" ;;
        *) fail 3 "request failed with HTTP $status" ;;
    esac
}

search_suggestion() {
    query=$*
    slug=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    [ -n "$slug" ] || fail 64 "missing search query"
    first=$(printf '%s' "$slug" | cut -c1)
    fetch_json "https://v3.sg.media-imdb.com/suggestion/$first/$slug.json"

    if ! jq -e . "$tmp_file" >/dev/null 2>&1; then
        fail 4 "the suggestion feed returned invalid JSON"
    fi

    output=$(jq -r '
        .d[]?
        | select(.id? | type == "string")
        | select(.id | startswith("tt"))
        | (.qid // "") as $qid
        | (if ($qid == "tvSeries" or $qid == "tvMiniSeries" or $qid == "tvEpisode" or $qid == "tvSpecial") then "tv"
           elif ($qid == "movie" or $qid == "tvMovie" or $qid == "short" or $qid == "video") then "movie"
           else empty end) as $type
        | [
            (.i.imageUrl // ""),
            ("imdb-" + .id),
            $type,
            ((.l // .id) + " [" + ((.y // "unknown") | tostring) + "]"),
            ("imdb:" + .id),
            "imdb"
          ]
        | @tsv
    ' "$tmp_file")

    [ -n "$output" ] || fail 2 "no matching movies or TV shows found"
    printf '%s\n' "$output"
}

case "${1:-}" in
    search)
        shift
        search_suggestion "$@"
        ;;
    trending | recent)
        fail 5 "does not provide this discovery action"
        ;;
    seasons | episodes)
        fail 5 "does not provide season or episode listings; enter the number manually"
        ;;
    *) fail 64 "unsupported action '${1:-}'" ;;
esac
