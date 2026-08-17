#!/usr/bin/env bash
# Reusable template: GitHub Actions OIDC -> Google Workload Identity Federation.
# Run in Google Cloud Shell while authenticated as an administrator of PROJECT_ID.
# Creates NO long-lived service-account key.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-visualismusic-publisher}"
PROJECT_NUMBER="${PROJECT_NUMBER:-223431871745}"
POOL_ID="${POOL_ID:-github-publisher}"
PROVIDER_ID="${PROVIDER_ID:-github}"

PUBLISHER_SA_ID="${PUBLISHER_SA_ID:-visualismusic-github-publisher}"
MEDIA_SA_ID="${MEDIA_SA_ID:-visualismusic-media-stager}"
PUBLISHER_SA_EMAIL="${PUBLISHER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
MEDIA_SA_EMAIL="${MEDIA_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Immutable GitHub repository IDs. Add future reusable-project repos deliberately.
REPO_ID_GMSS="${REPO_ID_GMSS:-1316260453}"
REPO_ID_MEDIA="${REPO_ID_MEDIA:-1336166378}"

printf 'Using project %s (%s)\n' "$PROJECT_ID" "$PROJECT_NUMBER"
gcloud config set project "$PROJECT_ID"

gcloud services enable \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  drive.googleapis.com

create_sa_if_missing() {
  local sa_id="$1"
  local sa_email="$2"
  local display_name="$3"
  if ! gcloud iam service-accounts describe "$sa_email" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$sa_id" --display-name="$display_name"
  fi
}

create_sa_if_missing "$PUBLISHER_SA_ID" "$PUBLISHER_SA_EMAIL" "VisualisMusic private publisher"
create_sa_if_missing "$MEDIA_SA_ID" "$MEDIA_SA_EMAIL" "VisualisMusic public media stager"

if ! gcloud iam workload-identity-pools describe "$POOL_ID" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --location=global \
    --display-name="GitHub publisher pool"
fi

MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner=assertion.repository_owner"
CONDITION="assertion.repository_id == '${REPO_ID_GMSS}' || assertion.repository_id == '${REPO_ID_MEDIA}'"

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location=global \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$MAPPING" \
    --attribute-condition="$CONDITION"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location=global \
    --display-name="GitHub Actions provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$MAPPING" \
    --attribute-condition="$CONDITION"
fi

POOL_NAME="$(gcloud iam workload-identity-pools describe "$POOL_ID" --location=global --format='value(name)')"

gcloud iam service-accounts add-iam-policy-binding "$PUBLISHER_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository_id/${REPO_ID_GMSS}"

gcloud iam service-accounts add-iam-policy-binding "$MEDIA_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository_id/${REPO_ID_MEDIA}"

PROVIDER_NAME="$(gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --workload-identity-pool="$POOL_ID" --location=global --format='value(name)')"

cat <<OUT

OIDC bootstrap created/updated.

Provider:
  ${PROVIDER_NAME}

Private publisher service account (GMSS private repo only):
  ${PUBLISHER_SA_EMAIL}

Public media-stager service account (visualismusic-media repo only):
  ${MEDIA_SA_EMAIL}

NEXT REQUIRED GOOGLE DRIVE SHARING (one-time):

PRIVATE PUBLISHER (${PUBLISHER_SA_EMAIL})
  1. VisualisMusic Publishing Calendar.csv   -> Viewer
  2. Rendered Videos root folder             -> Editor
  3. GMSS restricted secrets/ folder         -> Editor

PUBLIC MEDIA STAGER (${MEDIA_SA_EMAIL})
  1. VisualisMusic Publishing Calendar.csv   -> Viewer
  2. Rendered Videos/videos folder           -> Viewer

DO NOT share the secrets folder with the public media-stager identity.
DO NOT create a service-account key JSON.
OUT
