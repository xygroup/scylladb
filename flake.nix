{
  description = "Monstrously Fast + Scalable NoSQL";

  inputs = {
    # Pin to nixos-23.11 which has llvmPackages_15
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: {
    overlays.default = import ./dist/nix/overlay.nix nixpkgs;

    lib = {
      _attrs = system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          config = {
            permittedInsecurePackages = [ "python-2.7.18.7" "python-2.7.18.8" ];
          };
        };

        repl = pkgs.writeText "repl" ''
          let
            self = builtins.getFlake (toString ${self.outPath});
            attrs = self.lib._attrs "${system}";
          in {
            inherit self;
            inherit (attrs) pkgs;
          }
        '';

        args = {
          flake = true;
          srcPath = "${self}";
          inherit pkgs repl;
        };

        package = import ./default.nix args;
        devShell = import ./shell.nix args;
      in {
        inherit pkgs args package devShell;
      };
    };
  }
  // (flake-utils.lib.eachDefaultSystem (system: let
    packageName = "scylla";
    attrs = self.lib._attrs system;
  in {
    packages.${packageName} = attrs.package;
    defaultPackage = self.packages.${system}.${packageName};

    inherit (attrs) devShell;
  }));
}
