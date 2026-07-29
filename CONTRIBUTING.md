# Contributing to ThermoFan

Thank you for helping improve ThermoFan. Hardware-monitoring changes need more
evidence than a normal UI patch because an incorrect sensor mapping or fan
write can produce unsafe behavior on another Mac.

## Before You Start

- Search existing issues and discussions.
- Open an issue before a large behavioral or architecture change.
- Do not submit guessed SMC sensor names or writable keys.
- State the exact Mac model, chip, macOS version, and observed SMC data when a
  change is hardware-specific.
- Never include passwords, tokens, private keys, or unrelated diagnostic data.

## Local Setup

```sh
git clone https://github.com/girginomer10/thermofan-macos.git
cd thermofan-macos
swift test
./scripts/build_app.sh
```

Before opening a pull request, run:

```sh
swift test
bash -n scripts/build_app.sh
./scripts/build_app.sh
codesign --verify --deep --strict dist/ThermoFan.app
```

## Pull Requests

Keep changes focused and explain:

- what behavior changed;
- why the change is needed;
- how it was tested;
- which Mac models were tested;
- whether hardware writes were involved;
- how automatic-mode recovery was verified.

Add tests for curve math, persistence migrations, parsers, or other deterministic
logic. Hardware claims must be supported by sanitized diagnostics or a clear
manual test procedure.

## Safety Rules

- Keep all RPM values inside the minimum and maximum reported by the SMC.
- Verify target and mode writes before reporting success.
- Return the fan to automatic control when a write or verification step fails.
- Treat unknown models and unknown SMC data types as unsupported.
- Do not broaden the privileged helper command surface without a security
  review.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
