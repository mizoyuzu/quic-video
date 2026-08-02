# macOS Components

## Relay

Install the pinned `moq-relay` release, install `mkcert`, and run:

```bash
mac/relay/setup-cert.sh
mac/relay/start.sh
```

The relay listens on `[::]:4443`, uses the `delay` congestion controller, keeps
two seconds of cache, and allows anonymous access for the closed-LAN experiment.
It also serves HTTPS/WSS on TCP port 4443 for browser fallback and broadcast
discovery.
Do not forward port 4443 from the router. Restrict incoming access with the
macOS firewall.

## Bonjour advertiser

In another terminal, run:

```bash
mac/BonjourAdvertiser/start.sh \
  --name "$(scutil --get ComputerName)" \
  --port 4443 \
  --fingerprint "<sha256 fingerprint>"
```

The advertiser is deliberately separate from `moq-relay`: the relay has no
standard Bonjour advertisement in its current CLI. The iOS app searches for
`_quic-video._udp.` and reads the certificate fingerprint from TXT metadata.
