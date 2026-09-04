#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"
load_env_file "${REPO_ROOT}"
require_env_vars ARTIFACT_IMAGE_REFS

for command_name in docker trivy jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done

read -r -a image_refs <<< "${ARTIFACT_IMAGE_REFS}"
if ((${#image_refs[@]} == 0)); then
  echo "ERROR: ARTIFACT_IMAGE_REFS does not contain any image references." >&2
  exit 1
fi

missing_images=()
for image_ref in "${image_refs[@]}"; do
  if ! docker image inspect "${image_ref}" >/dev/null 2>&1; then
    missing_images+=("${image_ref}")
  fi
done

if ((${#missing_images[@]} > 0)); then
  echo "ERROR: Configured images are missing from the host Docker image store:" >&2
  printf '  %s\n' "${missing_images[@]}" >&2
  echo "Run ./scripts/build-all.sh or ./scripts/load-artifacts.sh first." >&2
  exit 1
fi

output_dir="${REPO_ROOT}/artifacts/trivy-output"
mkdir -p "${output_dir}"
summary_file="${output_dir}/vulnerability-summary.tsv"
printf 'IMAGE\tUNKNOWN\tLOW\tMEDIUM\tHIGH\tCRITICAL\tTOTAL\n' > "${summary_file}"

for image_ref in "${image_refs[@]}"; do
  output_name="$(printf '%s' "${image_ref}" | sed 's/[^[:alnum:]._-]/_/g')"
  vulnerability_report="${output_dir}/${output_name}.vulnerabilities.json"
  sbom_report="${output_dir}/${output_name}.sbom.cdx.json"

  echo "Scanning ${image_ref}"
  trivy image \
    --image-src docker \
    --scanners vuln \
    --format json \
    --output "${vulnerability_report}" \
    "${image_ref}"

  echo "Generating SBOM for ${image_ref}"
  trivy image \
    --image-src docker \
    --scanners vuln \
    --format cyclonedx \
    --output "${sbom_report}" \
    "${image_ref}"

  jq -r '
    [.Results[]?.Vulnerabilities[]?] as $v
    | [
        .ArtifactName,
        ([$v[] | select(.Severity == "UNKNOWN")] | length),
        ([$v[] | select(.Severity == "LOW")] | length),
        ([$v[] | select(.Severity == "MEDIUM")] | length),
        ([$v[] | select(.Severity == "HIGH")] | length),
        ([$v[] | select(.Severity == "CRITICAL")] | length),
        ($v | length)
      ]
    | @tsv
  ' "${vulnerability_report}" >> "${summary_file}"
done

echo
echo "Trivy reports and SBOMs written to:"
echo "  ${output_dir}"
echo
column -t -s $'\t' "${summary_file}" 2>/dev/null || cat "${summary_file}"
