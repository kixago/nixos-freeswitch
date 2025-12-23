***

```markdown
# NixOS FreeSWITCH Module

This repository contains a NixOS Flake for deploying a container-ready, fully declarative build of FreeSWITCH (v1.10+).

It abstracts the complex XML configuration of FreeSWITCH into native Nix syntax, allowing for reproducible telephony deployments. It specifically addresses the challenges of compiling FreeSWITCH C-dependencies on non-FHS systems and managing Real-Time Protocol (RTP) scheduling within restricted container environments (LXC/Docker).

## Integration

Add this repository to your `flake.nix` inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    freeswitch.url = "github:kixago/nixos-freeswitch";
  };

  outputs = { self, nixpkgs, freeswitch, ... }: {
    nixosConfigurations.container = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        freeswitch.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

## Configuration

The module provides options to configure modules, SIP profiles, and dialplans without modifying raw XML files.

### Service Activation
Basic configuration to enable the daemon and load specific modules (e.g., Sofia for SIP, ESL for external control).

```nix
services.freeswitch = {
  enable = true;
  
  # Selectively compile and load modules to reduce footprint
  enabledModules = [
    "endpoints/mod_sofia"             # SIP Signaling
    "event_handlers/mod_event_socket" # ESL (Go/Python Interop)
    "applications/mod_dptools"        # Dialplan Tools
    "codecs/mod_opus"                 # High-fidelity Audio
    "codecs/mod_g711"                 # Legacy Audio
  ];
  
  # Networking configuration for NAT traversal
  sipTcpPorts = [ 5060 5080 ];
  rtpStartPort = 16384;
  rtpEndPort = 32768;
};
```

### Declarative SIP Profiles
SIP Profiles define how FreeSWITCH listens for traffic (e.g., Internal for local extensions, External for carrier gateways).

```nix
services.freeswitch.sipProfiles = {
  
  # Internal Profile: Listens on loopback/LAN for extension registration
  internal = {
    "sip-ip" = "127.0.0.1";
    "rtp-ip" = "127.0.0.1";
    "sip-port" = "5060";
    "context" = "default";
    "codec-prefs" = "OPUS,PCMU,PCMA";
  };

  # External Profile: Interface for upstream VoIP providers
  external = {
    "sip-ip" = "0.0.0.0";
    "sip-port" = "5080";
    "context" = "public";
    "ext-rtp-ip" = "auto-nat";
    "ext-sip-ip" = "auto-nat";
  };
};
```

### Declarative Dialplan
Dialplans are defined as Nix attribute sets, which are generated into XML at runtime. This allows for conditional routing logic managed via infrastructure-as-code.

```nix
services.freeswitch.dialplan = {
  
  # The 'default' context handles authenticated internal calls
  default = {
    conditions = [
      
      # Condition: Echo Test
      # Regex matches exactly "9196"
      {
        field = "destination_number";
        expression = "^9196$";
        actions = [
          { app = "answer"; }
          { app = "echo"; }
        ];
      }

      # Condition: Outbound Bridge
      # Regex captures 10 or 11 digit numbers into $1
      {
        field = "destination_number";
        expression = "^(\\d{10,11})$";
        actions = [
          { app = "set"; data = "effective_caller_id_number=15550000000"; }
          { app = "bridge"; data = "sofia/external/$1@sip.upstream-carrier.com"; }
        ];
      }
    ];
  };
};
```

## Operation

The module ensures `fs_cli` is available in the system path for interaction with the running daemon.

**Connect to Event Socket:**
```bash
fs_cli
```

**Verify SIP Registration:**
```bash
fs_cli -x "sofia status"
```

**View Active Channels:**
```bash
fs_cli -x "show channels"
```

## Architecture Notes

### Systemd & Containerization
Running FreeSWITCH in containers (LXC/Docker) presents specific challenges regarding process forking and CPU scheduling. This module overrides standard service behaviors to ensure stability:

*   **Service Type:** Uses `Type=simple` with the `-nf` (No Fork) flag to prevent PID tracking issues inherent to systemd inside containers.
*   **Capabilities:** Sets `AmbientCapabilities=CAP_NET_BIND_SERVICE` to allow binding standard SIP ports (5060) without running as root.
*   **Scheduling:** Automatically detects container environments to suppress `SCHED_FIFO` (Real-Time) priority requests, which are typically rejected by container runtimes and cause process crashes.

### Compilation
The package derivation handles the patching required to build FreeSWITCH 1.10+ on NixOS:
*   Patches `apr` and `libtool` configurations to resolve pathing issues during `autoreconf`.
*   Disables `Werror` to allow compilation on modern GCC versions where strict warnings would otherwise halt the build.
```
