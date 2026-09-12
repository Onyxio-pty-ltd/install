# Organization artifact storage: installer impact

Inspected on 2026-09-10 against the **current local platform working tree**, including uncommitted changes. This does not establish that a published server image already contains these changes.

## Result

No installer runtime change is required for the organization directory layout. The installer already mounts the entire host `data/uploads` directory at `/app/backend/uploads`, and the platform still runs in `/app/backend`. Organization directories are descendants of that same mount and are created by the application. See [installer mount](/Users/puyan/projects/onyxio/install/install.sh:501), [upgrade mount](/Users/puyan/projects/onyxio/install/upgrade.sh:412), [web installer mount](/Users/puyan/projects/onyxio/install/index.html:501), and [image working directory](/Users/puyan/projects/onyxio/platform/backend/deploy/Dockerfile:47).

## Storage contract

The platform previously stored media, profile backgrounds, and HLS directly under `uploads/{artifact-type}`; customer clones used `uploads/philips-clones/{deviceId}/{sessionId}` or shared source folders. Current customer storage is:

```text
data/uploads/orgs/{organizationId}/
  media-assets/
  profile-backgrounds/
  hls-assets/{assetId}/
  logos/
  clones/default/
  clones/{deviceId}/{sessionId}/
  clones/packages/{cloneId}/
```

The root is derived from `process.cwd()`, with no new storage-root environment variable. Organization IDs and other identifiers are encoded as path segments. See [upload paths](/Users/puyan/projects/onyxio/platform/backend/src/uploads/storage.ts:3) and [clone paths](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/storage.ts:13).

The application recursively creates upload, logo, HLS, and organization clone directories. The installer does not need to know organization IDs or precreate their directories. Existing write access to the uploads mount remains necessary; these helpers do not introduce a separate ownership or permissions scheme. See [media and HLS creation](/Users/puyan/projects/onyxio/platform/backend/src/graphql/resolvers/Mutation.ts:900), [logo creation](/Users/puyan/projects/onyxio/platform/backend/src/uploads/logos.ts:30), and [clone provisioning](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/organizationClones.ts:32).

The installation template stays at `data/uploads/philips-clones/sources/default`, or the profile chosen by `PHILIPS_CLONE_SOURCE_PROFILE`. Keep that setting installation-wide. Each new organization receives independent copied files. App release bundles also remain deployment-wide under their existing uploads roots. See [template preparation](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/defaultSource.ts:36), [template copy](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/organizationClones.ts:33), and [managed app roots](/Users/puyan/projects/onyxio/platform/backend/src/apps/managedStaticApp.ts:158).

## Routing and installation flow

Public playback URLs become `/uploads/orgs/{organizationId}/{artifact-type}/...`. The backend permits only media, backgrounds, HLS, and logos through this static route; clone transfers use `/philips/clones/...`, including metadata-resolved `/files/{cloneId}/...` downloads. Installer nginx already proxies the entire URI to the backend, so no route rewrite is needed. See [upload routing](/Users/puyan/projects/onyxio/platform/backend/src/uploads/index.ts:6), [clone routes](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/routes.ts:827), and [installer proxy](/Users/puyan/projects/onyxio/install/install.sh:547).

The image contains clone seed files and the TV bundles, and startup prepares the installation template before serving requests. Organization creation then copies the template. If template preparation fails, startup logs a warning, while organization provisioning rejects an empty template. A fresh-install smoke test should therefore include organization creation and verify its default clone, in addition to HTTP health. See [image contents](/Users/puyan/projects/onyxio/platform/backend/deploy/Dockerfile:62), [startup order](/Users/puyan/projects/onyxio/platform/backend/src/index.ts:91), [startup error handling](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/defaultSource.ts:341), and [empty-template validation](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/organizationClones.ts:61).

## Release and data considerations

- The accompanying platform change switches the image startup command to `yarn prisma:migrate:deploy && yarn start`. The image copies the Prisma migrations, including the initial schema and partial unique index for one default clone per organization. Fresh installs must use an image built from this complete change. This is handled by platform image packaging, not an additional installer command. See [Docker startup](/Users/puyan/projects/onyxio/platform/backend/deploy/Dockerfile:85), [migration packaging](/Users/puyan/projects/onyxio/platform/backend/deploy/Dockerfile:57), and [default-clone constraint](/Users/puyan/projects/onyxio/platform/backend/prisma/migrations/20260910000000_init/migration.sql:782).
- Preserving files during upgrade does not convert their stored URLs or old schema. The platform explicitly targets fresh current-schema installations and excludes historical data migrations. Treat old local development installations separately; do not advertise an automatic old-layout upgrade or add installer backfills. See [compatibility policy](/Users/puyan/projects/onyxio/platform/AGENTS.md:66) and [organization upload contract](/Users/puyan/projects/onyxio/platform/backend/docs/organization-uploads.md:31).
- Upgrade's built-in backup is a PostgreSQL dump only. A complete backup must include all of `data/uploads`, covering both organization files and installation-wide templates/app bundles, together with the database. The path change does not create this limitation, but it should be clear in backup documentation. See [database backup](/Users/puyan/projects/onyxio/install/upgrade.sh:790). Uninstall already either preserves the whole installation directory with `--keep-data` or removes it, so no new deletion paths are needed: [uninstall behavior](/Users/puyan/projects/onyxio/install/uninstall.sh:262).

## Scope of verification

This is a source-level contract comparison; no server image was built or deployed. A useful release smoke test is: fresh install → create two organizations → upload matching media filenames and logos → verify separate persisted files and playback URLs → verify independent default clones → restart/upgrade the container and verify persistence. There is also a platform-only discrepancy to resolve separately: current clone transfer code still contains an old physical-folder fallback, despite the new docs stating there are no historical-layout readers. This does not require an installer change; see [capture download fallback](/Users/puyan/projects/onyxio/platform/backend/src/philips/clone/routes.ts:304).
