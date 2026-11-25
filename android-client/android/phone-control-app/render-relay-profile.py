"""Generate a private per-host CA configuration only in the Android build directory."""
import ipaddress
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root, output = map(Path, sys.argv[1:])
lan = ipaddress.IPv4Address(os.environ['AIRSIM_RELAY_LAN_IP'])
tunnel = ipaddress.IPv4Address(os.environ['AIRSIM_RELAY_TUNNEL_IP'])
private_ranges = [ipaddress.IPv4Network(net) for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
if lan == tunnel or not all(any(ip in net for net in private_ranges) for ip in (lan, tunnel)):
    sys.exit('The LAN and tunnel endpoints must be distinct private IPv4 addresses.')

ca = Path(os.environ['AIRSIM_RELAY_CA_FILE']).read_bytes().strip()
if not re.fullmatch(rb'-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----', ca):
    sys.exit('Supply one public root CA certificate in PEM format.')
def openssl(*args):
    return subprocess.run(['openssl', 'x509', *args], input=ca, capture_output=True, check=True).stdout
openssl('-checkend', '0', '-noout')
if b'CA:TRUE' not in openssl('-noout', '-ext', 'basicConstraints'):
    sys.exit('The certificate must be a CA.')
resources = output / 'res'
shutil.copytree(root / 'res', resources)
(resources / 'raw/airsim_private_relay_ca.pem').write_bytes(openssl('-outform', 'PEM'))
(resources / 'xml/standalone_network_security.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config>
        <trust-anchors>
            <certificates src="system" />
            <certificates src="@raw/airsim_private_relay_ca" />
        </trust-anchors>
        <domain includeSubdomains="false">{tunnel}</domain>
        <domain-config cleartextTrafficPermitted="true">
            <domain includeSubdomains="false">{lan}</domain>
        </domain-config>
    </domain-config>
</network-security-config>
''')
(output / 'RelayProfile.java').write_text(f'''package com.airsim.phonecontrol;

final class RelayProfile {{
    static final String LAN = "{lan}";
    static final String TUNNEL = "{tunnel}";
}}
''')
