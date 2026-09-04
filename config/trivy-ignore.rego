package trivy

# These packages primarily provide development headers and static build files;
# they do not replace the host kernel or the image's libc6 runtime package.
# Suppress their findings while retaining their SBOM components.
default ignore = false

ignore {
  input.Type == "vulnerability"
  input.PkgName == "linux-libc-dev"
}

ignore {
  input.Type == "vulnerability"
  input.PkgName == "libc6-dev"
}
