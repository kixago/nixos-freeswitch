{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.freeswitch;
  isContainer = config.boot.isContainer;

  freeswitchPkg = pkgs.callPackage ../pkgs/freeswitch/default.nix {
    modules = cfg.enabledModules;
  };

  mkParams = params: concatStringsSep "\n" (mapAttrsToList (k: v: ''      <param name="${k}" value="${v}"/>'') params);
  mkUser = id: userCfg: ''<user id="${id}"><params><param name="password" value="${userCfg.password}"/>${userCfg.extraParams or ""}</params><variables><variable name="user_context" value="${userCfg.context}"/>${userCfg.extraVariables or ""}</variables></user>'';
  mkActions = actions: concatStringsSep "\n" (map (a: ''        <action application="${a.app}" data="${a.data or ""}"/>'') actions);
  mkConditions = conditions: concatStringsSep "\n" (map (c: ''      <condition field="${c.field}" expression="${c.expression}">${mkActions c.actions}      </condition>'') conditions);
  mkExtensions = extensions: concatStringsSep "\n" (mapAttrsToList (name: ext: ''    <extension name="${name}">${mkConditions ext.conditions}    </extension>'') extensions);

in {
  options.services.freeswitch = {
    enable = mkEnableOption "FreeSWITCH Telephony Platform";

    package = mkOption {
      type = types.package;
      default = freeswitchPkg;
      description = "The FreeSWITCH package to use.";
    };

    enabledModules = mkOption {
      type = types.listOf types.str;
      default = [
        "loggers/mod_console" 
        "loggers/mod_logfile"
        "applications/mod_commands" 
        "applications/mod_dptools" 
        "applications/mod_db"
        "endpoints/mod_sofia" 
        "endpoints/mod_loopback"
        "event_handlers/mod_event_socket" 
        "dialplans/mod_dialplan_xml"
        "codecs/mod_g711" 
        "codecs/mod_g722" 
        "codecs/mod_opus"
      ];
      description = "List of FreeSWITCH modules to compile/load.";
    };

    configDir = mkOption {
      type = types.path;
      default = "${freeswitchPkg}/share/freeswitch/conf/vanilla";
      description = "Path to config directory.";
    };

    user = mkOption { type = types.str; default = "freeswitch"; };
    group = mkOption { type = types.str; default = "freeswitch"; };

    vars = mkOption { type = types.attrsOf types.str; default = {}; };
    sipProfiles = mkOption { type = types.attrsOf (types.attrsOf types.str); default = {}; };
    directory = mkOption { type = types.attrsOf (types.attrsOf (types.submodule { 
      options = { 
        password = mkOption { type = types.str; }; 
        context = mkOption { type = types.str; default = "default"; }; 
        extraParams = mkOption { type = types.str; default = ""; }; 
        extraVariables = mkOption { type = types.str; default = ""; }; 
      }; 
    })); default = {}; };
    dialplan = mkOption { type = types.attrsOf (types.attrsOf (types.submodule { 
      options = { 
        conditions = mkOption { 
          type = types.listOf (types.submodule { 
            options = { 
              field = mkOption { type = types.str; }; 
              expression = mkOption { type = types.str; }; 
              actions = mkOption { 
                type = types.listOf (types.submodule { 
                  options = { 
                    app = mkOption { type = types.str; }; 
                    data = mkOption { type = types.str; default = ""; }; 
                  }; 
                }); 
              }; 
            }; 
          }); 
        }; 
      }; 
    })); default = {}; };

    sipTcpPorts = mkOption { type = types.listOf types.port; default = [ 5060 5061 ]; };
    sipUdpPorts = mkOption { type = types.listOf types.port; default = [ 5060 5061 ]; };
    rtpStartPort = mkOption { type = types.port; default = 16384; };
    rtpEndPort = mkOption { type = types.port; default = 32768; };
    eventSocketPort = mkOption { type = types.port; default = 8021; };
  };

  config = mkIf cfg.enable {
    users.groups.${cfg.group} = {};
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "FreeSWITCH Daemon User";
      home = "/var/lib/freeswitch";
      createHome = false;
    };

        systemd.services.freeswitch = {
      description = "FreeSWITCH Telephony Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "network-online.target" ];

      serviceConfig = {
        # FIX 1: Use simple for containers/foreground
        Type = "simple";
        # PIDFile is not needed for Type=simple

        User = cfg.user;
        Group = cfg.group;

        # Systemd manages these directories automatically with correct permissions
        StateDirectory = "freeswitch";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "freeswitch";
        LogsDirectory = "freeswitch";

        # FIX 2: The "+" tells systemd to run this script as ROOT,
        # even though the main service runs as the 'freeswitch' user.
        # This fixes your "Permission denied" errors.
        ExecStartPre = "+" + (pkgs.writeShellScript "freeswitch-pre-start" ''
            set -e

            # 1. Prepare directories (StateDirectory handles creation, we just structure it)
            # We use /var/lib/freeswitch/conf instead of /etc to avoid read-only errors
            CONF_DIR="/var/lib/freeswitch/conf"

            mkdir -p /var/lib/freeswitch/{db,log,scripts,recordings,storage,sounds}
            mkdir -p $CONF_DIR

            # 2. Copy base config to writable dir
            # We use cp -L to dereference symlinks from the Nix store
            cp -rL ${cfg.configDir}/* $CONF_DIR/
            chmod -R u+w $CONF_DIR

            # 3. Clean out ALL module loads from vanilla configs
            find $CONF_DIR -name "*.xml" -type f | while read f; do
              sed -i '/<load module=/d' "$f" 2>/dev/null || true
            done

            # 4. Generate clean modules.conf.xml
            mkdir -p $CONF_DIR/autoload_configs
            cat > $CONF_DIR/autoload_configs/modules.conf.xml <<'MODEOF'
            <configuration name="modules.conf" description="Modules">
              <modules>
                ${concatStringsSep "\n                " (map (modPath:
                  "<load module=\"mod_${lib.removePrefix "mod_" (baseNameOf modPath)}\"/>"
                ) cfg.enabledModules)}
              </modules>
            </configuration>
            MODEOF

            # 5. Create minimal sofia.conf.xml if it doesn't exist
            if [ ! -f $CONF_DIR/autoload_configs/sofia.conf.xml ]; then
              cat > $CONF_DIR/autoload_configs/sofia.conf.xml <<'SOFIAEOF'
            <configuration name="sofia.conf" description="sofia Endpoint">
              <global_settings>
                <param name="log-level" value="0"/>
              </global_settings>
              <profiles>
                <X-PRE-PROCESS cmd="include" data="../sip_profiles/*.xml"/>
              </profiles>
            </configuration>
            SOFIAEOF
            fi

            # 6. Create minimal internal SIP profile
            mkdir -p $CONF_DIR/sip_profiles
            if [ ! -f $CONF_DIR/sip_profiles/internal.xml ]; then
              cat > $CONF_DIR/sip_profiles/internal.xml <<'INTEOF'
            <include>
              <profile name="internal">
                <settings>
                  <param name="debug" value="0"/>
                  <param name="sip-trace" value="no"/>
                  <param name="sip-capture" value="no"/>
                  <param name="context" value="default"/>
                  <param name="sip-port" value="5060"/>
                  <param name="dialplan" value="XML"/>
                  <param name="codec-prefs" value="OPUS,G722,PCMU,PCMA"/>
                  <param name="inbound-codec-negotiation" value="generous"/>
                  <param name="rtp-ip" value="127.0.0.1"/>
                  <param name="sip-ip" value="127.0.0.1"/>
                  <param name="ext-rtp-ip" value="stun:stun.freeswitch.org"/>
                  <param name="ext-sip-ip" value="stun:stun.freeswitch.org"/>
                  <param name="rtp-timeout-sec" value="300"/>
                  <param name="rtp-hold-timeout-sec" value="1800"/>
                  <param name="ws-binding" value=""/>
                  <param name="wss-binding" value=""/>
                </settings>
              </profile>
            </include>
            INTEOF
            fi

            # 7. Create minimal dialplan
            if [ ! -d $CONF_DIR/dialplan ] || [ -z "$(ls -A $CONF_DIR/dialplan 2>/dev/null)" ]; then
              mkdir -p $CONF_DIR/dialplan
              cat > $CONF_DIR/dialplan/default.xml <<'DIALEOF'
            <include>
              <context name="default">
                <extension name="test">
                  <condition field="destination_number" expression="^9196$">
                    <action application="answer"/>
                    <action application="echo"/>
                  </condition>
                </extension>
              </context>
            </include>
            DIALEOF
            fi

            # 8. Generate vars.xml
            if [ -f $CONF_DIR/vars.xml ]; then
              mv $CONF_DIR/vars.xml $CONF_DIR/vars_defaults.xml
            else
              echo "<include/>" > $CONF_DIR/vars_defaults.xml
            fi
            cat > $CONF_DIR/vars.xml <<'VARSEOF'
            <include>
              <X-PRE-PROCESS cmd="include" data="vars_defaults.xml"/>
              ${concatStringsSep "\n              " (mapAttrsToList (k: v:
                "<X-PRE-PROCESS cmd=\"set\" data=\"${k}=${v}\"/>"
              ) cfg.vars)}
            </include>
            VARSEOF

            # 9. Ensure permissions (since this script runs as +Root)
            chown -R ${cfg.user}:${cfg.group} /var/lib/freeswitch
        '');

        # FIX 3: Added -nf (No Fork) and pointed conf to /var/lib/freeswitch/conf
        ExecStart = ''
          ${cfg.package}/bin/freeswitch \
            -nf -nc -nonat \
            -conf /var/lib/freeswitch/conf \
            -log /var/lib/freeswitch/log \
            -db /var/lib/freeswitch/db \
            -run /run/freeswitch \
            -recordings /var/lib/freeswitch/recordings
        '';

        # Container-aware capabilities
        Nice = if isContainer then 10 else 0;
        AmbientCapabilities = if isContainer
          then [ "CAP_NET_BIND_SERVICE" ]
          else [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_SYS_NICE" ];
        CapabilityBoundingSet = if isContainer
          then [ "CAP_NET_BIND_SERVICE" ]
          else [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_SYS_NICE" ];

        # Relaxed limits for container
        LimitCORE = "infinity";
        LimitNOFILE = "100000";
        LimitNPROC = "60000";
        LimitSTACK = "240000";
        Restart = "always";
        RestartSec = "5s";
      };
    };
    networking.firewall = lib.mkIf config.networking.firewall.enable {
      allowedTCPPorts = cfg.sipTcpPorts ++ [ cfg.eventSocketPort ];
      allowedUDPPorts = cfg.sipUdpPorts;
      allowedUDPPortRanges = [{ from = cfg.rtpStartPort; to = cfg.rtpEndPort; }];
    };

    environment.systemPackages = [ cfg.package ];
    environment.shellAliases = { fs_cli = "${cfg.package}/bin/fs_cli"; };
  };
}
