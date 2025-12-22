{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.freeswitch;
  
  # Create a custom package instance based on the user's config
  freeswitchPkg = pkgs.callPackage ../pkgs/freeswitch/default.nix {
    enabledModules = cfg.enabledModules;
  };

in {
  options.services.freeswitch = {
    enable = mkEnableOption "FreeSWITCH Telephony Platform";

    package = mkOption {
      type = types.package;
      default = freeswitchPkg;
      description = "The FreeSWITCH package to use (automatically built with your selected modules).";
    };

    enabledModules = mkOption {
      type = types.listOf types.str;
      default = [
        "loggers/mod_console"
        "loggers/mod_logfile"
        "applications/mod_commands"
        "applications/mod_dptools"
        "applications/mod_db"
        "applications/mod_esl"
        "endpoints/mod_sofia"
        "endpoints/mod_loopback"
        "event_handlers/mod_event_socket"
        "formats/mod_sndfile"
        "formats/mod_native_file"
        "dialplans/mod_dialplan_xml"
        "codecs/mod_g711"
        "codecs/mod_g722"
      ];
      description = "List of FreeSWITCH modules to compile and enable.";
      example = [ "codecs/mod_opus" "applications/mod_curl" ];
    };

    configDir = mkOption {
      type = types.path;
      description = "Path to the configuration directory (conf/ directory structure).";
    };
  };

  config = mkIf cfg.enable {
    
    # 1. User Account
    users.groups.freeswitch = {};
    users.users.freeswitch = {
      isSystemUser = true;
      group = "freeswitch";
      description = "FreeSWITCH Daemon User";
    };

    # 2. The Service
    systemd.services.freeswitch = {
      description = "FreeSWITCH Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      preStart = ''
        mkdir -p /var/lib/freeswitch/{db,log,run,scripts,recordings,storage}
        
        # Deploy the user-specified config to /etc/freeswitch
        rm -rf /etc/freeswitch
        cp -r ${cfg.configDir} /etc/freeswitch
        chmod -R u+w /etc/freeswitch
        
        chown -R freeswitch:freeswitch /var/lib/freeswitch /etc/freeswitch
      '';

      serviceConfig = {
        Type = "forking";
        PIDFile = "/run/freeswitch/freeswitch.pid";
        User = "freeswitch";
        Group = "freeswitch";
        ExecStart = ''
          ${cfg.package}/bin/freeswitch \
            -nc -nonat \
            -conf /etc/freeswitch \
            -log /var/lib/freeswitch/log \
            -db /var/lib/freeswitch/db \
            -run /run/freeswitch
        '';
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_SYS_NICE" ];
        # High performance settings
        LimitCORE = "infinity";
        LimitNOFILE = "100000";
        IOSchedulingClass = "realtime";
        IOSchedulingPriority = 2;
        CPUSchedulingPolicy = "rr";
        CPUSchedulingPriority = 89;
      };
    };

    # 3. Networking
    networking.firewall = {
      allowedTCPPorts = [ 5060 5061 8021 ]; # 8021 is ESL
      allowedUDPPorts = [ 5060 5061 ] ++ range 16384 32768;
    };
    
    # 4. Add CLI to system path
    environment.systemPackages = [ cfg.package ];
  };
}
