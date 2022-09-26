{ lib, stdenv, fetchurl, makeWrapper, jre8, nodejs }:

stdenv.mkDerivation rec {
  version = "0.2.0";
  pname = "effekt";

  src = fetchurl {
    url = "https://github.com/effekt-lang/effekt/releases/download/v${version}/effekt.tgz";
    sha256 = "A/rMMZHY8l0n8U/pJ+0dgUF6dBlov562n6tn/bNwfgA=";
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ jre8 nodejs ];

  installPhase = ''
    mkdir -p $out/bin $out/lib

    # copy the jar file
    mv bin/effekt $out/lib/effekt.jar

    # copy the standard library
    mv libraries $out/libraries

    # make a wrapper script
    makeWrapper ${jre8}/bin/java $out/bin/effekt \
      --add-flags "-jar $out/lib/effekt.jar" \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]}
  '';
}
