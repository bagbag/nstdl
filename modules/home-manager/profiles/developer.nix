{ pkgs, ... }:
{
  home.packages = with pkgs; [
    bat
    btop
    eza
    fd
    fzf
    gping
    hexyl
    hyperfine
    lazygit
    micro
    nixfmt
    procs
    ripgrep
    sd
    tealdeer
    tmux
    doggo
    difftastic
    duf
    dust
  ];

  home.sessionVariables.EDITOR = "micro";

  programs = {
    zsh = {
      enable = true;
      profileExtra = ''
        if [[ -o interactive && -t 0 && -t 1 ]]; then
          exec ${pkgs.nushell}/bin/nu --login
        fi
      '';
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
    };

    nushell = {
      enable = true;
      shellAliases = {
        cat = "bat";
        lg = "lazygit";
      };
      extraConfig = ''
        $env.config = ($env.config? | default {} | merge {
          show_banner: false
          edit_mode: emacs
          history: {
            max_size: 100000
            file_format: "sqlite"
          }
          completions: {
            case_sensitive: false
            quick: true
            partial: true
            algorithm: "fuzzy"
          }
        })
      '';
    };

    git.enable = true;
    nix-index = {
      enable = true;
      enableZshIntegration = true;
    };
    nix-index-database.comma.enable = true;
    starship.enable = true;
    zoxide.enable = true;
    lazygit.enable = true;
    fzf = {
      enable = true;
      enableZshIntegration = true;
      historyWidget.command = "";
    };
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    atuin = {
      enable = true;
      enableZshIntegration = true;
      flags = [ "--disable-up-arrow" ];
      settings = {
        auto_sync = false;
        update_check = false;
        search_mode = "fuzzy";
        filter_mode = "global";
        style = "compact";
        inline_height = 20;
      };
    };
  };

  home.shell.enableNushellIntegration = true;
}
