#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scan-images-trivy.sh [options]

Options:
  --image IMAGE          Docker image to scan. May be repeated.
  --images IMAGES        Whitespace-separated Docker image references.
  --output-dir DIR       Report directory. Defaults to artifacts/trivy-output.
  --ignore-policy FILE   Optional policy for a diagnostic scan.
  --no-ignore-policy     Run a raw scan without an ignore policy.
  --skip-file PATTERN    File/glob omitted from both reports. May be repeated.
  --skip-dir PATTERN     Directory/glob omitted from both reports. May be repeated.
  --cache-dir DIR        Use an explicit Trivy cache/database directory.
  --platform OS/ARCH     Select the image platform passed to Trivy.
  --skip-db-update       Use the vulnerability DB already present in the cache.
  --skip-java-db-update  Use the Java DB already present in the cache.
  --offline-scan         Disable Trivy dependency-identification API requests.
  --scan-label LABEL     Human-readable context stored in scan-metadata.json.
  -h, --help             Show help.

Image references must be supplied explicitly. The profile workflow supplies
its locked output image, platform, and frozen scanner settings.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

output_dir="${REPO_ROOT}/artifacts/trivy-output"
ignore_policy=""
custom_images=0
image_refs=()
skip_files=()
skip_dirs=()
cache_dir=""
scan_platform=""
skip_db_update=false
skip_java_db_update=false
offline_scan=false
scan_label=""

while (($# > 0)); do
  case "$1" in
    --image)
      if (($# < 2)); then
        echo "ERROR: --image requires a value." >&2
        usage >&2
        exit 1
      fi
      image_refs+=("$2")
      custom_images=1
      shift 2
      ;;
    --images)
      if (($# < 2)); then
        echo "ERROR: --images requires a value." >&2
        usage >&2
        exit 1
      fi
      read -r -a parsed_image_refs <<< "$2"
      image_refs+=("${parsed_image_refs[@]}")
      custom_images=1
      shift 2
      ;;
    --output-dir)
      if (($# < 2)); then
        echo "ERROR: --output-dir requires a value." >&2
        usage >&2
        exit 1
      fi
      output_dir="$2"
      shift 2
      ;;
    --ignore-policy)
      if (($# < 2)); then
        echo "ERROR: --ignore-policy requires a value." >&2
        usage >&2
        exit 1
      fi
      ignore_policy="$2"
      shift 2
      ;;
    --no-ignore-policy)
      ignore_policy=""
      shift
      ;;
    --skip-file|--skip-dir)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 1
      fi
      if [[ "$1" == --skip-file ]]; then
        skip_files+=("$2")
      else
        skip_dirs+=("$2")
      fi
      shift 2
      ;;
    --cache-dir|--platform|--scan-label)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 1
      fi
      option="$1"
      value="$2"
      case "${option}" in
        --cache-dir) cache_dir="${value}" ;;
        --platform) scan_platform="${value}" ;;
        --scan-label) scan_label="${value}" ;;
      esac
      shift 2
      ;;
    --skip-db-update)
      skip_db_update=true
      shift
      ;;
    --skip-java-db-update)
      skip_java_db_update=true
      shift
      ;;
    --offline-scan)
      offline_scan=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${output_dir}" != /* ]]; then
  output_dir="${REPO_ROOT}/${output_dir}"
fi

