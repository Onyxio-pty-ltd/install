# Tools domain migration

The canonical script host is `tools.onyxio.app`, replacing
`install.onyxio.com.au`. The GitHub repository can keep its `install` name;
it does not need to match the public hostname.

## Published endpoints

| Operation | Path |
| --- | --- |
| Install platform | `/` or `/install.sh` |
| Install management console | `/ops-install.sh` |
| Update platform image or upgrade to a selected version | `/upgrade.sh` |
| Uninstall platform or management | `/uninstall.sh` |
| Install or update casting host | `/install-casting-host.sh` |

There is no separate `/update.sh`. The upgrade script pulls the requested image
even when its tag matches the installed tag. Use `ONYXIO_VERSION` to choose a
release; the default is `latest`. Existing installation-directory and other
options still apply to each script.

## GitHub Pages and DNS

1. Publish this repository's changes to `main`, the Pages source branch.
   The root `CNAME` file must contain only `tools.onyxio.app`. Confirm the custom
   domain in **Settings > Pages** also reads `tools.onyxio.app`.
2. In the Cloudflare DNS zone for `onyxio.app`, create:

   | Type | Name | Target | Proxy |
   | --- | --- | --- | --- |
   | CNAME | `tools` | `onyxio-pty-ltd.github.io` | DNS only |

   The target must not include `/install` or a URL scheme.
3. Wait for DNS validation and GitHub's HTTPS certificate, then enable
   **Enforce HTTPS** in Pages. Certificate provisioning can take up to 24 hours.
4. Download and inspect the endpoints before executing any installation:

   ```bash
   dig tools.onyxio.app CNAME +short
   curl -fsSL https://tools.onyxio.app/install.sh -o /tmp/onyxio-install.sh
   bash -n /tmp/onyxio-install.sh
   curl -fsSL https://tools.onyxio.app/upgrade.sh -o /tmp/onyxio-upgrade.sh
   bash -n /tmp/onyxio-upgrade.sh
   ```

See [GitHub's custom-domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site).

## Existing servers and old links

Already installed helpers can contain the old hostname. Changing this repository
does not rewrite files on those servers. Keep the old hostname working with an
HTTPS redirect at Cloudflare or another redirect service:

```text
https://install.onyxio.com.au/<path>?<query>
  -> https://tools.onyxio.app/<path>?<query>
```

Preserve the path and query string, and keep a valid certificate for the old
hostname. A DNS CNAME alone does not provide an HTTP redirect. A Cloudflare
redirect requires a proxied DNS record for the old hostname and an edge redirect
rule. Verify the new endpoints before enabling the redirect, and check that old
root, upgrade, uninstall, and casting-host URLs return the corresponding scripts.

Normal platform upgrades refresh the installed upgrade/uninstall wrappers to
the new domain unless `ONYXIO_SKIP_HOST_REFRESH=true`. Existing management
uninstall wrappers and previously built deployment bundles can still use the old
domain, so retain the redirect for those installations. Explicit
`ONYXIO_INSTALL_BASE_URL` overrides continue to work for supporting downloads.

The sibling Platform repository also has legacy copies under
`backend/deploy/installer-site/`; migrate their URLs before using them to publish
or build new artifacts.
