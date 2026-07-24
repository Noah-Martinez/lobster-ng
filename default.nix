{
  stdenvNoCC,
  testers,
  coreutils,
  curl,
  ffmpeg,
  fzf,
  gnugrep,
  gnupatch,
  gnused,
  html-xml-utils,
  lib,
  makeWrapper,
  mpv,
  openssl,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lobster";
  version = "4.6.7";

  src = builtins.path {
    name = "${finalAttrs.pname}-${finalAttrs.version}";
    filter = lib.cleanSourceFilter;
    path = ./.;
  };

  nativeBuildInputs = [makeWrapper];

  wrapperPaths = lib.makeBinPath [
    coreutils
    curl
    ffmpeg
    fzf
    gnugrep
    gnupatch
    gnused
    html-xml-utils
    mpv
    openssl
  ];

  dontBuild = true;

  preInstall = ''
    patchShebangs --host lobster.sh
  '';

  installPhase = ''
    runHook preInstall;
    mkdir -p $out/bin
    cp lobster.sh $out/bin/lobster
    runHook postInstall
  '';

  postInstall = ''
    wrapProgram $out/bin/lobster \
      --prefix PATH : $wrapperPaths
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
  };

  meta = {
    description = "Maintained fork of the Lobster movie and TV streaming CLI";
    homepage = "https://github.com/Noah-Martinez/lobster-ng";
    license = lib.licenses.gpl2;
    maintainers = with lib.maintainers; [NotAShelf];
    mainProgram = "lobster";
    platforms = lib.platforms.unix;
    sourceProvenance = [lib.sourceTypes.fromSource];
  };
})
