{ lib, stdenv, fetchurl, makeWrapper, jre, nodejs }:

stdenv.mkDerivation rec {
  version = "0.2.2";
  pname = "effekt";

  src = fetchurl {
    url = "https://github.com/effekt-lang/effekt/releases/download/v${version}/effekt.tgz";
    sha256 = "hYlJg/jpFK3FFze3udXa8lLysVOf7F0HtwALf13TcqM=";
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ jre nodejs ];

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
