#!/usr/bin/env sh

set -u

fail() {
    code=$1
    shift
    printf 'VidLink: %s\n' "$*" >&2
    exit "$code"
}

media_type=${1:-}
media_ref=${2:-}
season=${3:-}
episode=${4:-}

case "$media_ref" in
    tmdb:[0-9]*) id=${media_ref#tmdb:} ;;
    *) fail 5 "requires a TMDB media reference" ;;
esac

case "$media_type" in
    movie)
        printf 'https://vidlink.pro/movie/%s\n' "$id"
        ;;
    tv)
        case "$season:$episode" in
            *[!0-9:]* | :* | *:) fail 64 "TV playback requires numeric season and episode" ;;
            *) ;;
        esac
        printf 'https://vidlink.pro/tv/%s/%s/%s\n' "$id" "$season" "$episode"
        ;;
    *) fail 64 "unsupported media type '$media_type'" ;;
esac
