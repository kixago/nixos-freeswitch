{ config, lib, pkgs, ... }:

let
  # Import the package we made in Step 2
  myFreeswitch = pkgs.callPackage ./pkgs/freeswitch.nix {};
in
{
  # 1. Create the User (System User = No login allowed)
  users.groups.freeswitch = {};
  users.users.freeswitch = {
    isSystemUser = true;
    group = "freeswitch";
    description = "FreeSWITCH Daemon User";
  };

  # 2. Define the Service
  systemd.services.freeswitch = {
    description = "FreeSWITCH Daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # Prepare directories before running
    preStart = ''
      mkdir -p /var/lib/freeswitch/{db,log,run,scripts,recordings}
      
      # Copy config files from /etc/nixos/fs-conf to /etc/freeswitch
      rm -rf /etc/freeswitch
      cp -r /etc/nixos/fs-conf /etc/freeswitch
      
      # Make sure the user owns them
      chown -R freeswitch:freeswitch /var/lib/freeswitch /etc/freeswitch
    '';

    serviceConfig = {
      Type = "forking";
      PIDFile = "/run/freeswitch/freeswitch.pid";
      User = "freeswitch";
      Group = "freeswitch";
      
      ExecStart = ''
        ${myFreeswitch}/bin/freeswitch \
          -nc \
          -nonat \
          -conf /etc/freeswitch \
          -log /var/lib/freeswitch/log \
          -db /var/lib/freeswitch/db \
          -run /run/freeswitch
      '';
      
      # Allow binding ports like 5060
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_SYS_NICE" ];
    };
  };

  # 3. Open Firewall
  networking.firewall.allowedTCPPorts = [ 5060 5061 ];
  networking.firewall.allowedUDPPorts = [ 5060 5061 ] ++ lib.range 16384 32768;
  
  # 4. Add the binary to your path so you can type 'fs_cli'
  environment.systemPackages = [ myFreeswitch ];
}
