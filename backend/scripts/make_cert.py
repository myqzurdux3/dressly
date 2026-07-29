#!/usr/bin/env python3
"""Generate a self-signed TLS certificate and print its pin.

Why a pin and not just a certificate: a self-signed certificate is not trusted
by anything, so a client has two options. It can disable verification, which is
worse than plain HTTP because it looks secure while accepting any certificate an
attacker presents. Or it can *pin* — accept exactly this certificate and nothing
else. Pinning is genuinely strong: the connection cannot be intercepted even by
someone holding a certificate from a real authority.

So this prints the SHA-256 fingerprint, which goes into the Flutter app.

    python scripts/make_cert.py --host 203.0.113.10 --host dressly.example.com

Certificates are written to backend/certs/ (gitignored). Re-running replaces
them, which invalidates the old pin — update the app at the same time.

Once a domain name is in place, prefer a real certificate from Let's Encrypt
behind Caddy or nginx: no pin to maintain, and it works in a browser too.
"""
import argparse
import datetime
import ipaddress
import subprocess
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
CERT_DIR = BACKEND / "certs"


def _local_addresses() -> list[str]:
    """Every address this machine answers on, so the default cert just works."""
    out = {"127.0.0.1", "localhost"}
    try:
        res = subprocess.run(["hostname", "-I"], capture_output=True, text=True,
                             timeout=5)
        out.update(a for a in res.stdout.split() if a)
    except Exception:
        pass
    return sorted(out)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", action="append", default=[],
                    help="IP or hostname clients will connect to; repeatable. "
                         "Defaults to this machine's addresses.")
    ap.add_argument("--days", type=int, default=825,
                    help="validity in days (default 825, the max browsers accept)")
    ap.add_argument("--force", action="store_true",
                    help="overwrite an existing certificate")
    args = ap.parse_args()

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    hosts = args.host or _local_addresses()
    CERT_DIR.mkdir(parents=True, exist_ok=True)
    key_path, crt_path = CERT_DIR / "server.key", CERT_DIR / "server.crt"
    if crt_path.exists() and not args.force:
        print(f"{crt_path} already exists. Pass --force to replace it "
              f"(this invalidates the pin currently in the app).")
        return 1

    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)

    san = []
    for h in hosts:
        try:
            san.append(x509.IPAddress(ipaddress.ip_address(h)))
        except ValueError:
            san.append(x509.DNSName(h))

    now = datetime.datetime.now(datetime.timezone.utc)
    subject = x509.Name([
        x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, hosts[0]),
        x509.NameAttribute(x509.oid.NameOID.ORGANIZATION_NAME, "Dressly"),
    ])
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)                      # self-signed: issuer == subject
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=args.days))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None),
                       critical=True)
        .sign(key, hashes.SHA256())
    )

    key_path.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ))
    key_path.chmod(0o600)          # the private key must not be world-readable
    crt_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))

    fingerprint = cert.fingerprint(hashes.SHA256()).hex()
    pretty = ":".join(fingerprint[i:i + 2].upper()
                      for i in range(0, len(fingerprint), 2))

    print(f"key  : {key_path}")
    print(f"cert : {crt_path}")
    print(f"valid for: {', '.join(hosts)}")
    print(f"expires  : {(now + datetime.timedelta(days=args.days)).date()}")
    print()
    print("SHA-256 pin (put this in clothesapp/lib/config/api_config.dart):")
    print(f"  {fingerprint}")
    print(f"  {pretty}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
