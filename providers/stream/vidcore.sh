#!/usr/bin/env sh

set -u

fail() {
    code=$1
    shift
    printf 'VidCore: %s\n' "$*" >&2
    exit "$code"
}

media_type=${1:-}
media_ref=${2:-}
season=${3:-}
episode=${4:-}
language=${5:-en}

case "$media_ref" in
    tmdb:[0-9]*) id=${media_ref#tmdb:} ;;
    *) fail 5 "currently requires a TMDB media reference" ;;
esac

case "$media_type" in
    movie)
        printf 'https://vidcore.org/embed/movie/%s?sub=%s\n' "$id" "$language"
        ;;
    tv)
        case "$season:$episode" in
            *[!0-9:]* | :* | *:) fail 64 "TV playback requires numeric season and episode" ;;
            *) ;;
        esac
        printf 'https://vidcore.org/embed/tv/%s/%s/%s?sub=%s\n' "$id" "$season" "$episode" "$language"
        ;;
    *) fail 64 "unsupported media type '$media_type'" ;;
esac
