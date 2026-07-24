{
  stdenvNoCC,
  testers,
  coreutils,
  curl,
  ffmpeg,
  findutils,
  fzf,
  gawk,
  gnugrep,
  gnupatch,
  gnused,
  html-xml-utils,
  jq,
  lib,
  makeWrapper,
  mpv,
  openssl,
  shellcheck,
  shfmt,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lobster-ng";
  version = "4.7.0";

  src = builtins.path {
    name = "${finalAttrs.pname}-${finalAttrs.version}";
    filter = lib.cleanSourceFilter;
    path = ./.;
  };

  nativeBuildInputs = [
    findutils
    jq
    makeWrapper
    shellcheck
    shfmt
  ];

  wrapperPaths = lib.makeBinPath [
    coreutils
    curl
    ffmpeg
    findutils
    fzf
    gawk
    gnugrep
    gnupatch
    gnused
    html-xml-utils
    jq
    mpv
    openssl
  ];

  dontBuild = true;
  doCheck = true;

  postPatch = ''
    patchShebangs --host lobster.sh providers tests
  '';

  checkPhase = ''
    runHook preCheck

    find . -type f -name '*.sh' -print0 \
      | xargs -0 -n1 sh -n
    shfmt -i 4 -ci -d lobster.sh providers tests
    shellcheck -s sh -o all -e 2250 \
      lobster.sh providers/catalog/*.sh providers/stream/*.sh tests/*.sh
    ./tests/provider-interface.sh

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/lobster/providers/catalog $out/lib/lobster/providers/stream
    cp lobster.sh $out/bin/lobster
    cp providers/catalog/*.sh $out/lib/lobster/providers/catalog/
    cp providers/stream/*.sh $out/lib/lobster/providers/stream/

    runHook postInstall
  '';

  postInstall = ''
    wrapProgram $out/bin/lobster \
      --set LOBSTER_PROVIDER_DIR "$out/lib/lobster/providers" \
      --prefix PATH : $wrapperPaths
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
    command = "lobster --version";
    version = finalAttrs.version;
  };

  meta = {
    description = "Maintained, provider-based Lobster movie and TV streaming CLI";
    homepage = "https://github.com/Noah-Martinez/lobster-ng";
    license = lib.licenses.gpl2;
    mainProgram = "lobster";
    platforms = lib.platforms.unix;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
