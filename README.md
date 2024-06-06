# effekt-nix

> [!NOTE]
> Contributions are very welcome, see TODOs below! :)

A simple Nix package for the [Effekt programming language](https://github.com/effekt-lang/effekt).

## Installation

```sh
nix-build -A effekt
```

then call `./result/bin/effekt` to invoke the Effekt compiler/interpreter.

## Usage

If you just want a temporary shell with the Effekt compiler/interpreter inside, use the command:

```sh
nix-shell
```

This will spawn a new shell in which one can just call `effekt`.

### WIP

You can also use `nix-build -A effekt-nightly` to build directly from a **relative** Effekt source folder (needs setup in `default.nix`).
Similarly you can use `nix-shell -A shell-nightly default.nix` to get a shell with `Effekt` from a relative folder.

> [!WARNING]
> You might need to modify the `build.sbt` file, this is very WIP.

You can also use `nix-shell -A devshell default.nix` to get the development environment necessary for developing the Effekt compiler itself.

## TODO

- [x] provide a Nix shell with Effekt as an input
- [ ] add configurable pulling in Chez Scheme and/or LLVM
- [x] building directly from a folder
- [ ] building directly from a GitHub commit
- [ ] Flake-ify!
- [ ] upstream the `effekt` package itself to Nixpkgs
- [ ] Docker images
- [ ] CI
