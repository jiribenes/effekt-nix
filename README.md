# effekt-nix

> [!NOTE]
> Contributions are very welcome! :)

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

> [!WARNING]
> This section is untested right now.

_If you just want to do things quickly, see the **TL;DR** above_

### Using the Latest Released Version

To use the latest released version:

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

### Using a Released Version of Effekt

To use a specific released version of Effekt in your project:

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

### Building an Effekt Package

To build an Effekt package:

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
        src = ./.; # Path to your Effekt project
        main = "Main.effekt";
        effektVersion = "0.2.2";
        effektBackends = with effekt-lib.effektBackends; [ js llvm ];
      };
    };
}
```

### Custom Effekt Build

To use a custom Effekt build:

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.${system};
      
      myCustomEffekt = effekt-lib.buildEffektFromSource {
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
        main = "Main.effekt";
        effekt = myCustomEffekt;
      };
    };
}
```
