{ inputs, pkgs, ... }:
{
  home.packages = with pkgs; [
    # Core Editors
    nano
    micro

    # Modern Coreutils
    eza
    ripgrep
    fd
    bat

    # Productivity Tools
    fzf
    tmux
    tealdeer

    # Utilities
    ipcalc

    # System Monitoring
    btop
  ];

  home.sessionVariables = {
    EDITOR = inputs.nixpkgs.lib.mkDefault "micro";
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    initContent = ''
      bindkey "^[[1;5C" forward-word
      bindkey "^[[1;5D" backward-word
    '';

    shellAliases = {
      ls = "eza --smart-group --icons";
      la = "eza --smart-group -a --icons";
      ll = "eza --smart-group -l --icons";
      cat = "bat";
      grep = "grep --color=auto";
    };

    history = {
      size = 10000;
      ignoreAllDups = true;
      path = "$HOME/.zsh_history";
    };
  };

  programs.home-manager.enable = true;
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;
  programs.starship.enable = true;
  programs.git.enable = true;
  programs.zoxide.enable = true;
}
