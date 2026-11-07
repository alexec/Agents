#!/usr/bin/env bash
# Sets up Google Cloud for __SERVICE__'s deploys from GitHub. Run it in Cloud Shell
# (https://shell.cloud.google.com), signed in as yourself:
#
#   bash setup-gcp.sh [PROJECT]
#
# It makes, or finds, each of these, so it is safe to run again:
#   - the project (__GCP_PROJECT__ unless you name another), linked to your billing account;
#   - the APIs that Cloud Run deploys from source need;
#   - the service account `deploy`, which may deploy to Cloud Run;
#   - Workload Identity Federation from the GitHub repository __GITHUB_REPO__ to it, so that the
#     deploy workflow signs in with no key.
#
# Then it prints the two repository variables that deploy.yml reads, GCP_WIF_PROVIDER and
# GCP_DEPLOY_SA. No key or secret leaves Google Cloud.
set -euo pipefail

project=${1:-__GCP_PROJECT__}
repo=__GITHUB_REPO__
pool=github
provider=github
account=deploy

say() { printf '%s\n' "$*" >&2; }

# A new service account takes a few seconds to show in IAM: try again for up to a minute.
retry() {
	local n
	for n in 1 2 3 4 5 6; do
		if "$@" >/dev/null; then return 0; fi
		[ "$n" = 6 ] && return 1
		sleep 10
	done
}

if ! gcloud projects describe "$project" >/dev/null 2>&1; then
	say "Making the project $project"
	if ! gcloud projects create "$project"; then
		say "Google Cloud did not make $project. A project id is unique to all of Google Cloud: name another, as in bash setup-gcp.sh my-app-1234"
		exit 1
	fi
fi
gcloud config set project "$project" >/dev/null
number=$(gcloud projects describe "$project" --format='value(projectNumber)')

billing=$(gcloud billing projects describe "$project" --format='value(billingEnabled)')
if [ "${billing,,}" != true ]; then
	billing_account=$(gcloud billing accounts list --filter=open=true --format='value(name)' --limit=1)
	if [ -z "$billing_account" ]; then
		say "You have no open billing account. Make one at https://console.cloud.google.com/billing, then run this again."
		exit 1
	fi
	say "Linking $project to the billing account $billing_account"
	gcloud billing projects link "$project" --billing-account="$billing_account" >/dev/null
fi

say "Turning on the APIs"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
	compute.googleapis.com iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

sa="$account@$project.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$sa" >/dev/null 2>&1; then
	say "Making the service account $sa"
	gcloud iam service-accounts create "$account" --display-name="Deploys from GitHub"
fi
for role in roles/run.admin roles/run.sourceDeveloper roles/iam.serviceAccountUser roles/serviceusage.serviceUsageConsumer; do
	retry gcloud projects add-iam-policy-binding "$project" --member="serviceAccount:$sa" \
		--role="$role" --condition=None --quiet
done
# A deploy from source builds as the Compute Engine default service account.
retry gcloud projects add-iam-policy-binding "$project" \
	--member="serviceAccount:$number-compute@developer.gserviceaccount.com" \
	--role=roles/run.builder --condition=None --quiet

if ! gcloud iam workload-identity-pools describe "$pool" --location=global >/dev/null 2>&1; then
	say "Making the workload identity pool $pool"
	gcloud iam workload-identity-pools create "$pool" --location=global --display-name="GitHub"
fi
if ! gcloud iam workload-identity-pools providers describe "$provider" --location=global \
	--workload-identity-pool="$pool" >/dev/null 2>&1; then
	say "Making the provider $provider, for $repo only"
	gcloud iam workload-identity-pools providers create-oidc "$provider" --location=global \
		--workload-identity-pool="$pool" --display-name="GitHub" \
		--issuer-uri=https://token.actions.githubusercontent.com \
		--attribute-mapping=google.subject=assertion.sub,attribute.repository=assertion.repository \
		--attribute-condition="assertion.repository == '$repo'"
fi
retry gcloud iam service-accounts add-iam-policy-binding "$sa" --role=roles/iam.workloadIdentityUser \
	--member="principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$pool/attribute.repository/$repo" \
	--quiet

say "Done. Put these in the repository's variables (Settings ▸ Secrets and variables ▸ Actions ▸ Variables):"
echo "GCP_WIF_PROVIDER=projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider"
echo "GCP_DEPLOY_SA=$sa"
