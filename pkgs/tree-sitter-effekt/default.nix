{ lib
, stdenv
, fetchFromGitHub
, tree-sitter
, src
}:

tree-sitter.buildGrammar {
  language = "effekt";
  version = "0.1.0"; # Adjust version as needed
  
  inherit src;

  meta = with lib; {
    description = "Tree-sitter grammar for the Effekt programming language";
    homepage = "https://github.com/leonfuss/tree-sitter-effekt";
  };
}
