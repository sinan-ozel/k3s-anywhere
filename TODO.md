# TODO

## Fix `config` input path inconsistency in cluster.yaml

The `config` and `provider_config` inputs behave differently:

- `config`: code does `"configs/${{ inputs.config }}.env"` — prepends `configs/`
- `provider_config`: code does `"${{ inputs.provider_config }}.env"` — no prefix

But the description for `config` shows `e.g. configs/my-cluster`, implying the
caller passes the full path. This causes `config: configs/sandbox` to resolve to
`configs/configs/sandbox.env` (double prefix).

Fix: either update the description example to `e.g. sandbox` (code is correct),
or remove the `configs/` prefix from the code (description is correct). The
`provider_config` pattern (caller passes full path) is more flexible and
consistent with how callers think about it — prefer that approach, i.e. remove
the hardcoded `configs/` prefix and update the description to say
`e.g. configs/my-cluster`. Apply the same fix to the `Validate inputs` step.

## Update Quick Start to pin workflow ref and image at first release

The Quick Start and GitHub Actions examples in README.md currently use `@main`
and `sinanozel/k3s-anywhere:latest`. Once `v0.1.0` is tagged these should
become `@v0.1.0` and `image: sinanozel/k3s-anywhere:0.1.0`. This is covered
by the release checklist in CLAUDE.md and will be handled automatically when
cutting the first release.

## Remove AWS_REGION from setup.sh secrets output

`scripts/aws/setup.sh` currently prints `AWS_REGION` in the "Add the following
to GitHub Secrets" block. This is wrong. `AWS_REGION` is the region used to
create the Pulumi state bucket during setup — it belongs in the provider config
file (`configs/aws/<name>-<region>.env`), not in GitHub Secrets. The cluster
workflow already reads it from `provider_config`, not from secrets. Printing it
in the secrets list misleads operators into adding a redundant (and potentially
conflicting) secret.

Fix: remove the `AWS_REGION` line from the secrets summary block in
`scripts/aws/setup.sh` (and the matching block in the local `.env.secrets`
section). Add a note that `AWS_REGION` goes in the provider config file instead.

## Generate a memorable passphrase for PULUMI_CONFIG_PASSPHRASE

Instead of printing a placeholder that the operator must replace, `setup.sh`
should generate a strong passphrase automatically and include it in the output
as a real value. Memorable passphrases (diceware-style: 4–5 random words
separated by dashes or spaces) are both strong enough for Pulumi state
encryption and easy to copy into a password manager or remember in the short
term.

Python is already in the container. Add `wamerican` to the Dockerfile's
`apt-get install` list so `/usr/share/dict/words` is available, then generate
with:

```bash
python3 -c "
import secrets, re
w = [x for x in re.findall(r'\b[a-z]{4,7}\b', open('/usr/share/dict/words').read())]
print('-'.join(secrets.choice(w) for _ in range(4)))
"
```

This produces output like `coral-brisk-haven-funky`. The generated passphrase
should appear as a ready-to-use `KEY=VALUE` line in both output blocks so the
operator only needs to copy it, not invent it.

If `PULUMI_CONFIG_PASSPHRASE` is already set in the environment when setup runs,
skip generation and use the existing value (idempotent reruns keep the same
passphrase).

## Make setup.sh output directly copy-pasteable

The "Add to your local .env.secrets" block currently has two problems:

1. Lines are indented with two leading spaces, so pasting into a `.env` file
   produces broken `  KEY=VALUE` entries.
2. `PULUMI_CONFIG_PASSPHRASE=<same passphrase>` is a placeholder, not a value
   (resolved once passphrase generation is implemented above).

Fix: print the `.env.secrets` block with no leading whitespace and delimit it
clearly so the operator can select and paste the whole block verbatim:

```
=== Copy into .env.secrets ===
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
STATE_BUCKET_NAME=k3s-anywhere-state-...
PULUMI_CONFIG_PASSPHRASE=word1-word2-word3-word4
==============================
```

Apply the same fix to `scripts/exoscale/setup.sh`.
