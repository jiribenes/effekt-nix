# effekt-nix

> [!NOTE]
> Contributions are very welcome, see Contributing section below! :)

A comprehensive Nix flake for the [Effekt programming language](https://github.com/effekt-lang/effekt).

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
  nix run github:jiribenes/effekt-nix#effekt_0_2_2 -- --help
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
  nix develop github:jiribenes/effekt-nix#effekt_0_2_2

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

## Examples of using this Nix Flake

### Adding a devshell with Effekt to your own Nix flake

#### Latest released version of Effekt:

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
    in {
      devShell = effekt-nix.devShells.${system}.default;
    };
}
```

#### Specific released version of Effekt:

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.${system};
    in {
      devShell = effekt-lib.mkDevShell {
        effektVersion = "0.2.2";
      };
    };
}
```

### Building an app written in Effekt in your Nix flake

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.${system};
    in {
      packages.default = effekt-lib.buildEffektPackage {
        pname = "my-effekt-project";
        version = "1.0.0";
        src = ./.;              # Path to your Effekt project
        main = ./main.effekt;   # the main Effekt file to run
        effektVersion = "0.2.2";
        effektBackends = with effekt-lib.effektBackends; [ js llvm ];
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
- `effektBackends`: A list of backends to compile your project with. The first backend in the list is considered the default.
- `buildInputs`: (Optional) Additional build inputs required for your package.

The function will compile your project with all specified backends and create a binary for each.
It also sets up a symbolic link to the default backend's binary under the `pname`.

#### Using a custom Effekt compiler build

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
      devShell = effekt-lib.mkDevShell {
        effekt = myCustomEffekt;
      };
      
      packages.myPackage = effekt-lib.buildEffektPackage {
        pname = "my-custom-effekt-project";
        version = "1.0.0";
        src = ./.; # Path to your Effekt project
        main = ./main.effekt;
        effekt = myCustomEffekt; #
      };
    };
}
```

### Available Backends

The `effekt-nix` flake supports the following backends:

- `js`: JavaScript backend (always available)
- `llvm`: LLVM backend
- `chez-callcc`: Chez Scheme backend with call/cc
- `chez-monadic`: Chez Scheme backend with monadic style
- `chez-lift`: Chez Scheme backend with lifting
- `ml`: MLton backend (only available on systems that support MLton)

You can specify which backends to use when building an Effekt package or creating a development shell.

## Contributing

Contributions of all kinds are very welcome, feel free to create a PR.

A common chore is updating this repo with released versions of Effekt in `releases.json` (hopefully will be addressed with CI).

### Adding a new Effekt version

To add support for a new Effekt version:

1. Update the `releases.json` file with the new version number and its corresponding SHA256 hash.
2. The flake will automatically generate new packages and development shells for the added version.
