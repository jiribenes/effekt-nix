# effekt-nix

> [!NOTE]
> Contributions are very welcome, see Contributing section below! :)

A comprehensive Nix flake for the [Effekt programming language](https://github.com/effekt-lang/effekt).

## Features

- pre-packaged Effekt compiler releases for all platforms supported by Nixpkgs, and for any subset of Effekt's backends
- building the Effekt compiler from source or from a GitHub Release
- pre-made development shells with Effekt compiler releases and for Effekt compiler development
- Nix toolchain to build, test, and package apps written in Effekt

## Quick Start

<details>
  <summary><b>I want to quickly run Effekt!</b></summary>

  Great! Here's how you run the latest released version of Effekt:
  ```sh
  # run Effekt REPL
  nix run github:jiribenes/effekt-nix

  # run the latest version of the Effekt compiler on a file (with default backend)
  nix run github:jiribenes/effekt-nix -- file.effekt

  # run the latest version of the Effekt compiler on a file with the LLVM backend
  nix run github:jiribenes/effekt-nix -- --backend llvm file.effekt

  # run a specific version of the Effekt compiler
  nix run github:jiribenes/effekt-nix#effekt_0_3_0 -- --help
  ```

</details>

---

<details>
  <summary><b>I want to quickly play with Effekt!</b></summary>

  Sure, let's get you a devshell in which you can just call `effekt` then:
  ```sh
  # a shell with the latest Effekt version
  nix develop github:jiribenes/effekt-nix

  # a shell with a specific Effekt version
  nix develop github:jiribenes/effekt-nix#effekt_0_3_0

  # ADVANCED: a shell for developing the Effekt compiler
  nix develop github:jiribenes/effekt-nix#compilerDev
  ```

  You can use this -- for example -- for benchmarking or for working with LSP support in VSCode.

</details>

---

<details>
  <summary><b>I want to quickly install Effekt on my machine!</b></summary>

  Alright, let's install Effekt on your machine so that you can call `effekt` at any time:
  ```sh
  # install latest version of Effekt
  nix profile install github:jiribenes/effekt-nix
  ```

</details>

---

<details>
  <summary><b>I want to quickly build Effekt on my machine!</b></summary>

  _... okay, I guess? ..._
  ```sh
  # builds the latest version of Effekt
  nix build github:jiribenes/effekt-nix
  ```

  The result of the build is in the `result/` folder (the binary is in `result/bin/`).

</details>

## Example: packaging an app written in Effekt

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux"; # or "aarch64-darwin" if you're on a M1
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.${system};

      # You can set a fixed Effekt version and your supported backends here:
      effektVersion = "0.3.0";
      backends = with effekt-lib.effektBackends; [ js llvm ];
    in {
      # A package for your Effekt project
      packages.${system}.default = effekt-lib.buildEffektPackage {
        pname = "my-effekt-project";
        version = "1.0.0";
        src = ./.;               # Path to your Effekt project
        main = "./main.effekt";  # the main Effekt file to run

        inherit effektVersion backends;
      };

      # Development shell for your project
      devShell.${system}.default = effekt-lib.mkDevShell {
        inherit effektVersion backends;
      };
    };
}
```

Here's a breakdown of `buildEffektPackage`'s arguments:

- `pname`: The name of your package.
- `version`: The version of your package.
- `src`: The source directory of your Effekt project.
- `main`: The main Effekt file to compile.
- `tests`: (Optional) A list of test files to run during the build process.
- `effekt`: (Optional) A specific Effekt derivation to use. If not provided, it uses the version specified by `effektVersion`.
- `effektVersion`: The version of Effekt to use (defaults to the latest version).
- `backends`: A list of backends to compile your project with. The first backend in the list is considered the default.
- `buildInputs`: (Optional) Additional build inputs required for your package.

The function will compile your project with all specified backends and create a binary for each.
It also sets up a symbolic link to the default backend's binary under the `pname`.

`effekt-nix` also supports multiple platforms. Use `flake-utils` and its `flake-utils.lib.eachDefaultSystem` (or alternatives)
to define outputs for multiple systems at the same time.

### Using a custom Effekt compiler build for your app

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.${system};
      
      # Define your own Effekt build from source:
      myCustomEffekt = effekt-lib.buildEffektFromSource {
        # ... by defining the path to your compiler source here:
        src = ./path/to/effekt/compiler/source;
        backends = with effekt-lib.effektBackends; [ js llvm ];
      };
    in {
      packages.${system}.default = effekt-lib.buildEffektPackage {
        pname = "my-custom-effekt-project";
        version = "1.0.0";
        src = ./.;                           # Path to your Effekt project
        main = "./src/main.effekt";          # path to the entrypoint
        tests = [ "./src/mytest.effekt" ];   # path to the tests

        effekt = myCustomEffekt;
      };

      devShell.${system}.default = effekt-lib.mkDevShell {
        effekt = myCustomEffekt;
      };
    };
}
```

## Contributing

Contributions of all kinds are very welcome, feel free to create a PR.

A common chore is updating this repo with released versions of Effekt in `releases.json` (hopefully will be addressed with CI).

### Adding a new Effekt version

To add support for a new Effekt version:

1. Update the `releases.json` file with the new version number and its corresponding SHA256 hash.
2. The flake will automatically generate new packages and development shells for the added version.
