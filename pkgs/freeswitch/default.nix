{ lib, stdenv, fetchFromGitHub, autoreconfHook, pkg-config, libtool
, zlib, sqlite, pcre, pcre2, speex, speexdsp, libedit, openssl, libuuid
, curl, libjpeg, ldns, yasm, which
, perl
, spandsp3
, sofia_sip
, libopus
, bcg729
, libsndfile
, lua
, postgresql
, python3
, modules ? [
    "loggers/mod_console"
    "loggers/mod_logfile"
    "applications/mod_commands"
    "applications/mod_dptools"
    "endpoints/mod_sofia"
    "endpoints/mod_loopback"
    "event_handlers/mod_event_socket"
    "codecs/mod_g711"
    "codecs/mod_g722"
  ]
}:

let
  dependencyMap = {
    "codecs/mod_opus"       = [ libopus ];
    "codecs/mod_g729"       = [ bcg729 ];
    "formats/mod_sndfile"   = [ libsndfile ];
    "languages/mod_lua"     = [ lua ];
    "languages/mod_python3" = [ python3 ];
    "databases/mod_pgsql"   = [ postgresql ];
  };

  baseInputs = [
    sqlite pcre pcre2 speex speexdsp libedit openssl libuuid
    curl libjpeg ldns zlib
    spandsp3
    sofia_sip
    postgresql
    libtool  # Add libtool to buildInputs
  ];

  extraInputs = lib.concatLists (lib.mapAttrsToList (modName: libs:
    if builtins.elem modName modules then libs else []
  ) dependencyMap);

in stdenv.mkDerivation rec {
  pname = "freeswitch";
  version = "unstable-2024-12-23";

  configureFlags = [ "--disable-werror" ];

  env.NIX_CFLAGS_COMPILE = "-Wno-error -fpermissive";
  enableParallelBuilding = false;

  src = fetchFromGitHub {
    owner = "signalwire";
    repo = "freeswitch";
    rev = "master";
    sha256 = "sha256-5BCsD4Sm5/C9i+1vMo8InIhzBTU8mYj5hsqLWrTf/kw=";
  };

  nativeBuildInputs = [ autoreconfHook pkg-config which yasm perl libtool ];
  buildInputs = baseInputs ++ extraInputs;

  postPatch = ''
    patchShebangs libs/libvpx
    export AS="yasm"

    # Fix the libtool path issue in APR's build system
    # The problem is in build/apr_rules.mk.in where LIBTOOL is set
    
    # Method 1: Fix the apr_rules.mk.in template
    if [ -f libs/apr/build/apr_rules.mk.in ]; then
      substituteInPlace libs/apr/build/apr_rules.mk.in \
        --replace '@LIBTOOL@' '$(SHELL) $(top_builddir)/libtool'
    fi

    # Method 2: Also fix configure.in/configure.ac if they hardcode paths
    for f in libs/apr/configure.in libs/apr/configure.ac libs/apr/configure; do
      if [ -f "$f" ]; then
        sed -i 's|LIBTOOL="\$LIBTOOL"|LIBTOOL="\$(SHELL) \$(top_builddir)/libtool"|g' "$f" || true
        sed -i 's|LIBTOOL="/libtool"|LIBTOOL="\$(SHELL) \$(top_builddir)/libtool"|g' "$f" || true
      fi
    done

    # Method 3: Fix the bundled libtool scripts
    find libs/apr -name "ltmain.sh" -exec sed -i 's|/libtool|./libtool|g' {} \; || true

    echo "" > modules.conf
    ${lib.concatMapStrings (m: "echo '${m}' >> modules.conf\n") modules}
  '';

  # Add a preConfigure hook to ensure libtool is properly set up in APR
  preConfigure = ''
    # Ensure APR can find libtool
    export LIBTOOL="${libtool}/bin/libtool"
    
    # If APR has its own bootstrap, run it
    if [ -f libs/apr/buildconf ]; then
      pushd libs/apr
      ./buildconf || true
      popd
    fi
  '';

  # Hook to fix libtool path after configure runs but before make
  postConfigure = ''
    # Fix any generated Makefiles that have the wrong libtool path
    find libs/apr -name "Makefile" -o -name "apr_rules.mk" | while read f; do
      if [ -f "$f" ]; then
        sed -i "s|/libtool|$PWD/libs/apr/libtool|g" "$f" || true
        sed -i "s| /libtool| $PWD/libs/apr/libtool|g" "$f" || true
      fi
    done
    
    # Also check if libtool exists in the apr directory
    if [ ! -f libs/apr/libtool ]; then
      echo "WARNING: libs/apr/libtool not found, copying from system"
      cp ${libtool}/bin/libtool libs/apr/libtool || true
      chmod +x libs/apr/libtool
    fi
  '';

  postInstall = ''
    mkdir -p $out/share/freeswitch/conf/vanilla
    cp -r conf/vanilla/* $out/share/freeswitch/conf/vanilla/
  '';

  meta = with lib; {
    description = "Cross-Platform Scalable Telephony Platform";
    license = licenses.mpl11;
    platforms = platforms.linux;
  };
}
