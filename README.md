# socks5-vpn

Small Linux scripts for routing traffic through SSH-based tunnels.

This repository contains two approaches:

- `socks-route.sh`: route traffic through a local SSH SOCKS5 proxy using `hev-socks5-tunnel`
- `ssh-w-route.sh`: create a point-to-point TUN tunnel using `ssh -w`

## Why two scripts

`ssh -D` is convenient, but it is not a full VPN:

- TCP works
- ICMP does not work
- UDP is limited
- DNS often needs extra handling

`ssh -w` behaves more like a real VPN because it forwards IP traffic through a TUN interface.

## Files

- `socks-route.sh`: SOCKS5-based routing helper
- `ssh-w-route.sh`: `ssh -w` routing helper

## Requirements

Local machine:

- Linux
- `bash`
- `iproute2`
- `ssh`
- root privileges for route and TUN changes

For `socks-route.sh`:

- a running local SSH SOCKS proxy, for example `ssh -N -D 127.0.0.1:1080 user@server`
- `hev-socks5-tunnel` installed locally, or permission to let the script install it

For `ssh-w-route.sh`:

- remote SSH server reachable over IPv4
- remote `sshd` with `PermitTunnel yes`
- remote user with `root` access or passwordless `sudo`
- remote NAT/firewall tools such as `iptables`

## Quick Start

### SOCKS5 mode

Start a SOCKS proxy:

```bash
ssh -N -D 127.0.0.1:1080 user@203.0.113.10
```

Enable routing:

```bash
sudo ./socks-route.sh up --remote 203.0.113.10 --dns 1.1.1.1
```

Check state:

```bash
sudo ./socks-route.sh status
```

Disable routing:

```bash
sudo ./socks-route.sh down
```

### `ssh -w` mode

Enable routing:

```bash
sudo ./ssh-w-route.sh up \
  --remote 203.0.113.10 \
  --remote-out-if eth0 \
  --dns 8.8.8.8
```

Check state:

```bash
sudo ./ssh-w-route.sh status
```

Disable routing:

```bash
sudo ./ssh-w-route.sh down
```

## Notes

### SOCKS5 mode caveats

- `ssh -D` is not a full VPN
- `ping` is not a valid test
- DNS over UDP may fail through OpenSSH dynamic forwarding
- if hostname resolution fails, test with direct IPs first

### `ssh -w` mode caveats

- the remote server must permit tunnel devices
- the remote server must allow forwarding/NAT for tunnel traffic
- the local machine must keep a direct route to the SSH server public IP

## Testing

Useful checks:

```bash
ip rule
ip route
curl -4 https://api.ipify.org
ssh root@server 'ip addr show'
```

For SOCKS mode, prefer TCP-based checks instead of `ping`.

## Safety

These scripts modify:

- default routes
- policy routing rules
- `/etc/resolv.conf`
- remote SSH configuration for `PermitTunnel yes`
- remote IPv4 forwarding and iptables rules

Review the scripts before using them on production systems.

## License

MIT
