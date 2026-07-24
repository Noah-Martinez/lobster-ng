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
  lib,
  makeWrapper,
  mpv,
  openssl,
  shellcheck,
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
    makeWrapper
    shellcheck
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
    mpv
    openssl
  ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck

    find . -type f -name '*.sh' -print0 \
      | xargs -0 -n1 sh -n
    shellcheck --severity=error lobster.sh providers/catalog/*.sh providers/stream/*.sh tests/*.sh
    ./tests/provider-interface.sh

    runHook postCheck
  '';

  preInstall = ''
    patchShebangs --host lobster.sh providers tests
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
