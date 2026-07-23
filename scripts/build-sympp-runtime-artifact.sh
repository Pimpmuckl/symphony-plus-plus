#!/usr/bin/env bash
set -euo pipefail

revision="${SYMPP_SOURCE_REVISION:-}"
output_dir="artifacts/sympp-runtime"
platform=""
dry_run=0

usage() {
  cat <<'USAGE'
Builds the Symphony++ installed-runtime artifact for the current platform.

This is the installed artifact workflow: it compiles the Elixir backend release,
builds static dashboard assets, then emits a package plus manifest. Developer
source workflows such as `make -C elixir all`, `mix sympp.cockpit`, and the Vite
dev server remain separate and available.

Usage:
  scripts/build-sympp-runtime-artifact.sh [--revision <sha>] [--output-dir <dir>] [--platform <id>] [--dry-run]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision)
      revision="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
elixir_dir="$repo_root/elixir"
assets_dir="$elixir_dir/assets"

if [[ -z "${revision// }" ]] && command -v git >/dev/null 2>&1; then
  revision="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
fi

revision="$(printf '%s' "$revision" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Missing or invalid Symphony++ source revision. Set SYMPP_SOURCE_REVISION or run from a Git checkout." >&2
  exit 1
fi

plugin_manifest_path="$repo_root/plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"
[[ -f "$plugin_manifest_path" ]] || { echo "MCP plugin manifest is missing: $plugin_manifest_path" >&2; exit 1; }
plugin_name="$(grep -E '"name"[[:space:]]*:[[:space:]]*"[^"]+"' "$plugin_manifest_path" | head -n 1 | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
plugin_version="$(grep -E '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$plugin_manifest_path" | head -n 1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
if [[ -z "${plugin_name// }" || -z "${plugin_version// }" ]]; then
  echo "MCP plugin manifest must declare name and version." >&2
  exit 1
fi

if [[ -z "${platform// }" ]]; then
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux*) os="linux" ;;
    darwin*) os="macos" ;;
    msys*|mingw*|cygwin*) os="windows" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac
  platform="$os-$arch"
fi

