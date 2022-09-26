let
  pkgs = import <nixpkgs> { };
in
import ./effekt.nix {
  inherit (pkgs) lib stdenv fetchurl makeWrapper jre8 nodejs;
}
