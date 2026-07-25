{ pkgs, ... }:
{
  home.packages = with pkgs; [
    btop
    gping
    hexyl
    hyperfine
    micro
    nixfmt
    procs
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
    bat.enable = true;
    fd.enable = true;
    ripgrep.enable = true;
    eza = {
      enable = true;
      icons = "auto";
      git = true;
      extraOptions = [ "--smart-group" ];
    };

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
      initContent = ''
        WORDCHARS=''${WORDCHARS//[-.\/=]/}
        setopt autocd extendedglob nomatch

        autoload -U up-line-or-beginning-search down-line-or-beginning-search
        zle -N up-line-or-beginning-search
        zle -N down-line-or-beginning-search

        bindkey "^[[1;5C" forward-word
        bindkey "^[[1;5D" backward-word
        bindkey "^[[A" up-line-or-beginning-search
        bindkey "^[[B" down-line-or-beginning-search
      '';
      shellAliases = {
        cat = "bat";
        lg = "lazygit";
        grep = "grep --color=auto";
        ".." = "cd ..";
        "..." = "cd ../..";
        "...." = "cd ../../..";
      };
      history = {
        size = 100000;
        path = "$HOME/.zsh_history";
      };
    };

    nushell = {
      enable = true;
      shellAliases = {
        cat = "bat";
        lg = "lazygit";
      };
      environmentVariables.EDITOR = "micro";
      extraEnv = ''
        if ($env.GHOSTTY_RESOURCES_DIR? | is-not-empty) {
          $env.NU_VENDOR_AUTOLOAD_DIRS = (
            $env.NU_VENDOR_AUTOLOAD_DIRS?
              | default []
              | prepend ($env.GHOSTTY_RESOURCES_DIR | path join "shell-integration/nushell/vendor/autoload")
          )
        }
      '';
      extraConfig = ''
        $env.config = ($env.config? | default {} | merge {
          show_banner: false
          edit_mode: emacs
          footer_mode: "auto"
          history: {
            max_size: 100000
            file_format: "sqlite"
            isolation: false
          }
          completions: {
            case_sensitive: false
            quick: true
            partial: true
            algorithm: "fuzzy"
          }
          cursor_shape: { emacs: line }
          table: { trim: { methodology: "wrapping", wrapping_try_keep_words: true } }
        })

        def hints-for-command [line: string] {
          let hints = {
            find: { modern: "fd config.nu", nuOwns: "piped" }
            grep: { modern: "rg TODO", nu: "... | where $it =~ 'pattern'" }
            cat: { modern: "bat shell.nix", nu: "open file  (structured) or `open --raw file`" }
            sed: { modern: "sd 'old' 'new' file", nu: "... | str replace 'old' 'new'" }
            du: { modern: "dust -d 2" }
            df: { modern: "duf" }
            top: { modern: "btop" }
            diff: { modern: "difft a.nix b.nix" }
            hexdump: { modern: "hexyl file.bin" }
            tree: { modern: "eza --tree --git-ignore" }
            ping: { modern: "gping 1.1.1.1" }
          }
          $line
            | str trim
            | split row '|'
            | each {|entry|
                let parts = ($entry | str trim | split row ' ' | where {|word| $word != "" })
                let command = ($parts | first | default "" | str replace --regex '^\^' "")
                let hint = ($hints | get --optional $command)
                if $hint == null { null } else {
                  [
                    ($hint | get --optional modern | if $in == null { null } else { $"modern: ($in)" })
                    ($hint | get --optional nu | if $in == null { null } else { $"nu: ($in)" })
                  ] | where {|value| $value != null } | str join "  |  "
                }
              }
            | where {|hint| $hint != null }
            | uniq
        }

        $env.LAST_HINTS = []
        $env.config.hooks.pre_execution = ($env.config.hooks.pre_execution? | default [] | append [
          '
            let hints = (hints-for-command (commandline))
            $env.LAST_HINTS = $hints
            for hint in $hints { print --stderr $"\e[2m💡 ($hint)\e[0m" }
          '
        ])
        $env.config.hooks.pre_prompt = ($env.config.hooks.pre_prompt? | default [] | append [
          '
            for hint in ($env.LAST_HINTS? | default []) { print --stderr $"\e[2m💡 ($hint)\e[0m" }
            $env.LAST_HINTS = []
          '
        ])
        $env.config.keybindings = ($env.config.keybindings? | default [] | append [
          {
            name: fzf_insert_file
            modifier: control
            keycode: char_t
            mode: [emacs vi_normal vi_insert]
            event: { send: executehostcommand, cmd: "commandline edit --insert (^fd --type f --hidden --exclude .git | ^fzf --height 40% --reverse --preview 'bat --style=numbers --color=always {}' | str trim)" }
          }
          {
            name: fzf_cd
            modifier: alt
            keycode: char_c
            mode: [emacs vi_normal vi_insert]
            event: { send: executehostcommand, cmd: "let dir = (^fd --type d --hidden --exclude .git | ^fzf --height 40% --reverse | str trim); if ($dir | is-not-empty) { cd $dir }" }
          }
        ])
      '';
    };

    git = {
      enable = true;
      settings = {
        init.defaultBranch = "main";
        pull.rebase = true;
      };
    };
    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        navigate = true;
        line-numbers = true;
        side-by-side = true;
      };
    };
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