case "$output_dir" in
  /*) output_root="$output_dir" ;;
  *) output_root="$repo_root/$output_dir" ;;
esac

package_base="sympp-runtime-$revision-$platform"
staging_dir="$output_root/$package_base-staging"
release_dir="$elixir_dir/_build/prod/rel/symphony_elixir"
source_static_dir="$elixir_dir/priv/static"
payload_manifest_path="$staging_dir/runtime-manifest.json"
archive_path="$output_root/$package_base.zip"
manifest_path="$output_root/$package_base.manifest.json"

[[ -d "$elixir_dir" ]] || { echo "Elixir project directory is missing: $elixir_dir" >&2; exit 1; }
[[ -f "$elixir_dir/mix.exs" ]] || { echo "Mix project is missing: $elixir_dir/mix.exs" >&2; exit 1; }
[[ -d "$assets_dir" ]] || { echo "Dashboard assets directory is missing: $assets_dir" >&2; exit 1; }

if [[ "$dry_run" -eq 1 ]]; then
  echo "Dry run: revision=$revision platform=$platform output=$output_root"
  exit 0
fi

command -v npm >/dev/null 2>&1 || { echo "Required command was not found on PATH: npm" >&2; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "Required command was not found on PATH: mix" >&2; exit 1; }
python_bin="$(command -v python3 || command -v python || true)"
[[ -n "$python_bin" ]] || { echo "Required command was not found on PATH: python3 or python" >&2; exit 1; }

(cd "$assets_dir" && npm ci && npm run build)
[[ -f "$source_static_dir/index.html" ]] || { echo "Dashboard static index is missing: $source_static_dir/index.html" >&2; exit 1; }
[[ -f "$source_static_dir/.vite/manifest.json" ]] || { echo "Dashboard Vite manifest is missing: $source_static_dir/.vite/manifest.json" >&2; exit 1; }

(cd "$elixir_dir" && MIX_ENV=prod SYMPP_SOURCE_REVISION="$revision" mix deps.get --only prod && MIX_ENV=prod SYMPP_SOURCE_REVISION="$revision" mix release symphony_elixir --overwrite)
[[ -d "$release_dir" ]] || { echo "Compiled backend release is missing: $release_dir" >&2; exit 1; }

release_app_dirs=()
for candidate in "$release_dir"/lib/symphony_elixir-*; do
  [[ -d "$candidate" ]] && release_app_dirs+=("$candidate")
done

if [[ "${#release_app_dirs[@]}" -ne 1 ]]; then
  echo "Expected exactly one symphony_elixir release lib directory under $release_dir/lib; found ${#release_app_dirs[@]}." >&2
  exit 1
fi

release_app_dir="${release_app_dirs[0]}"
[[ -f "$release_app_dir/priv/static/index.html" ]] || { echo "Release dashboard static index is missing." >&2; exit 1; }
[[ -f "$release_app_dir/priv/static/.vite/manifest.json" ]] || { echo "Release dashboard Vite manifest is missing." >&2; exit 1; }

dashboard_fingerprint="$("$python_bin" - "$source_static_dir" <<'PY'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
lines = []
for base, _dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        lines.append(f"{rel} {digest.hexdigest()}")
payload = "\n".join(sorted(lines)).encode("utf-8")
print(hashlib.sha256(payload).hexdigest())
PY
)"

mcp_contract_fingerprint="$("$python_bin" - "$repo_root/elixir/priv/symphony_plus_plus/mcp_contract.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    fingerprint = str(json.load(handle).get("mcp_contract_fingerprint", "")).strip().lower()
if not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
    raise SystemExit(f"Could not resolve MCP contract fingerprint from {sys.argv[1]}.")
print(fingerprint)
PY
)"

mkdir -p "$output_root"
rm -rf "$staging_dir" "$archive_path" "$manifest_path"
mkdir -p "$staging_dir"
cp -R "$release_dir" "$staging_dir/runtime"
cp -R "$source_static_dir" "$staging_dir/dashboard-static"
cat > "$staging_dir/start-runtime.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ack_flag="--i-understand-that-this-will-be-running-without-the-usual-guardrails"
workflow=""
logs_root=""
port=""
acknowledged=0

usage() {
  cat <<'USAGE'
Usage: start-runtime.sh --i-understand-that-this-will-be-running-without-the-usual-guardrails [--workflow <WORKFLOW.md>] --logs-root <dir> --port <port>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    "$ack_flag")
      acknowledged=1
      shift
      ;;
    --workflow)
      workflow="${2:-}"
      shift 2
      ;;
    --logs-root)
      logs_root="${2:-}"
      shift 2
      ;;
    --port)
      port="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$acknowledged" -eq 1 ]] || { echo "Missing required acknowledgement: $ack_flag" >&2; exit 2; }
[[ -z "${workflow// }" || -f "$workflow" ]] || { echo "Workflow file not found: $workflow" >&2; exit 1; }
[[ -n "${logs_root// }" ]] || { echo "--logs-root is required." >&2; exit 2; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a non-negative integer." >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_bin="$script_dir/runtime/bin/symphony_elixir"
chmod +x \
  "$runtime_bin" \
  "$script_dir"/runtime/bin/* \
  "$script_dir"/runtime/erts-*/bin/* \
  "$script_dir"/runtime/releases/*/elixir \
  2>/dev/null || true
release_tmp="$logs_root/release-tmp"
mkdir -p "$logs_root" "$release_tmp"
export SYMPP_RUNTIME_ARTIFACT=1
export SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED=1
if [[ -n "${workflow// }" ]]; then
  export SYMPP_WORKFLOW_FILE="$workflow"
else
  unset SYMPP_WORKFLOW_FILE
