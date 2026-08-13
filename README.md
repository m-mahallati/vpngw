# vpngw

**Turn a Raspberry Pi into an on-demand VPN gateway for your LAN.**

Point a device's gateway and DNS at the Pi and its traffic is NATed out your VPN tunnel — kill switch, DNS leak protection, and per-client rules included. Point it back at your router and that device is unaffected. Everything is toggled with one command and nothing touches the Pi's network config until you turn it on.

```
sudo vpngw on          → LAN clients you've pointed here now exit through the VPN
sudo vpngw status       → what's on, tunnel state, live packet counters
sudo vpngw off          → fully reversed, nothing left behind
```

## Why

Most VPN clients only protect the device they're installed on. This lets any device on your LAN — a smart TV, a game console, a guest's phone, anything that can't run a VPN client itself — route through the tunnel too, just by changing its gateway/DNS. And it's opt-in per device: nothing changes for devices you don't repoint.

## Features

- **On/off toggle** — `vpngw on` / `off` / `status`, nothing persists across reboots unless you ask it to
- **Kill switch** — if the tunnel drops, client traffic is dropped too, not silently sent out the plain uplink
- **DNS leak guard** — the Pi's own resolver traffic is also confined to the tunnel
- **Per-client rules, applied live** — `vpngw block <ip>` (no internet at all), `vpngw bypass <ip>` (skip the tunnel), `vpngw user-block <ssh-user>` (drop their outbound traffic, keep their SSH login working)
- **IPv6 blocked by default** — no accidental bypass over v6
- **Self-contained** — dedicated iptables chains, `off` never touches rules it didn't create

## Requirements

