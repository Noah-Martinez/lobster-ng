#!/usr/bin/env sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lobster-tests.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

cat >"$tmp_dir/tmdb-search.html" <<'EOF_TMDB'
<div class="card v4 tight"><img data-src="/t/p/w94_and_h141_bestv2/abc.jpg"><a href="/tv/4626-ugly-betty" title="Ugly Betty"><h2>Ugly Betty</h2></a><span class="release_date">September 28, 2006</span></div>
EOF_TMDB

cat >"$tmp_dir/imdb-search.html" <<'EOF_IMDB'
<script>{"id":"tt0805669","titleText":{"text":"Ugly Betty"},"titleType":{"id":"tvSeries"},"releaseYear":{"year":2006},"primaryImage":{"id":"x","url":"https://m.media-amazon.com/image.jpg"}}</script>
EOF_IMDB

cat >"$tmp_dir/tmdb-movie.html" <<'EOF_MOVIE'
<div class="card v4 tight"><img data-src="/t/p/w94_and_h141_bestv2/def.jpg"><a href="/movie/550-fight-club" title="Fight Club"><h2>Fight Club</h2></a><span class="release_date">October 15, 1999</span></div>
EOF_MOVIE

tmdb_output=$(LOBSTER_FIXTURE_FILE="$tmp_dir/tmdb-search.html" "$repo_dir/providers/catalog/tmdb.sh" search 'Ugly Betty')
printf '%s\n' "$tmdb_output" | grep -F 'tmdb:4626' >/dev/null
printf '%s\n' "$tmdb_output" | grep -F 'Ugly Betty [2006]' >/dev/null

imdb_output=$(LOBSTER_FIXTURE_FILE="$tmp_dir/imdb-search.html" "$repo_dir/providers/catalog/imdb.sh" search 'Ugly Betty')
printf '%s\n' "$imdb_output" | grep -F 'imdb:tt0805669' >/dev/null
printf '%s\n' "$imdb_output" | grep -F 'Ugly Betty [2006]' >/dev/null

[ "$("$repo_dir/providers/stream/vidapi.sh" movie tmdb:550 '' '' en)" = 'https://vaplayer.ru/embed/movie/550?lang=en' ]
[ "$("$repo_dir/providers/stream/vidcore.sh" tv tmdb:1396 1 1 en)" = 'https://vidcore.org/embed/tv/1396/1/1?sub=en' ]

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/curl" <<'EOF_CURL'
#!/usr/bin/env sh
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            out=$2
            shift 2
            ;;
        *) shift ;;
    esac
done
json='{"sources":[{"file":"https://example.test/playlist.m3u8"}],"tracks":[]}'
if [ -n "$out" ]; then
    printf '%s' "$json" >"$out"
else
    printf '%s' "$json"
fi
EOF_CURL
chmod +x "$tmp_dir/bin/curl"

main_output=$(PATH="$tmp_dir/bin:$PATH" \
    LOBSTER_PROVIDER_DIR="$repo_dir/providers" \
    LOBSTER_FIXTURE_FILE="$tmp_dir/tmdb-movie.html" \
    "$repo_dir/lobster.sh" --select-first --json 'Fight Club')
printf '%s\n' "$main_output" | grep -F 'https://example.test/playlist.m3u8' >/dev/null

printf 'provider interface tests passed\n'