fi
export SYMPP_LOGS_ROOT="$logs_root"
export SYMPP_BACKEND_PORT="$port"
export RELEASE_TMP="$release_tmp"
export PHX_SERVER=true
exec "$runtime_bin" start
SH
chmod +x "$staging_dir/start-runtime.sh"
cat > "$staging_dir/start-runtime.ps1" <<'PS1'
[CmdletBinding()]
param(
  [string]$Workflow = "",
  [string]$LogsRoot = "",
  [int]$Port = -1,
  [switch]$IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
  @"
Usage: start-runtime.ps1 -IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails [-Workflow <WORKFLOW.md>] -LogsRoot <dir> -Port <port>
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if (-not $IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails) {
  throw "Missing required acknowledgement: -IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails"
}
if (-not [string]::IsNullOrWhiteSpace($Workflow) -and -not (Test-Path -LiteralPath $Workflow -PathType Leaf)) {
  throw "Workflow file not found: $Workflow"
}
if ([string]::IsNullOrWhiteSpace($LogsRoot)) {
  throw "-LogsRoot is required."
}
if ($Port -lt 0) {
  throw "-Port must be a non-negative integer."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$releaseTmp = Join-Path $LogsRoot "release-tmp"
New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $releaseTmp | Out-Null
$env:SYMPP_RUNTIME_ARTIFACT = "1"
$env:SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED = "1"
if (-not [string]::IsNullOrWhiteSpace($Workflow)) {
  $env:SYMPP_WORKFLOW_FILE = $Workflow
} else {
  Remove-Item Env:SYMPP_WORKFLOW_FILE -ErrorAction SilentlyContinue
}
$env:SYMPP_LOGS_ROOT = $LogsRoot
$env:SYMPP_BACKEND_PORT = [string]$Port
$env:RELEASE_TMP = $releaseTmp
$env:PHX_SERVER = "true"
& (Join-Path $scriptDir "runtime\bin\symphony_elixir.bat") start
exit $LASTEXITCODE
PS1

PYTHON_BIN="$python_bin" "$python_bin" - "$payload_manifest_path" "$revision" "$platform" "$dashboard_fingerprint" "$mcp_contract_fingerprint" "$plugin_name" "$plugin_version" <<'PY'
import datetime
import json
import sys

path, revision, platform, dashboard_fingerprint, mcp_contract_fingerprint, plugin_name, plugin_version = sys.argv[1:8]
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
payload = {
    "schema_version": 1,
    "plugin": {
        "marketplace": "symphony-plus-plus",
        "name": plugin_name,
        "version": plugin_version,
        "packages": ["symphony-plus-plus", "symphony-plus-plus-mcp"],
    },
    "source_revision": revision,
    "platform": platform,
    "built_at": now,
    "backend": {
        "kind": "mix_release",
        "name": "symphony_elixir",
        "relative_path": "runtime",
        "entrypoints": {
            "unix": "start-runtime.sh",
            "windows": "start-runtime.ps1",
        },
    },
    "dashboard": {
        "kind": "vite_static",
        "relative_path": "dashboard-static",
        "index": "dashboard-static/index.html",
        "vite_manifest": "dashboard-static/.vite/manifest.json",
        "fingerprint": dashboard_fingerprint,
    },
    "launcher_contract": {
        "manifest": "sympp-runtime-artifact",
        "version": 1,
        "mcp_contract_fingerprint": mcp_contract_fingerprint,
    },
}
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

PYTHON_BIN="$python_bin" "$python_bin" - "$archive_path" "$staging_dir" <<'PY'
import os
import stat
import sys
import zipfile

archive_path, staging_dir = sys.argv[1:3]
with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for base, dirs, files in os.walk(staging_dir):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(base, name)
            relative = os.path.relpath(path, staging_dir).replace(os.sep, "/")
            info = zipfile.ZipInfo.from_file(path, relative)
            mode = stat.S_IMODE(os.stat(path).st_mode)
            info.external_attr = mode << 16
            with open(path, "rb") as handle:
                archive.writestr(info, handle.read(), compress_type=zipfile.ZIP_DEFLATED)
PY

PYTHON_BIN="$python_bin" "$python_bin" - "$manifest_path" "$payload_manifest_path" "$archive_path" "$output_root" "$revision" "$platform" <<'PY'
import datetime
import hashlib
import json
import os
import sys

manifest_path, payload_manifest_path, archive_path, output_root, revision, platform = sys.argv[1:7]

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

with open(payload_manifest_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
manifest = {
    "schema_version": 1,
    "status": "built",
    "plugin": payload["plugin"],
    "source_revision": revision,
    "platform": platform,
    "created_at": now,
    "artifact": {
        "file": os.path.basename(archive_path),
        "relative_path": os.path.relpath(archive_path, output_root).replace(os.sep, "/"),
        "size_bytes": os.path.getsize(archive_path),
        "sha256": sha256(archive_path),
    },
    "payload_manifest": {
        "file": "runtime-manifest.json",
        "sha256": sha256(payload_manifest_path),
    },
    "backend": payload["backend"],
    "dashboard": payload["dashboard"],
    "launcher_contract": payload["launcher_contract"],
}
with open(manifest_path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

echo "Built $archive_path"
echo "Manifest $manifest_path"
