{ inputs }:
{
  config.nstdl.profiles = {
    nixos = {
      foreign-binaries = { programs.nix-ld.enable = true; };
      container-development = { pkgs, ... }: { environment.systemPackages = [ pkgs.podman-compose ]; };
      remote-desktop = { pkgs, ... }: {
        networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];
      };
      full-stack-developer = { pkgs, ... }: {
        programs.nix-ld.enable = true;
        environment.systemPackages = [ pkgs.podman-compose ];
      };
    };
    home = {
      javascript-development = { pkgs, ... }: { home.packages = with pkgs; [ nodejs_26 pnpm bun deno typescript-language-server oxlint oxfmt ]; };
      python-development = { pkgs, ... }: { home.packages = [ pkgs.python3 ]; };
      native-development = { pkgs, ... }: { home.packages = with pkgs; [ rustup gcc ]; };
      database-client = { pkgs, ... }: { home.packages = with pkgs; [ postgresql_18 dbeaver-bin ]; };
      developer-extras = { pkgs, ... }: { home.packages = with pkgs; [ aria2 bc e2fsprogs graphviz libpst repomix d2 iotop nmon wl-clipboard-rs iputils ]; };
      office-tools = { pkgs, ... }: { home.packages = with pkgs; [ libreoffice-fresh hunspell hunspellDicts.en_US hunspellDicts.de_DE hyphenDicts.en_US hyphenDicts.de_DE typst pandoc pdfcpu poppler-utils qpdf ]; };
      creative-media = { pkgs, ... }: { home.packages = with pkgs; [ ffmpeg gimp easyeffects ]; };
      remote-desktop = { pkgs, ... }: { home.packages = with pkgs; [ rclone remmina rustdesk-flutter ]; };
      messaging = { pkgs, ... }: { home.packages = [ pkgs.signal-desktop ]; };
      gnome-extras = { pkgs, ... }: { home.packages = with pkgs; [ gnome-tweaks keepassxc gnome-disk-utility dconf-editor devhelp gnome-builder sysprof gnomeExtensions.appindicator gnomeExtensions.launch-new-instance gnomeExtensions.status-icons gnomeExtensions.uptime-kuma-indicator htop usbutils ]; };
      vscode = { ... }: { programs.vscode.enable = true; };
      ai-agent-tools = { pkgs, ... }: { home.packages = [ pkgs.claude-code ]; };
      secret-admin = { pkgs, ... }:
        let
          diff-gen = pkgs.writeShellApplication {
            name = "diff-gen";
            runtimeInputs = [ pkgs.nvd ];
            text = ''
              current=/run/current-system
              profile=/nix/var/nix/profiles/system
              case $# in
                0) from=$current; to=$profile ;;
                1) from=$current; to="''${profile}-$1-link" ;;
                2) from="''${profile}-$1-link"; to="''${profile}-$2-link" ;;
                *) echo "Usage: diff-gen [generation [generation]]" >&2; exit 2 ;;
              esac
              test -e "$from" && test -e "$to"
              ${pkgs.nvd}/bin/nvd diff "$from" "$to"
            '';
          };
        in
        { home.packages = [
          pkgs.age
          pkgs.nix-du
          pkgs.nix-tree
          pkgs.deploy-rs
          inputs.ragenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          diff-gen
        ]; };
      full-stack-developer = { pkgs, ... }: {
        home.packages = with pkgs; [ nodejs_26 pnpm bun deno typescript-language-server oxlint oxfmt python3 rustup gcc postgresql_18 dbeaver-bin aria2 graphviz libpst repomix d2 iotop nmon wl-clipboard-rs iputils ];
      };
    };
  };
}
