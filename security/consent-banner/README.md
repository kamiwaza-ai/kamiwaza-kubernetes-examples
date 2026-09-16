# Consent banner and pre-login consent gate

**Scenario:** enable the consent gate and classification banners on a Kamiwaza
Deploy Helmfile installation.

Tags: #security #compliance #kustomize #helm-values

## Compatibility

This example targets the Deploy `core-scheduler` workload in namespace
`kamiwaza`. It does not apply to the operator-managed `core-api` topology.

The operator API does not currently expose consent text or banner policy. Do not
patch an operator-managed Deployment to copy this procedure.

## Files

| File                       | Purpose                                                      |
| -------------------------- | ------------------------------------------------------------ |
| `kustomization.yaml`       | Builds `ConfigMap/consent-configmap` from the HTML fragment. |
| `consent.html`             | Contains the consent modal body.                             |
| `core-values-snippet.yaml` | Adds the mount and enables the Deploy chart settings.        |

## Prerequisites

- Use a current Kamiwaza Deploy checkout.
- Install the platform in namespace `kamiwaza`.
- Configure `kubectl` for the target cluster.
- Review the consent text with the responsible legal and security teams.

## Configure the consent text

Edit `consent.html`. Replace the sample contact and policy text with approved
content for the target organization.

The file is an HTML fragment. Do not add scripts, remote styles, remote fonts,
or third-party resources.

## Apply the ConfigMap

Apply the ConfigMap before the Helm release. When the ConfigMap is absent, the
scheduler Pod cannot start.

Run this command from the root of this examples repository:

```bash
kubectl apply -k security/consent-banner/
```

## Configure the Deploy release

Merge the `core:` block from `core-values-snippet.yaml` into
`deploy/cluster/values/overrides.yaml`. Site overrides load after environment
values, so they replace the default disabled settings.

Review these fields before deployment:

- `core.security.consent.enabled`
- `core.security.consent.buttonLabel`
- `core.security.banner.enabled`
- `core.security.banner.topText`
- `core.security.banner.topColor`
- `core.security.banner.bottomText`
- `core.security.banner.bottomColor`

Colors must use six-digit hexadecimal CSS form, such as `#007A33`.

Apply the selected Deploy environment with its normal Helmfile command. When
the EULA is required, accept it through the standard Deploy value.

## Verify the rendered contract

The scheduler Deployment must mount the ConfigMap key at
`/app/config/security/consent.html`. The Core ConfigMap must contain the enabled
flags and configured text.

```bash
kubectl -n kamiwaza get configmap consent-configmap \
  -o jsonpath='{.data.consent\.html}'

kubectl -n kamiwaza get deployment core-scheduler \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="core")].volumeMounts[?(@.name=="consent-html")].mountPath}{"\n"}'

kubectl -n kamiwaza get configmap core-config \
  -o jsonpath='{.data.KAMIWAZA_SECURITY_CONSENT_ENABLED}{"\n"}{.data.KAMIWAZA_SECURITY_BANNER_ENABLED}{"\n"}'

kubectl -n kamiwaza exec deployment/core-scheduler -c core -- \
  test -r /app/config/security/consent.html
```

Require both enabled flags to equal `true`. Require the mounted file command to
exit with status 0.

## Verify the user interface

Open the public platform URL in a new private browser session.

1. Verify that the top and bottom classification banners show the configured
   text and color.
2. Verify that the consent modal appears before the login form.
3. Verify that the button uses the configured label.
4. Accept the agreement and verify that login continues.
5. Start another private session and verify that the gate appears again.

A ConfigMap update does not refresh a `subPath` mount in an existing Pod. Restart
the scheduler after a consent text change:

```bash
kubectl -n kamiwaza rollout restart deployment/core-scheduler
kubectl -n kamiwaza rollout status deployment/core-scheduler --timeout=10m
```

Repeat the private-session user interface verification after the rollout.
