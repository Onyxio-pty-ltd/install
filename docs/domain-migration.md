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

`tools.onyxio.app` fully replaces the old hostname. No legacy DNS record or
redirect is maintained.

Already installed helpers can still contain the old hostname. Changing this
repository does not rewrite files on those servers. Use the new public URLs
for future operations and replace the old hostname in any saved commands or
installed lifecycle wrappers before using them. Normal platform upgrades from
the new URL refresh the installed upgrade/uninstall wrappers unless
`ONYXIO_SKIP_HOST_REFRESH=true`. Management uninstall wrappers need their URL
updated separately. Rebuild older deployment bundles before reusing them.

Explicit `ONYXIO_INSTALL_BASE_URL` overrides continue to work for supporting
downloads; update any override that still points to the retired hostname.

The sibling Platform repository also has legacy copies under
`backend/deploy/installer-site/`; migrate their URLs before using them to publish
or build new artifacts.
