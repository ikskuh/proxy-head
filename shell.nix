{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  nativeBuildInputs = [pkgs.pkg-config pkgs.zig_0_11_0];
  buildInputs = [pkgs.SDL2];
}
