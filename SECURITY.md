# Security policy

## Supported versions

Only the latest release is supported; fixes ship as a new release.

## Scope

InkStats has an optional **privileged helper**, a launch daemon that runs as root to read
power figures and set fan speeds. It is the most sensitive part:

- The app and the helper talk over XPC, and each side checks the other's code signature
  (same team, exact identifier) before trusting it.
- The helper resets fans to automatic when a client disconnects and above 95 °C.

The only network use is the optional weather forecast from Open-Meteo, off until you turn it
on. Reports about the helper accepting other clients, or anything leaving the Mac otherwise,
are especially welcome.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately instead:
on GitHub, open the **Security** tab of this repository and choose **Report a vulnerability**.

Please include as much as you can:

- the affected version or commit
- your macOS version and Mac model
- steps to reproduce, or a proof of concept
- what an attacker could do with it
- any ideas for a fix

## Response

- New reports are acknowledged within 72 hours.
- A first assessment follows within 7 days.
- Once a fix is out, we agree on a disclosure timeline with the reporter.
