# effekt-nix

A simple Nix package for the [Effekt programming language](https://github.com/effekt-lang/effekt).

## Installation

```sh
nix-build default.nix
```

then call `./result/bin/effekt` to invoke the Effekt compiler/interpreter.

## TODO

- [ ] provide a Nix shell with Effekt as an input
- [ ] building directly from source
- [ ] upstreaming this to Nixpkgs
