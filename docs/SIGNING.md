# Release signing

CI signs the release APK with a fixed upload key kept in the repository
secrets. Every release APK then carries the same signature and installs over
the previous one. Local release builds without `android/key.properties` fall
back to the debug key.

## Create the key (once, on the VPS)

Requires `keytool` from a JDK or JRE (Debian/Ubuntu:
`sudo apt-get install -y openjdk-17-jre-headless`).

```sh
# Private working directory: files created here are readable only by you.
umask 077
mkdir -p ~/ssh-app-signing && cd ~/ssh-app-signing

# A random password. Hex is safe in the shell, in YAML and in key.properties.
openssl rand -hex 24 | tr -d '\n' > keystore-password.txt

# The keystore: RSA 4096, valid 10000 days, alias "upload". PKCS12 keystores
# use one password for the store and the key, so both read the same file.
# The password never appears on the command line or in the shell history.
keytool -genkeypair -v \
  -keystore upload-keystore.jks -storetype PKCS12 \
  -alias upload -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass:file keystore-password.txt \
  -keypass:file keystore-password.txt \
  -dname "CN=SSH App, O=Personal, C=US"

# Check it, and note the SHA-256 fingerprint. CI prints the same one.
keytool -list -v -keystore upload-keystore.jks \
  -storepass:file keystore-password.txt | grep -E 'Alias name|SHA256|Valid'

# One-line base64 copy for the secret.
base64 -w0 upload-keystore.jks > upload-keystore.jks.base64
```

Change the `-dname` values if you like; they are only shown in the
certificate.

## Add the four repository secrets

In GitHub: **Settings → Secrets and variables → Actions → New repository
secret**.

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | contents of `upload-keystore.jks.base64` |
| `KEYSTORE_PASSWORD` | contents of `keystore-password.txt` |
| `KEY_ALIAS` | `upload` |
| `KEY_PASSWORD` | contents of `keystore-password.txt` (same as above) |

Or, with the GitHub CLI on the VPS:

```sh
gh secret set KEYSTORE_BASE64   --repo mohamedwithai/terminal < upload-keystore.jks.base64
gh secret set KEYSTORE_PASSWORD --repo mohamedwithai/terminal < keystore-password.txt
gh secret set KEY_ALIAS         --repo mohamedwithai/terminal --body upload
gh secret set KEY_PASSWORD      --repo mohamedwithai/terminal < keystore-password.txt
```

## Afterwards

```sh
rm ~/ssh-app-signing/upload-keystore.jks.base64
```

Back up `upload-keystore.jks` and `keystore-password.txt` somewhere safe
(a password manager, or offline). Without them, a new key means installed
copies of the app can no longer be updated in place; they have to be
uninstalled first.

Never commit any of these files. The root `.gitignore` excludes `*.jks`,
`*.jks.base64`, `*.keystore`, `key.properties` and `keystore-password.txt`.

## How CI uses it

`.github/workflows/android-apk.yml` decodes `KEYSTORE_BASE64` into the
runner's temp directory and writes `android/key.properties`, which
`android/app/build.gradle.kts` reads. The build fails if a secret is missing
or if the release APK still has the debug signature. The run prints the
certificate's SHA-256 so you can compare it with the `keytool -list` output.
Both files are deleted at the end of the job.
