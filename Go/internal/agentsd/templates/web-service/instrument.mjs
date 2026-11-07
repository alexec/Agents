import * as Sentry from "@sentry/node";

// deploy.yml sets SENTRY_DSN from the repository variable of that name, and SENTRY_RELEASE to
// <service>@<version> from the tag, so that each error names the release that made it. With no
// DSN, the service sends nothing to Sentry.
if (process.env.SENTRY_DSN) {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    release: process.env.SENTRY_RELEASE,
    environment: process.env.SENTRY_ENVIRONMENT ?? "production",
  });
}
