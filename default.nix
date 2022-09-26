let
  pkgs = import <nixpkgs> { };

  effekt = import ./effekt.nix {
    inherit (pkgs) lib stdenv fetchurl makeWrapper jre8 nodejs;
  };

  shell = pkgs.mkShell {
    buildInputs = [ effekt ];
  };
in
{
  inherit shell effekt;
}
