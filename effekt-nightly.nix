{ lib, mkSbtDerivation, fetchFromGitHub, nix-gitignore, jre, nodejs, maven, makeWrapper, effektSrcPath }:
let
  gitIgnore = nix-gitignore.gitignoreSourcePure [ "${effektSrcPath}/.gitignore" ];
in
mkSbtDerivation {
  pname = "effekt";
  version = "0.2.2+nightly";
  src = gitIgnore effektSrcPath;

  depsSha256 = "SqW8m/374mOOxMaFTFXRqceyYLaGwiO1oKiRahE3yfo=";

  depsWarmupCommand = "sbt deploy";

  nativeBuildInputs = [ nodejs maven makeWrapper ];

  buildPhase = ''
    sbt deploy
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib

    # copy the jar file
    mv bin/effekt $out/lib/effekt.jar

    # copy the standard library
    mv libraries $out/libraries

    # make a wrapper script
    makeWrapper ${jre}/bin/java $out/bin/effekt \
      --add-flags "-jar $out/lib/effekt.jar" \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]}
  '';
}