- Raspberry Pi (or any Debian/Ubuntu box) with a single LAN-facing interface
- A VPN client already installed and able to bring up a tunnel interface (tested against xvpn's `xvpn-tun0`; any tunnel interface name works — set `VPN_IF`)
- Root access

## Install

```bash
git clone https://github.com/m-mahallati/vpngw.git
cd vpngw
sudo ./install.sh
```

The installer pulls in `dnsmasq`, `iptables`, `curl`, `dnsutils`, drops `vpngw` into `/usr/local/sbin`, installs the systemd unit, and auto-generates `/etc/vpngw.conf` from your current network. Check the detected values before first use:

```bash
sudo nano /etc/vpngw.conf
```

`VPN_IF` must match the tunnel your VPN client creates — confirm with `ip -br link` while the VPN is connected.

## Usage

```bash
sudo vpngw on        # enable — LAN clients now route through the tunnel
sudo vpngw off       # disable — all rules removed, dnsmasq stopped
sudo vpngw status    # what's on, tunnel state, packet counters
sudo vpngw test      # confirm the exit IP and DNS really use the tunnel
sudo vpngw restart

sudo vpngw enable-boot    # come up automatically after a reboot
sudo vpngw disable-boot
```

You can also drive the systemd unit directly (`systemctl start|stop|status vpn-gateway`) — it just calls `vpngw on` / `vpngw off`.

## Client setup

On each device you want tunneled, set a static config:

| Field   | Value            |
|---------|------------------|
| IP      | any free LAN IP  |
| Netmask | your LAN netmask |
| Gateway | the Pi's IP      |
| DNS     | the Pi's IP      |

Devices you leave alone keep using the router and are unaffected. To confirm a client is tunneled, check its public IP at e.g. `ifconfig.me` before and after.

## Per-client rules

Two kinds of "blacklist", depending on what you mean:

```bash
sudo vpngw block 192.168.1.42      # no internet through the Pi at all
sudo vpngw unblock 192.168.1.42

sudo vpngw bypass 192.168.1.77     # skip the tunnel, use the normal uplink
sudo vpngw unbypass 192.168.1.77

sudo vpngw clients                 # show both lists
```

Both accept a single IP or a CIDR range (`192.168.1.32/27`). Changes are written to `/etc/vpngw.conf` and applied immediately if the gateway is running — no restart, no dropped sessions for anyone else.

**block** drops the client's forwarded traffic in both directions *before* the established-connections rule, so open sessions die the moment you block it, and also denies it the Pi's DNS. From that device's point of view the Pi is a black hole.

**bypass** forwards the client straight back out the uplink, un-NATed, so it looks to your router exactly as if the Pi weren't in the path. Note the device is probably still using the Pi for DNS, and dnsmasq resolves over the tunnel — if you want it fully off the VPN, point its DNS at your router too.

Blocking wins if an address ends up in both lists.

### Blocking a local (SSH) user

Same idea, but for an account on the Pi rather than a device on the LAN. The user can still log in over SSH — everything they try to send out is dropped.

```bash
sudo vpngw user-block alice
sudo vpngw user-unblock alice
```

This adds an `-m owner --uid-owner alice -j DROP` rule to the OUTPUT chain, preceded by two exemptions that are always installed first:

```
-o lo                  -j RETURN     # loopback stays usable
-p tcp --sport 22      -j RETURN     # live SSH sessions survive
```

The `--sport 22` exemption is the important one. sshd's reply packets to a logged-in user are generated *as that user*, so without it a `--uid-owner` DROP would kill the very session you're blocking — including your own, if you ever block your own account. Change `SSH_PORT` in `/etc/vpngw.conf` if sshd isn't on 22.

Two caveats worth knowing:

- **It matches on uid, so `sudo` escapes it.** Anything the user runs as root comes from uid 0 and is not blocked. If that matters, take them out of the sudo group as well.
- **Existing connections drop instantly.** The owner match applies per-packet with no conntrack exemption, so downloads and sessions die the moment you run the command. `vpngw user-block` tells you how many processes that user currently has running.

## What `on` actually does

1. `net.ipv4.ip_forward=1`, ICMP redirects off, loose reverse-path filtering (traffic enters and leaves on different interfaces).
2. Creates dedicated iptables chains `VPNGW_FWD`, `VPNGW_IN`, `VPNGW_OUT`, `VPNGW_NAT` (and `VPNGW_FWD6`) so your existing rules are never flushed:
   - MASQUERADE for `LAN_CIDR` leaving `VPN_IF`
   - MSS clamping so TCP survives the tunnel's smaller MTU
   - accept established/related + LAN→tunnel, then **drop everything else from the LAN**
   - drop the Pi's own DNS queries to the upstream resolvers if they'd leave outside the tunnel
   - drop all IPv6 forwarding from the LAN
3. Writes `/etc/dnsmasq.d/vpngw.conf` and starts dnsmasq, listening on the Pi's LAN IP and forwarding to `UPSTREAM_DNS` over the tunnel, with caching and `filter-AAAA`.

`off` unhooks and deletes those chains, removes the dnsmasq drop-in, stops dnsmasq, and sets `ip_forward=0`.

## Kill switch

`KILL_SWITCH=yes` (default) means the accept rule is bound to `VPN_IF`, so if `xvpn-tun0` disappears or drops, client packets hit the final DROP instead of falling back to your plain uplink. Clients go dark rather than leaking. Set it to `no` in `/etc/vpngw.conf` if you'd rather they fall back to the normal WAN path — note that with a single-interface Pi that means hairpin NAT back out `eth0`.

The kill switch is passive: rules are keyed by interface name, so a VPN reconnect resumes working automatically with no need to re-run `vpngw on`.

`DNS_LEAK_GUARD=yes` extends this to the Pi's own resolver traffic — queries to `UPSTREAM_DNS` are dropped unless they leave via the tunnel. One caveat: if the Pi's own `/etc/resolv.conf` points at one of those same servers, the Pi loses DNS while the tunnel is down. `vpngw on` warns you if it detects this; either point `/etc/resolv.conf` at `127.0.0.1` (dnsmasq) or set `DNS_LEAK_GUARD=no`.

This also assumes your VPN client puts the Pi's **default route** through the tunnel — that's what carries dnsmasq's upstream queries. If your client uses per-app or policy routing instead, the guard will block them; check with `ip route get 1.1.1.1` while connected.

## Config reference (`/etc/vpngw.conf`)

| Key | Meaning |
|-----|---------|
| `LAN_IF` | Pi's ethernet interface, e.g. `eth0` |
| `LAN_CIDR` | LAN subnet, e.g. `192.168.1.0/24` |
| `VPN_IF` | tunnel interface, e.g. `xvpn-tun0` |
| `UPSTREAM_DNS` | space-separated resolvers dnsmasq forwards to |
| `KILL_SWITCH` | `yes` / `no` |
| `DNS_LEAK_GUARD` | block the Pi's own upstream DNS outside the tunnel |
| `BLOCK_IPV6` | `yes` / `no` |
| `BLOCK_IPS` | space-separated IPs/CIDRs denied entirely (use `vpngw block`) |
| `BYPASS_IPS` | space-separated IPs/CIDRs that skip the tunnel (use `vpngw bypass`) |
| `BLOCK_USERS` | local accounts whose outbound traffic is dropped (use `vpngw user-block`) |
| `SSH_PORT` | exempted from user blocks so live sessions survive |
| `DNS_CACHE_SIZE` | dnsmasq cache entries |
| `DNSMASQ_SERVICE` | systemd unit name for dnsmasq |

## Troubleshooting

**dnsmasq won't start** — something else owns port 53. On a Pi that's usually `systemd-resolved`:

```bash
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf && echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

**Clients have no internet** — `sudo vpngw status`. If the tunnel line is red, the VPN is down and the kill switch is doing its job; reconnect the VPN.

**Slow or stalled HTTPS on clients** — an MTU issue. MSS clamping is already on; if it persists, lower the tunnel MTU: `sudo ip link set xvpn-tun0 mtu 1400`.

**The Pi itself isn't going through the VPN** — that's your VPN client's routing, not this script. `vpngw` only handles forwarded traffic from other devices.

**Watch what's flowing** — `sudo watch -n1 iptables -vnL VPNGW_FWD` shows live packet counts per rule; a climbing DROP counter means traffic is being blocked.

**Something's stuck** — `sudo vpngw off` is always safe and fully reverses everything; it never touches rules it didn't create.

## Notes

- The Pi does not run DHCP, so nothing on your network changes until you manually repoint a device. If you'd rather push the Pi as gateway/DNS to everyone, do it from your access point's DHCP settings instead.
- Rules are not persisted to disk. Reboots start clean unless you ran `vpngw enable-boot`.
- Requires `iptables` (works with both legacy and nft backends via the `iptables` wrapper).

## Repo layout

```
vpngw               the CLI itself — everything lives in this one script
install.sh           installer: deps, /usr/local/sbin/vpngw, systemd unit, config
systemd/
  vpn-gateway.service
examples/
  vpngw.conf.example  fully-commented config reference
README.md
LICENSE
```

## Uninstall

```bash
sudo vpngw off
sudo systemctl disable vpn-gateway 2>/dev/null
sudo rm -f /usr/local/sbin/vpngw /etc/systemd/system/vpn-gateway.service \
           /etc/vpngw.conf /etc/dnsmasq.d/vpngw.conf
sudo systemctl daemon-reload
```

`dnsmasq` itself is left installed since other things may depend on it; remove it separately if you don't need it.

## Contributing

Issues and PRs welcome — this started as a single-Pi setup so edge cases from other network layouts (multiple LAN interfaces, non-systemd inits, nftables-only systems) are genuinely useful to hear about.

## License

MIT — see [LICENSE](LICENSE).
