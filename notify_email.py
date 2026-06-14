#!/usr/bin/env python3
"""
Send an alert email via Resend (default) or SendGrid (fallback). Stdlib only —
no pip install needed, so it runs even when the bot's RL deps are absent.

Usage:
    python notify_email.py "<subject>" "<body text>"

Env:
    RESEND_API_KEY     Resend API key (preferred)
    SENDGRID_API_KEY   SendGrid API key (used if RESEND_API_KEY is absent)
    ALERT_EMAIL_TO     recipient address (required)
    ALERT_EMAIL_FROM   sender (default: onboarding@resend.dev — Resend's test
                       sender, which delivers to the Resend account owner)

Always exits 0 — a notification failure must never fail a trading cycle.
"""
import json, os, sys, urllib.request, urllib.error


def main() -> int:
    subject = sys.argv[1] if len(sys.argv) > 1 else "BTC Bot"
    body    = sys.argv[2] if len(sys.argv) > 2 else ""

    to     = os.getenv("ALERT_EMAIL_TO", "").strip()
    frm    = os.getenv("ALERT_EMAIL_FROM", "onboarding@resend.dev").strip()
    resend = os.getenv("RESEND_API_KEY", "").strip()
    sg     = os.getenv("SENDGRID_API_KEY", "").strip()

    if not to:
        print("notify_email: ALERT_EMAIL_TO not set — skipping")
        return 0

    if resend:
        url = "https://api.resend.com/emails"
        payload = {"from": frm, "to": [to], "subject": subject, "text": body}
        key = resend
    elif sg:
        url = "https://api.sendgrid.com/v3/mail/send"
        payload = {
            "personalizations": [{"to": [{"email": to}]}],
            "from": {"email": frm},
            "subject": subject,
            "content": [{"type": "text/plain", "value": body}],
        }
        key = sg
    else:
        print("notify_email: no RESEND_API_KEY / SENDGRID_API_KEY — skipping")
        return 0

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            print(f"notify_email: sent (HTTP {r.status})")
    except urllib.error.HTTPError as e:
        print(f"notify_email: HTTP {e.code} — {e.read().decode('utf-8', 'replace')[:300]}")
    except Exception as e:  # noqa: BLE001
        print(f"notify_email: error — {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
