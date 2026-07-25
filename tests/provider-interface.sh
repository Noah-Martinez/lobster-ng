#!/usr/bin/env sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lobster-tests.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

cat >"$tmp_dir/tmdb-search.html" <<'EOF_TMDB'
<div id="abc" class="comp:media-card w-full tight"><a data-media-type="tv" href="/tv/4626-ugly-betty"><img src="https://media.themoviedb.org/t/p/w94/poster.jpg"></a><a data-media-type="tv" href="/tv/4626-ugly-betty"><h2><span>Ugly Betty</span></h2></a><span class="release_date">September 28, 2006</span></div>
EOF_TMDB

cat >"$tmp_dir/tmdb-movie.html" <<'EOF_MOVIE'
<div id="def" class="comp:media-card w-full tight"><a data-media-type="movie" href="/movie/550-fight-club"><img src="https://media.themoviedb.org/t/p/w94/poster.jpg"></a><a data-media-type="movie" href="/movie/550-fight-club"><h2><span>Fight Club</span></h2></a><span class="release_date">October 15, 1999</span></div>
EOF_MOVIE

cat >"$tmp_dir/imdb-search.json" <<'EOF_IMDB'
{"d":[{"id":"tt0805669","l":"Ugly Betty","qid":"tvSeries","y":2006,"i":{"imageUrl":"https://m.media-amazon.com/image.jpg"}}]}
EOF_IMDB

tmdb_output=$(LOBSTER_FIXTURE_FILE="$tmp_dir/tmdb-search.html" "$repo_dir/providers/catalog/tmdb.sh" search 'Ugly Betty')
printf '%s\n' "$tmdb_output" | grep -F 'tmdb-4626' >/dev/null
printf '%s\n' "$tmdb_output" | grep -F 'tmdb:4626' >/dev/null
printf '%s\n' "$tmdb_output" | grep -F 'Ugly Betty [2006]' >/dev/null

imdb_output=$(LOBSTER_FIXTURE_FILE="$tmp_dir/imdb-search.json" "$repo_dir/providers/catalog/imdb.sh" search 'Ugly Betty')
printf '%s\n' "$imdb_output" | grep -F 'imdb-tt0805669' >/dev/null
printf '%s\n' "$imdb_output" | grep -F 'imdb:tt0805669' >/dev/null

vidsrc_movie_url=$("$repo_dir/providers/stream/vidsrc.sh" movie imdb:tt0137523 '' '' en)
[ "$vidsrc_movie_url" = 'https://vidsrc.to/embed/movie/tt0137523' ]
vidsrc_tv_url=$("$repo_dir/providers/stream/vidsrc.sh" tv tmdb:1396 1 1 en)
[ "$vidsrc_tv_url" = 'https://vidsrc.to/embed/tv/1396/1/1' ]
vidlink_movie_url=$("$repo_dir/providers/stream/vidlink.sh" movie tmdb:550 '' '' en)
[ "$vidlink_movie_url" = 'https://vidlink.pro/movie/550' ]
vidlink_tv_url=$("$repo_dir/providers/stream/vidlink.sh" tv tmdb:1396 1 1 en)
[ "$vidlink_tv_url" = 'https://vidlink.pro/tv/1396/1/1' ]
vidapi_url=$("$repo_dir/providers/stream/vidapi.sh" movie tmdb:550 '' '' en)
[ "$vidapi_url" = 'https://vaplayer.ru/embed/movie/550?lang=en' ]
vidcore_url=$("$repo_dir/providers/stream/vidcore.sh" tv tmdb:1396 1 1 en)
[ "$vidcore_url" = 'https://vidcore.org/embed/tv/1396/1/1?sub=en' ]

mkdir -p "$tmp_dir/bin" "$tmp_dir/home/.config/lobster" "$tmp_dir/data" "$tmp_dir/cache"
shell_path=$(command -v sh)
cat >"$tmp_dir/home/.config/lobster/lobster_config.sh" <<EOF_CONFIG
player="true"
history="false"
remove_tmp_lobster="true"
EOF_CONFIG

{
    printf '#!%s\n' "$shell_path"
    cat <<'EOF_CURL'
json='{"sources":[{"file":"https://example.test/playlist.m3u8"}],"tracks":[]}'
printf '%s' "$json"
EOF_CURL
} >"$tmp_dir/bin/curl"

{
    printf '#!%s\n' "$shell_path"
    cat <<'EOF_FZF'
printf '\n'
head -n 1
EOF_FZF
} >"$tmp_dir/bin/fzf"
chmod +x "$tmp_dir/bin/curl" "$tmp_dir/bin/fzf"

main_output=$(HOME="$tmp_dir/home" \
    XDG_DATA_HOME="$tmp_dir/data" \
    XDG_CACHE_HOME="$tmp_dir/cache" \
    PATH="$tmp_dir/bin:$PATH" \
    LOBSTER_PROVIDER_DIR="$repo_dir/providers" \
    LOBSTER_FIXTURE_FILE="$tmp_dir/tmdb-movie.html" \
    stream_provider_order="vidsrc vidlink vidapi vidcore" \
    "$repo_dir/lobster.sh" --json 'Fight Club')
printf '%s\n' "$main_output" | grep -F 'https://example.test/playlist.m3u8' >/dev/null

printf 'provider interface tests passed\n'
