"""LAN discovery: the laptop advertises itself; nothing leaves the local network.

Primary: mDNS / DNS-SD service sync.service_type ("_snapy._tcp.local.") via `zeroconf`,
instance "<device_id>", TXT {id, v}. The TXT record carries no name or key: the phone
already knows the laptop's key from pairing and only needs host + port.
Fallback (zeroconf not installed or failed): a UDP multicast beacon on
sync.beacon_group:sync.beacon_port. A probe datagram b"SNAPY?1" is answered (unicast,
to the sender) with JSON {"t":"snapy","v":1,"id":device_id,"port":port}.
Phones also fall back to the last host that worked and the QR's host list.
"""
import json
import socket
import struct
import threading

from src import diag
from src.sync import conf

PROBE = b"SNAPY?1"


class Advertiser:
    def __init__(self, device_id, port, addresses, cfg=conf.get):
        self.device_id, self.port, self.addresses, self.cfg = device_id, port, list(addresses), cfg
        self.mode = None
        self._zc = self._info = None
        self._beacon = None

    def start(self):
        try:
            self._start_zeroconf()
            self.mode = "mdns"
        except Exception as e:          # noqa: BLE001 - zeroconf missing or the network refused it
            diag.record("sync.mdns", e, quiet=True)
            self._beacon = Beacon(self.device_id, self.port, self.cfg)
            try:
                self._beacon.start()
                self.mode = "beacon"
            except OSError as e2:
                diag.record("sync.beacon", e2, quiet=True)
                self.mode = None
        return self.mode

    def _start_zeroconf(self):
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
        stype = self.cfg("service_type")
        self._info = ServiceInfo(stype, f"{self.device_id}.{stype}",
                                 addresses=[socket.inet_aton(a) for a in self.addresses] or None,
                                 port=int(self.port), properties={"id": self.device_id, "v": "1"},
                                 server=f"{self.device_id}.local.")
        self._zc = Zeroconf(ip_version=IPVersion.V4Only)
        self._zc.register_service(self._info, allow_name_change=True)

    def stop(self):
        if self._zc:
            try:
                self._zc.unregister_service(self._info)
                self._zc.close()
            except Exception as e:      # noqa: BLE001
                diag.record("sync.mdns_stop", e, quiet=True)
            self._zc = None
        if self._beacon:
            self._beacon.stop()
            self._beacon = None
        self.mode = None


class Beacon:
    """Minimal multicast responder (fallback discovery)."""

    def __init__(self, device_id, port, cfg=conf.get):
        self.device_id, self.port, self.cfg = device_id, port, cfg
        self._sock = None
        self._stop = threading.Event()
        self._thread = None

    def reply(self):
        return json.dumps({"t": "snapy", "v": 1, "id": self.device_id, "port": int(self.port)}).encode()

    def start(self):
        group, bport = self.cfg("beacon_group"), int(self.cfg("beacon_port"))
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", bport))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                     struct.pack("4s4s", socket.inet_aton(group), socket.inet_aton("0.0.0.0")))
        s.settimeout(1.0)
        self._sock = s
        self._thread = threading.Thread(target=self._run, daemon=True, name="snapy-sync-beacon")
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                break
            if data == PROBE:
                try:
                    self._sock.sendto(self.reply(), addr)
                except OSError:
                    pass

    def stop(self):
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
