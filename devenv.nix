{ pkgs, ... }:

{
  name = "actions";

  languages = {
    python = {
      enable = true;
      package = pkgs.python314;
    };
  };

  packages = with pkgs; [ ast-grep ];

  git-hooks.hooks = {
    ruff.enable = true;
    ruff-format.enable = true;
    ripsecrets.enable = true;
    actionlint.enable = true;
    shellcheck.enable = true;
  };

  treefmt.config.programs = {
    shfmt.enable = true;
  };
}
