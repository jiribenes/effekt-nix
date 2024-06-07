let
  sbt-derivation-repo = builtins.fetchTarball {
    url = "https://github.com/zaninime/sbt-derivation/archive/master.tar.gz";
  };

  sbt-derivation = import "${sbt-derivation-repo}/overlay.nix";

  pkgs = import <nixpkgs> { overlays = [ sbt-derivation ]; };

  # Latest version of Effekt as a package
  effekt = import ./effekt.nix {
    inherit (pkgs) lib stdenv fetchurl makeWrapper jre nodejs;
  };

  # Nightly, **RELATIVE** version of Effekt as a package.
  # Specify the source path below in `effektSrcPath`.
  effekt-nightly = import ./effekt-nightly.nix {
    inherit (pkgs) lib mkSbtDerivation fetchFromGitHub nix-gitignore makeWrapper jre nodejs maven;
    effektSrcPath = ./. + "/../effekt";
  };

  # Basic shell with Effekt (Node.js backend only!)
  shell = pkgs.mkShell {
    buildInputs = [ effekt ];
  };

  # Nightly shell with Effekt stored in `effektSrcPath` defined above in `effekt-nightly`.
  # (Node.js, LLVM, Chez backends are supported, others are not!)
  shell-nightly = pkgs.mkShell {
    buildInputs = with pkgs; [ effekt-nightly nodejs llvm libuv chez ];
  };

  # Development environment for working on the Effekt compiler
  devshell = pkgs.mkShell {
    buildInputs = with pkgs; [ sbt jre nodejs llvm libuv nodejs maven scala_3 chez ];
  };

in
{
  inherit shell shell-nightly effekt effekt-nightly devshell;
}
