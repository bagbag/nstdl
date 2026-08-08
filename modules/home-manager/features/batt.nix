{ lib, ... }:
{
  programs.nushell.extraConfig = lib.mkAfter ''
    def "nu-complete batt log level" [] {
      [trace debug info warn error fatal panic]
    }

    def "nu-complete batt duration" [] {
      [30m 1h 2h 4h 8h 12h 1d 2d 1w]
    }

    def "nu-complete batt percentage" [] {
      10..100 | each {|percentage| { value: ($percentage | into string) } }
    }

    def "nu-complete batt lower-limit-delta" [] {
      1..20 | each {|delta| { value: ($delta | into string) } }
    }

    def "nu-complete batt command" [] {
      [
        [value description]
        [disable "Temporarily or permanently disable the charge limit"]
        [limit "Set the upper charge limit"]
        [lower-limit-delta "Set the gap below the upper limit"]
        [status "Show the current charge-limit status"]
        [version "Show batt version information"]
        [completion "Generate a completion script for a supported shell"]
        [help "Show batt command help"]
      ]
    }

    def "nu-complete batt completion shell" [] {
      [bash fish powershell zsh]
    }

    extern batt [
      command?: string@"nu-complete batt command"
      --config: path                         # Config file path
      --daemon-socket: path                  # Daemon socket path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt disable" [
      --for: string@"nu-complete batt duration"
      --config: path
      --daemon-socket: path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt limit" [
      percentage?: int@"nu-complete batt percentage"
      --config: path
      --daemon-socket: path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt lower-limit-delta" [
      delta?: int@"nu-complete batt lower-limit-delta"
      --config: path
      --daemon-socket: path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt status" [
      --config: path
      --daemon-socket: path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt version" [
      --config: path
      --daemon-socket: path
      --log-level(-l): string@"nu-complete batt log level"
      --pprof: string
      -h --help
    ]

    extern "batt completion" [
      shell?: string@"nu-complete batt completion shell"
      -h --help
    ]

    extern "batt help" [
      command?: string@"nu-complete batt command"
      -h --help
    ]
  '';
}