if [[ -n "${ignore_policy}" && "${ignore_policy}" != /* ]]; then
  ignore_policy="${REPO_ROOT}/${ignore_policy}"
fi

if [[ -n "${cache_dir}" && "${cache_dir}" != /* ]]; then
  cache_dir="${REPO_ROOT}/${cache_dir}"
fi

case "${scan_platform}" in
  ""|linux/amd64|linux/arm64) ;;
  *)
    echo "ERROR: Unsupported scan platform: ${scan_platform}" >&2
    echo "Supported values: linux/amd64, linux/arm64" >&2
    exit 1
    ;;
esac

for command_name in docker trivy jq python3 sha256sum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done

# Trivy reads TRIVY_* environment variables and a default trivy.yaml in the
# current directory in addition to command-line flags. A release/raw scan must
# not become narrower because a developer has ambient severity, ignore-status,
# ignore-unfixed, VEX, or output settings. Preserve unrelated Docker, proxy,
# and CA variables, but remove every Trivy-specific variable and explicitly
# select empty configuration and ignore files below.
while IFS= read -r variable_name; do
  if [[ "${variable_name}" == TRIVY_* ]]; then
    unset "${variable_name}"
  fi
done < <(compgen -e)

if ((${#image_refs[@]} == 0)); then
  if [[ "${custom_images}" -eq 0 ]]; then
    echo "ERROR: Supply at least one --image reference." >&2
  else
    echo "ERROR: No Docker images were selected for scanning." >&2
  fi
  exit 1
fi

if [[ -n "${ignore_policy}" && ! -f "${ignore_policy}" ]]; then
  echo "ERROR: Trivy ignore policy not found:" >&2
  echo "  ${ignore_policy}" >&2
  exit 1
fi

missing_images=()
platform_mismatches=()
image_identities_json='[]'
declare -A image_ids=()
declare -A output_name_owners=()
for image_ref in "${image_refs[@]}"; do
  if ! image_inspect_json="$(docker image inspect "${image_ref}" 2>/dev/null)"; then
    missing_images+=("${image_ref}")
    continue
  fi
  if ! image_id="$(jq -er \
      '.[0].Id | select(type == "string" and test("^sha256:[a-f0-9]{64}$"))' \
      <<< "${image_inspect_json}")" \
    || ! actual_platform="$(jq -er '.[0] | "\(.Os)/\(.Architecture)"' \
      <<< "${image_inspect_json}")"; then
    echo "ERROR: Docker returned invalid identity metadata for ${image_ref}." >&2
    exit 1
  fi
  image_ids["${image_ref}"]="${image_id}"
  image_identities_json="$(jq -c \
    --arg reference "${image_ref}" \
    --argjson inspected "${image_inspect_json}" '
      . + [($inspected[0] | {
        reference: $reference,
        imageId: .Id,
        platform: "\(.Os)/\(.Architecture)",
        created: (.Created // ""),
        sizeBytes: (.Size // null),
        repoDigests: (.RepoDigests // [])
      })]
    ' <<< "${image_identities_json}")"
  if [[ -n "${scan_platform}" && "${actual_platform}" != "${scan_platform}" ]]; then
    platform_mismatches+=("${image_ref}: expected ${scan_platform}, found ${actual_platform}")
  fi

  output_name="$(printf '%s' "${image_ref}" | sed 's/[^[:alnum:]._-]/_/g')"
  if [[ -n "${output_name_owners["${output_name}"]:-}" ]]; then
    echo "ERROR: Image references map to the same report filename:" >&2
    echo "  ${output_name_owners["${output_name}"]}" >&2
    echo "  ${image_ref}" >&2
    exit 1
  fi
  output_name_owners["${output_name}"]="${image_ref}"
done

if ((${#missing_images[@]} > 0)); then
  if [[ "${custom_images}" -eq 0 ]]; then
    echo "ERROR: Configured images are missing from the host Docker image store:" >&2
  else
    echo "ERROR: Requested images are missing from the host Docker image store:" >&2
  fi
  printf '  %s\n' "${missing_images[@]}" >&2
  if [[ "${custom_images}" -eq 0 ]]; then
    echo "Build or load the selected profile first." >&2
  else
    echo "Build or load the requested images first." >&2
  fi
  exit 1
fi

if ((${#platform_mismatches[@]} > 0)); then
  echo "ERROR: Requested images do not match the Trivy target platform:" >&2
  printf '  %s\n' "${platform_mismatches[@]}" >&2
  exit 1
fi

mkdir -p "${output_dir}"
if [[ -n "${cache_dir}" ]]; then
  mkdir -p "${cache_dir}"
fi
# Invalidate prior provenance before touching any report. A failed partial scan
# must not remain comparable under an older successful run's manifest.
rm -f "${output_dir}/scan-metadata.json" "${output_dir}/scan-metadata.json.tmp"
summary_file="${output_dir}/vulnerability-summary.tsv"
printf 'IMAGE\tUNKNOWN\tLOW\tMEDIUM\tHIGH\tCRITICAL\tTOTAL\n' > "${summary_file}"
vulnerability_reports=()
report_metadata=()
ignore_policy_args=()
if [[ -n "${ignore_policy}" ]]; then
  ignore_policy_args=(--ignore-policy "${ignore_policy}")
fi
skip_args=()
for pattern in "${skip_files[@]}"; do
  skip_args+=(--skip-files "${pattern}")
done
for pattern in "${skip_dirs[@]}"; do
  skip_args+=(--skip-dirs "${pattern}")
done
trivy_common_args=(
  --config /dev/null
  --image-src docker
  --scanners vuln
  --severity "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
  --ignore-unfixed=false
  --ignorefile /dev/null
  --skip-version-check
)
if [[ -n "${cache_dir}" ]]; then
  trivy_common_args+=(--cache-dir "${cache_dir}")
fi
if [[ -n "${scan_platform}" ]]; then
  trivy_common_args+=(--platform "${scan_platform}")
fi
if [[ "${skip_db_update}" == true ]]; then
  trivy_common_args+=(--skip-db-update)
fi
if [[ "${skip_java_db_update}" == true ]]; then
  trivy_common_args+=(--skip-java-db-update)
fi
if [[ "${offline_scan}" == true ]]; then
  trivy_common_args+=(--offline-scan)
fi

for image_ref in "${image_refs[@]}"; do
  output_name="$(printf '%s' "${image_ref}" | sed 's/[^[:alnum:]._-]/_/g')"
  vulnerability_report="${output_dir}/${output_name}.vulnerabilities.json"
  sbom_report="${output_dir}/${output_name}.sbom.cdx.json"
  vulnerability_reports+=("${vulnerability_report}")

  echo "Scanning ${image_ref}"
  trivy image \
    "${trivy_common_args[@]}" \
    "${ignore_policy_args[@]}" \
    "${skip_args[@]}" \
    --format json \
    --output "${vulnerability_report}" \
    "${image_ref}"

  current_image_id="$(docker image inspect --format '{{.Id}}' "${image_ref}")"
  if [[ "${current_image_id}" != "${image_ids["${image_ref}"]}" ]]; then
    echo "ERROR: Image tag changed while Trivy was scanning: ${image_ref}" >&2
    exit 1
  fi
  if ! jq -e --arg image "${image_ref}" --arg imageId "${current_image_id}" '
      .ArtifactName == $image
      and .Metadata.ImageID == $imageId
      and (.Results | type == "array")
      and all(.Results[]?;
        type == "object"
        and ((.Vulnerabilities // []) | type == "array"))
    ' "${vulnerability_report}" >/dev/null; then
    echo "ERROR: Trivy vulnerability report identity does not match ${image_ref}." >&2
    exit 1
  fi

  echo "Generating SBOM for ${image_ref}"
  trivy image \
    "${trivy_common_args[@]}" \
    "${ignore_policy_args[@]}" \
    "${skip_args[@]}" \
    --format cyclonedx \
    --output "${sbom_report}" \
    "${image_ref}"

  current_image_id="$(docker image inspect --format '{{.Id}}' "${image_ref}")"
  if [[ "${current_image_id}" != "${image_ids["${image_ref}"]}" ]]; then
    echo "ERROR: Image tag changed while Trivy was generating the SBOM: ${image_ref}" >&2
    exit 1
  fi
  if ! jq -e --arg image "${image_ref}" --arg imageId "${current_image_id}" '
      .bomFormat == "CycloneDX"
      and (.components | type == "array")
      and .metadata.component.name == $image
      and any(.metadata.component.properties[]?;
        .name == "aquasecurity:trivy:ImageID" and .value == $imageId)
    ' "${sbom_report}" >/dev/null; then
    echo "ERROR: Trivy SBOM identity does not match ${image_ref}." >&2
    exit 1
  fi

  vulnerability_sha256="$(sha256sum "${vulnerability_report}" | cut -d' ' -f1)"
  sbom_sha256="$(sha256sum "${sbom_report}" | cut -d' ' -f1)"
  report_metadata+=("${image_ref}|${output_name}.vulnerabilities.json|${output_name}.sbom.cdx.json|${vulnerability_sha256}|${sbom_sha256}")

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

python3 "${REPO_ROOT}/src/scan/summarize.py" \
  --output "${output_dir}/vulnerabilities.csv" \
  "${vulnerability_reports[@]}"

trivy_version_args=(version --config /dev/null --format json)
if [[ -n "${cache_dir}" ]]; then
  trivy_version_args+=(--cache-dir "${cache_dir}")
fi
if ! trivy_version_json="$(trivy "${trivy_version_args[@]}")" \
  || ! jq -e 'type == "object" and (.Version | type == "string")' \
    >/dev/null <<< "${trivy_version_json}"; then
  echo "ERROR: Unable to record Trivy/database version metadata." >&2
  exit 1
fi

images_json="$(jq -cn --args '$ARGS.positional' -- "${image_refs[@]}")"
skip_files_json="$(jq -cn --args '$ARGS.positional' -- "${skip_files[@]}")"
skip_dirs_json="$(jq -cn --args '$ARGS.positional' -- "${skip_dirs[@]}")"
reports_json="$(
  printf '%s\n' "${report_metadata[@]}" \
    | jq -Rsc '
        split("\n")[:-1]
        | map(split("|") | {
            image: .[0],
            vulnerabilities: .[1],
            sbom: .[2],
            vulnerabilitiesSha256: .[3],
            sbomSha256: .[4]
          })
      '
)"
ignore_policy_sha256=""
if [[ -n "${ignore_policy}" ]]; then
  ignore_policy_sha256="$(sha256sum "${ignore_policy}" | cut -d' ' -f1)"
fi
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
metadata_file="${output_dir}/scan-metadata.json"
jq -n \
  --arg generatedAt "${generated_at}" \
  --arg scanLabel "${scan_label}" \
  --argjson trivy "${trivy_version_json}" \
  --argjson images "${images_json}" \
  --argjson imageIdentities "${image_identities_json}" \
  --argjson reports "${reports_json}" \
  --arg platform "${scan_platform}" \
  --argjson offlineScan "${offline_scan}" \
  --argjson skipDbUpdate "${skip_db_update}" \
  --argjson skipJavaDbUpdate "${skip_java_db_update}" \
  --argjson skipFiles "${skip_files_json}" \
  --argjson skipDirs "${skip_dirs_json}" \
  --argjson ignoreApplied "$([[ -n "${ignore_policy}" ]] && echo true || echo false)" \
  --arg ignorePath "${ignore_policy}" \
  --arg ignoreSha256 "${ignore_policy_sha256}" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    "label": $scanLabel,
    trivy: $trivy,
    databaseIdentity: {
      vulnerability: (
        $trivy.VulnerabilityDB
        | if type == "object" then {
            version: .Version,
            updatedAt: .UpdatedAt
          } else null end
      ),
      java: (
        $trivy.JavaDB
        | if type == "object" then {
            version: .Version,
            updatedAt: .UpdatedAt
          } else null end
      )
    },
    scannerOptions: {
      configFile: "/dev/null",
      ambientTrivyEnvironmentCleared: true,
      imageSource: "docker",
      scanners: ["vuln"],
      severities: ["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"],
      ignoreUnfixed: false,
      ignoreFile: "/dev/null",
      platform: $platform,
      offlineScan: $offlineScan,
      skipDbUpdate: $skipDbUpdate,
      skipJavaDbUpdate: $skipJavaDbUpdate,
      skipFiles: $skipFiles,
      skipDirs: $skipDirs,
      ignorePolicy: {
        applied: $ignoreApplied,
        path: $ignorePath,
        sha256: $ignoreSha256
      }
    },
    images: $images,
    imageIdentities: $imageIdentities,
    reports: $reports
  }' > "${metadata_file}.tmp"
mv "${metadata_file}.tmp" "${metadata_file}"

echo
echo "Trivy reports, SBOMs, and vulnerability spreadsheet written to:"
echo "  ${output_dir}"
echo
column -t -s $'\t' "${summary_file}" 2>/dev/null || cat "${summary_file}"
