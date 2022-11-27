{ pkgs, version }: pkgs.writeText "devenv-flake" ''
  {
    inputs = {
      pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
      pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
      nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
      devenv.url = "github:cachix/devenv?dir=src/modules";
      dotbox.url = "github:snowfallorg/dotbox";
      dotbox.inputs.nixpkgs.follows = "nixpkgs";
    } // (if builtins.pathExists ./.devenv/devenv.json 
         then (builtins.fromJSON (builtins.readFile ./.devenv/devenv.json)).inputs
         else {});

    outputs = { nixpkgs, ... }@inputs:
      let
        pkgs = import nixpkgs { system = "${pkgs.system}"; overlays = [ inputs.dotbox.overlay ]; };
        lib = pkgs.lib;
        dotbox = inputs.dotbox.lib.mkImporter pkgs;
        devenv = if builtins.pathExists ./.devenv/devenv.json
          then builtins.fromJSON (builtins.readFile ./.devenv/devenv.json)
          else {};
        configToModule = config: args:
          let
            pkgs' = args.pkgs;
          in
            (builtins.removeAttrs config [ "inputs" ]) // {
              packages = builtins.map
                (name:
                  let
                    parts = builtins.split "\\\\." name;
                    parts' = builtins.foldl' (acc: part:
                      if builtins.isList part then
                        acc
                      else
                        acc ++ [part]
                    ) [] parts;
                    pkg = builtins.foldl' (attrs: name:
                      attrs.''${name}
                    ) pkgs' parts';
                  in
                    (builtins.trace parts')
                    pkg
                )
                config.packages;
            };
        toModule = path:
          if lib.hasPrefix "./" path
          then ./. + (builtins.substring 1 255 path) + "/devenv.nix"
          else if lib.hasPrefix "../" path 
          then throw "devenv: ../ is not supported for imports"
          else let
            paths = lib.splitString "/" path;
            name = builtins.head paths;
            input = inputs.''${name} or (throw "Unknown input ''${name}");
            subpath = "/''${lib.concatStringsSep "/" (builtins.tail paths)}";
            devenvpath =
              if builtins.pathExists "''${input}/" + subpath + "/devenv.nix" then
                "''${input}/" + subpath + "/devenv.nix"
              else if builtins.pathExists "''${input}/" + subpath + "/devenv.box" then
                configToModule (dotbox.import 
                  ("''${input}/" + subpath + "/devenv.box")
                )
              else
                builtins.throw "No devenv.nix or devenv.box file found for input: ''${input}/.";
            in if (!devenv.inputs.''${name}.flake or true) && builtins.pathExists devenvpath
               then devenvpath
               else throw (devenvpath + " file does not exist for input ''${name}.");
        userConfig =
          if builtins.pathExists ./devenv.nix then
            ./devenv.nix
          else if builtins.pathExists ./devenv.box then
            configToModule (dotbox.import ./devenv.box)
          else
            builtins.throw "No devenv.nix or devenv.box file found.";
        project = pkgs.lib.evalModules {
          specialArgs = inputs // { inherit inputs pkgs; };
          modules = [
            (inputs.devenv.modules + /top-level.nix)
            { devenv.cliVersion = "${version}"; }
          ] ++ (map toModule (devenv.imports or [])) ++ [
            userConfig
            (devenv.devenv or {})
            (if builtins.pathExists ./devenv.local.nix then ./devenv.local.nix else {})
          ];
        };
        config = project.config;
      in {
        packages."${pkgs.system}" = {
          ci = pkgs.runCommand "ci" {} ("ls " + toString config.ci + " && touch $out");
          inherit (config) info procfileScript procfileEnv procfile;
        };
        devShell."${pkgs.system}" = config.shell;
      };
  }
''
