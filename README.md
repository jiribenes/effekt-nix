# effekt-nix

A simple Nix package for the [Effekt programming language](https://github.com/effekt-lang/effekt).

## Installation

```sh
nix-build -A effekt
```

then call `./result/bin/effekt` to invoke the Effekt compiler/interpreter.

## Development

If you just want a temporary shell with the Effekt compiler/interpreter inside,
use the command:

```sh
nix-shell
```

This will spawn a new shell in which one can just call `effekt`.

## TODO

- [x] provide a Nix shell with Effekt as an input
- [ ] add optional support for pulling in Chez Scheme and/or LLVM
- [ ] building directly from source
- [ ] upstreaming this to Nixpkgs
