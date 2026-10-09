#!/usr/bin/env bash
# Fork-only validation script for microsoft/aspire#15904.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOTNET="$REPO_ROOT/dotnet.sh"
CLI_PROJECT="$REPO_ROOT/src/Aspire.Cli/Aspire.Cli.csproj"
WORK_DIR="$(mktemp -d -t aspire-sdk-update-15904-XXXXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Build Aspire CLI from source ==="
cd "$REPO_ROOT"
"$DOTNET" build "$CLI_PROJECT" -c Debug --nologo -v minimal

create_apphost() {
  local dir="$1"
  local sdk_attr="$2"
  mkdir -p "$dir"
  cat > "$dir/AppHost.csproj" <<EOF
<Project Sdk="$sdk_attr">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
EOF
  cat > "$dir/Program.cs" <<'EOF'
var builder = Aspire.Hosting.DistributedApplication.CreateBuilder(args);
builder.Build().Run();
EOF
}

run_update() {
  local project="$1"
  local dir
  dir="$(dirname "$project")"
  (
    cd "$dir"
    "$DOTNET" run --project "$CLI_PROJECT" \
      -c Debug --no-build --no-launch-profile \
      -- --non-interactive update --apphost "$project" --channel stable --yes
  )
}

verify_versionless() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
project = pathlib.Path(sys.argv[1]).read_text()
config = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert '<Project Sdk="Aspire.AppHost.Sdk">' in project, project
pin = config["msbuild-sdks"]["Aspire.AppHost.Sdk"]
assert pin != "13.5.4", f"Stale global.json pin: {pin}"
assert pin.count(".") >= 2, f"Unexpected SDK version: {pin}"
print(f"PASS: project is versionless and global.json now selects {pin}")
PY
}

echo "=== E2E 1: versionless SDK from ancestor global.json ==="
mkdir -p "$WORK_DIR/ancestor"
create_apphost "$WORK_DIR/ancestor/host" "Aspire.AppHost.Sdk"
cat > "$WORK_DIR/ancestor/global.json" <<'EOF'
{
  "customSetting": "preserve",
  "msbuild-sdks": { "Aspire.AppHost.Sdk": "13.5.4" }
}
EOF
run_update "$WORK_DIR/ancestor/host/AppHost.csproj"
verify_versionless "$WORK_DIR/ancestor/host/AppHost.csproj" "$WORK_DIR/ancestor/global.json"
"$DOTNET" build "$WORK_DIR/ancestor/host/AppHost.csproj" --no-restore --nologo -v minimal

echo "=== E2E 2: second update is idempotent ==="
sha256sum "$WORK_DIR/ancestor/global.json" "$WORK_DIR/ancestor/host/AppHost.csproj" > "$WORK_DIR/before.sha"
run_update "$WORK_DIR/ancestor/host/AppHost.csproj"
sha256sum -c "$WORK_DIR/before.sha"

echo "=== E2E 3: explicit project SDK beats global.json ==="
create_apphost "$WORK_DIR/explicit" "Aspire.AppHost.Sdk/13.5.4"
cat > "$WORK_DIR/explicit/global.json" <<'EOF'
{ "msbuild-sdks": { "Aspire.AppHost.Sdk": "13.5.4" } }
EOF
run_update "$WORK_DIR/explicit/AppHost.csproj"
python3 - "$WORK_DIR/explicit/AppHost.csproj" "$WORK_DIR/explicit/global.json" <<'PY'
import json, pathlib, sys
project = pathlib.Path(sys.argv[1]).read_text()
config = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert "Aspire.AppHost.Sdk/13.5.4" not in project, project
assert "Aspire.AppHost.Sdk/" in project, project
assert config["msbuild-sdks"]["Aspire.AppHost.Sdk"] == "13.5.4"
print("PASS: explicit SDK updated and global.json unchanged")
PY
"$DOTNET" build "$WORK_DIR/explicit/AppHost.csproj" --no-restore --nologo -v minimal

echo "=== E2E 4: shared ancestor pin updates sibling AppHosts ==="
create_apphost "$WORK_DIR/shared/first" "Aspire.AppHost.Sdk"
create_apphost "$WORK_DIR/shared/second" "Aspire.AppHost.Sdk"
cat > "$WORK_DIR/shared/global.json" <<'EOF'
{ "msbuild-sdks": { "Aspire.AppHost.Sdk": "13.5.4" } }
EOF
run_update "$WORK_DIR/shared/first/AppHost.csproj"
verify_versionless "$WORK_DIR/shared/first/AppHost.csproj" "$WORK_DIR/shared/global.json"
verify_versionless "$WORK_DIR/shared/second/AppHost.csproj" "$WORK_DIR/shared/global.json"
"$DOTNET" restore "$WORK_DIR/shared/second/AppHost.csproj" --nologo -v minimal
"$DOTNET" build "$WORK_DIR/shared/second/AppHost.csproj" --no-restore --nologo -v minimal

echo "PASS: all E2E scenarios"
