{
  stdenvNoCC,
  testers,
  coreutils,
  curl,
  ffmpeg,
  fzf,
  gnugrep,
  gnused,
  html-xml-utils,
  lib,
  makeWrapper,
  mpv,
  openssl,
  python3,
  shellcheck,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lobster-ng";
  version = "4.6.7-ng.1";

  src = builtins.path {
    name = "${finalAttrs.pname}-${finalAttrs.version}";
    filter = lib.cleanSourceFilter;
    path = ./.;
  };

  nativeBuildInputs = [
    makeWrapper
    python3
    shellcheck
  ];

  postPatch = ''
    python3 scripts/harden.py lobster.sh
  '';

  wrapperPaths = lib.makeBinPath [
    coreutils
    curl
    ffmpeg
    fzf
    gnugrep
    gnused
    html-xml-utils
    mpv
    openssl
  ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    sh -n lobster.sh
    shellcheck --severity=error lobster.sh
    if grep -Eq '(^|[^[:alnum:]_])eval[[:space:]]' lobster.sh; then
      echo "security check failed: eval remains in lobster.sh" >&2
      exit 1
    fi
    if grep -q 'update_script' lobster.sh; then
      echo "security check failed: self-updater remains in lobster.sh" >&2
      exit 1
    fi
    runHook postCheck
  '';

  preInstall = ''
    patchShebangs --host lobster.sh
  '';

  installPhase = ''
    runHook preInstall
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
    command = "lobster --version";
    version = "4.6.7";
  };

  meta = {
    description = "Security-hardened movie and TV streaming CLI";
    homepage = "https://github.com/Noah-Martinez/lobster-ng";
    license = lib.licenses.gpl2;
    mainProgram = "lobster";
    platforms = lib.platforms.unix;
    sourceProvenance = [lib.sourceTypes.fromSource];
  };
})
