let
  pkgs = import <nixpkgs> { };

  effekt = import ./effekt.nix {
    inherit (pkgs) lib stdenv fetchurl makeWrapper jre nodejs;
  };

  # Basic shell with Effekt (Node.js backend only!)
  shell = pkgs.mkShell {
    buildInputs = [ effekt ];
  };
in
{
  inherit shell effekt;
}
