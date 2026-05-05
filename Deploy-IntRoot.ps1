<#
.SYNOPSIS
    Deploys ALL ALZ management groups and policies by reading configuration from
    .config/platform-landing-zone.yaml and running management-group-scoped deployments.

.DESCRIPTION
    1. Reads and parses .config/platform-landing-zone.yaml for all MG names, IDs,
       locations, and resource-group prefixes.
    2. Merges with subscription IDs supplied on the command line.
    3. Resolves every {{placeholder}} and {{placeholder||default}} token in each
       main.bicepparam file (originals are never modified – temp files are used).
    4. Deploys all 15 management groups in four dependency-ordered waves:
         Wave 1 – int-root               (parent: tenant root)
         Wave 2 – platform, landingzones, sandbox, decommissioned  (parent: int-root)
         Wave 3 – platform children      (connectivity, identity, security, management)
         Wave 4 – landingzones children  (corp, online, confidential-corp,
                                          confidential-online, local, public)

.PARAMETER YamlConfigPath
    Path to platform-landing-zone.yaml. Defaults to '<repo-root>/.config/platform-landing-zone.yaml'.

.PARAMETER ManagementSubscriptionId
    Subscription ID placed in the Management MG and used for logging workspace refs. Required.

.PARAMETER ConnectivitySubscriptionId
    Subscription ID placed in the Connectivity MG. Required.

.PARAMETER IdentitySubscriptionId
    Subscription ID placed in the Identity MG. Required.

.PARAMETER SecuritySubscriptionId
    Subscription ID placed in the Security MG. Required.

.PARAMETER RootParentManagementGroupId
    ID of the parent management group for int-root (usually the tenant root).
    Auto-detected from 'az account show' when omitted.

.PARAMETER OnlyWaves
    Comma-separated list of wave numbers to deploy (1,2,3,4). Deploys all waves when omitted.
    Example: -OnlyWaves 1,2

.PARAMETER WhatIf
    Runs 'az deployment mg what-if' for every deployment instead of creating them.

.PARAMETER ContinueOnError
    Continue deploying subsequent waves even if one deployment fails.

.EXAMPLE
    # Full deployment – minimal parameters (locations come from the YAML)
    .\Deploy-IntRoot.ps1 `
        -ManagementSubscriptionId    aaaaaaaa-0000-0000-0000-000000000000 `
        -ConnectivitySubscriptionId  bbbbbbbb-0000-0000-0000-000000000000 `
        -IdentitySubscriptionId      cccccccc-0000-0000-0000-000000000000 `
        -SecuritySubscriptionId      dddddddd-0000-0000-0000-000000000000

.EXAMPLE
    # Preview wave 1 only
    .\Deploy-IntRoot.ps1 `
        -ManagementSubscriptionId    aaaaaaaa-0000-0000-0000-000000000000 `
        -ConnectivitySubscriptionId  bbbbbbbb-0000-0000-0000-000000000000 `
        -IdentitySubscriptionId      cccccccc-0000-0000-0000-000000000000 `
        -SecuritySubscriptionId      dddddddd-0000-0000-0000-000000000000 `
        -OnlyWaves 1 `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $YamlConfigPath,

    [Parameter(Mandatory)]
    [string] $ManagementSubscriptionId,

    [Parameter(Mandatory)]
    [string] $ConnectivitySubscriptionId,

    [Parameter(Mandatory)]
    [string] $IdentitySubscriptionId,

    [Parameter(Mandatory)]
    [string] $SecuritySubscriptionId,

    [string] $RootParentManagementGroupId,

    [int[]]  $OnlyWaves,

    [switch] $ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$tempFiles = [System.Collections.Generic.List[string]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# Helper: simple YAML scalar parser (handles quoted and unquoted values)
# ─────────────────────────────────────────────────────────────────────────────
function Read-YamlScalars {
    param([string] $FilePath)
    $result = @{}
    foreach ($line in (Get-Content -Path $FilePath)) {
        # Skip comments and blank lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        # key: ["val1", "val2"]  → capture as raw array string
        if ($line -match '^\s*(\w+)\s*:\s*(\[.+\])\s*$') {
            $result[$Matches[1]] = $Matches[2]
            continue
        }
        # key: "value"  or  key: value
        if ($line -match '^\s*(\w+)\s*:\s*"?([^"#]*)"?\s*$') {
            $result[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
    return $result
}

function Parse-YamlArray {
    param([string] $Raw)
    # Expects:  ["val1","val2"]  or  [ "val1", "val2" ]
    $inner = $Raw.Trim().TrimStart('[').TrimEnd(']')
    return ($inner -split ',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Load YAML config
# ─────────────────────────────────────────────────────────────────────────────
if (-not $YamlConfigPath) {
    $YamlConfigPath = Join-Path $repoRoot '.config\platform-landing-zone.yaml'
}
if (-not (Test-Path $YamlConfigPath)) {
    throw "YAML config not found: $YamlConfigPath"
}

Write-Host "`nLoading config: $YamlConfigPath" -ForegroundColor Cyan
$yaml = Read-YamlScalars -FilePath $YamlConfigPath

# Parse locations array
$locations = Parse-YamlArray -Raw ($yaml['starter_locations'] ?? '["eastus"]')
$primaryLocation   = $locations[0]
$secondaryLocation = if ($locations.Count -gt 1) { $locations[1] } else { $locations[0] }

# ─────────────────────────────────────────────────────────────────────────────
# 2. Auto-detect tenant root if not supplied
# ─────────────────────────────────────────────────────────────────────────────
if (-not $RootParentManagementGroupId) {
    Write-Host "Auto-detecting tenant root from 'az account show'..." -ForegroundColor Cyan
    $tenantId = (az account show --query tenantId -o tsv 2>$null)
    if (-not $tenantId) {
        throw "Cannot detect tenant ID – run 'az login' first or supply -RootParentManagementGroupId."
    }
    $RootParentManagementGroupId = $tenantId.Trim()
    Write-Host "  Tenant root: $RootParentManagementGroupId" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Build token replacement map
#    All {{token}} and {{token||default}} occurrences in .bicepparam files are covered.
# ─────────────────────────────────────────────────────────────────────────────
function yaml {
    param([string]$Key, [string]$Default = '')
    if ($yaml.ContainsKey($Key) -and $yaml[$Key] -ne '') { return $yaml[$Key] }
    return $Default
}

$pre  = yaml 'management_group_id_prefix'
$post = yaml 'management_group_id_postfix'

$tokens = [ordered]@{
    # Locations
    'primary_location'                             = $primaryLocation
    'secondary_location'                           = $secondaryLocation

    # MG ID fragments
    'management_group_id_prefix'                   = $pre
    'management_group_id_postfix'                  = $post
    'management_group_int_root_id'                 = yaml 'management_group_int_root_id'         'alz'
    'management_group_platform_id'                 = yaml 'management_group_platform_id'          'platform'
    'management_group_connectivity_id'             = yaml 'management_group_connectivity_id'       'connectivity'
    'management_group_identity_id'                 = yaml 'management_group_identity_id'           'identity'
    'management_group_security_id'                 = yaml 'management_group_security_id'           'security'
    'management_group_management_id'               = yaml 'management_group_management_id'         'management'
    'management_group_landing_zones_id'            = yaml 'management_group_landing_zones_id'      'landingzones'
    'management_group_corp_id'                     = yaml 'management_group_corp_id'               'corp'
    'management_group_online_id'                   = yaml 'management_group_online_id'             'online'
    'management_group_local_id'                    = yaml 'management_group_local_id'              'local'
    'management_group_public_id'                   = yaml 'management_group_public_id'             'public'
    'management_group_confidential_corp_id'        = yaml 'management_group_confidential_corp_id'  'confidential_corp'
    'management_group_confidential_online_id'      = yaml 'management_group_confidential_online_id' 'confidential_online'
    'management_group_decommissioned_id'           = yaml 'management_group_decommissioned_id'     'decommissioned'
    'management_group_sandbox_id'                  = yaml 'management_group_sandbox_id'            'sandbox'

    # MG display-name fragments
    'management_group_name_prefix'                 = yaml 'management_group_name_prefix'
    'management_group_name_postfix'                = yaml 'management_group_name_postfix'
    'management_group_int_root_name'               = yaml 'management_group_int_root_name'          'Azure Landing Zones'
    'management_group_platform_name'               = yaml 'management_group_platform_name'           'Platform'
    'management_group_connectivity_name'           = yaml 'management_group_connectivity_name'       'Connectivity'
    'management_group_identity_name'               = yaml 'management_group_identity_name'           'Identity'
    'management_group_security_name'               = yaml 'management_group_security_name'           'Security'
    'management_group_management_name'             = yaml 'management_group_management_name'         'Management'
    'management_group_landing_zones_name'          = yaml 'management_group_landing_zones_name'      'Landing Zones'
    'management_group_corp_name'                   = yaml 'management_group_corp_name'               'Corp'
    'management_group_online_name'                 = yaml 'management_group_online_name'             'Online'
    'management_group_local_name'                  = yaml 'management_group_local_name'              'Local'
    'management_group_public_name'                 = yaml 'management_group_public_name'             'Public'
    'management_group_confidential_corp_name'      = yaml 'management_group_confidential_corp_name'  'Confidential Corp'
    'management_group_confidential_online_name'    = yaml 'management_group_confidential_online_name' 'Confidential Online'
    'management_group_decommissioned_name'         = yaml 'management_group_decommissioned_name'     'Decommissioned'
    'management_group_sandbox_name'                = yaml 'management_group_sandbox_name'            'Sandbox'

    # Subscription IDs (from CLI params, not YAML)
    'management_subscription_id'                   = $ManagementSubscriptionId
    'connectivity_subscription_id'                 = $ConnectivitySubscriptionId
    'identity_subscription_id'                     = $IdentitySubscriptionId
    'security_subscription_id'                     = $SecuritySubscriptionId

    # Misc
    'root_parent_management_group_id'              = $RootParentManagementGroupId
    'resource_group_logging_name_prefix'           = yaml 'resource_group_logging_name_prefix'        'rg-alz-logging'
    'resource_group_hub_networking_name_prefix'    = yaml 'resource_group_hub_networking_name_prefix'  'rg-alz-conn'
    'resource_group_virtual_wan_name_prefix'       = yaml 'resource_group_virtual_wan_name_prefix'     'rg-alz-conn'
    'resource_group_dns_name_prefix'               = yaml 'resource_group_dns_name_prefix'             'rg-alz-dns'
    'resource_group_private_dns_resolver_name_prefix' = yaml 'resource_group_private_dns_resolver_name_prefix' 'rg-alz-dnspr'
}

# Compute composite MG IDs used as deployment targets
$mgIntRootId    = "$pre$($tokens['management_group_int_root_id'])$post"
$mgPlatformId   = "$pre$($tokens['management_group_platform_id'])$post"
$mgLandingZones = "$pre$($tokens['management_group_landing_zones_id'])$post"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Deployment manifest
#    Each entry: Name, RelPath (bicep+param folder), TargetMgId, Wave
# ─────────────────────────────────────────────────────────────────────────────
$mgRoot = 'templates\core\governance\mgmt-groups'

$deployments = @(
    # Wave 1 – int-root (targets tenant root / supplied parent)
    [PSCustomObject]@{ Wave=1; Name='int-root';                 RelPath="$mgRoot\int-root";                                      TargetMgId=$RootParentManagementGroupId }

    # Wave 2 – direct children of int-root
    [PSCustomObject]@{ Wave=2; Name='platform';                 RelPath="$mgRoot\platform";                                      TargetMgId=$mgIntRootId }
    [PSCustomObject]@{ Wave=2; Name='landingzones';             RelPath="$mgRoot\landingzones";                                  TargetMgId=$mgIntRootId }
    [PSCustomObject]@{ Wave=2; Name='sandbox';                  RelPath="$mgRoot\sandbox";                                       TargetMgId=$mgIntRootId }
    [PSCustomObject]@{ Wave=2; Name='decommissioned';           RelPath="$mgRoot\decommissioned";                                TargetMgId=$mgIntRootId }

    # Wave 3 – children of platform
    [PSCustomObject]@{ Wave=3; Name='platform-connectivity';    RelPath="$mgRoot\platform\platform-connectivity";               TargetMgId=$mgPlatformId }
    [PSCustomObject]@{ Wave=3; Name='platform-identity';        RelPath="$mgRoot\platform\platform-identity";                   TargetMgId=$mgPlatformId }
    [PSCustomObject]@{ Wave=3; Name='platform-security';        RelPath="$mgRoot\platform\platform-security";                   TargetMgId=$mgPlatformId }
    [PSCustomObject]@{ Wave=3; Name='platform-management';      RelPath="$mgRoot\platform\platform-management";                 TargetMgId=$mgPlatformId }

    # Wave 4 – children of landingzones
    # [PSCustomObject]@{ Wave=4; Name='landingzones-corp';               RelPath="$mgRoot\landingzones\landingzones-corp";               TargetMgId=$mgLandingZones }
    # [PSCustomObject]@{ Wave=4; Name='landingzones-online';             RelPath="$mgRoot\landingzones\landingzones-online";             TargetMgId=$mgLandingZones }
    [PSCustomObject]@{ Wave=4; Name='landingzones-confidential-corp';  RelPath="$mgRoot\landingzones\landingzones-confidential-corp";  TargetMgId=$mgLandingZones }
    [PSCustomObject]@{ Wave=4; Name='landingzones-confidential-online';RelPath="$mgRoot\landingzones\landingzones-confidential-online";TargetMgId=$mgLandingZones }
    [PSCustomObject]@{ Wave=4; Name='landingzones-local';              RelPath="$mgRoot\landingzones\landingzones-local";              TargetMgId=$mgLandingZones }
    [PSCustomObject]@{ Wave=4; Name='landingzones-public';             RelPath="$mgRoot\landingzones\landingzones-public";             TargetMgId=$mgLandingZones }
)

# Filter to requested waves
if ($OnlyWaves) {
    $deployments = $deployments | Where-Object { $_.Wave -in $OnlyWaves }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Placeholder substitution helper
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-BicepParam {
    param([string] $ParamFilePath)

    $content = Get-Content -Raw -Path $ParamFilePath

    foreach ($key in $tokens.Keys) {
        $value = $tokens[$key]
        # Replace {{key||default}} first (more specific), then {{key}}
        $content = [regex]::Replace($content, "\{\{$([regex]::Escape($key))\|\|[^}]*\}\}", $value)
        $content = $content -replace [regex]::Escape("{{$key}}"), $value
    }

    $remaining = [regex]::Matches($content, '\{\{[^}]+\}\}')
    if ($remaining.Count -gt 0) {
        $unique = ($remaining | Select-Object -ExpandProperty Value | Sort-Object -Unique) -join ', '
        Write-Warning "  Unreplaced placeholders in $([IO.Path]::GetFileName($ParamFilePath)): $unique"
    }

    # Keep the resolved file next to the source parameter file so
    # relative paths like "using './main.bicep'" stay valid.
    $paramDir = Split-Path -Parent $ParamFilePath
    $tmpPath = Join-Path $paramDir ".resolved-$([IO.Path]::GetRandomFileName()).bicepparam"
    Set-Content -Path $tmpPath -Value $content -Encoding UTF8
    $tempFiles.Add($tmpPath)
    return $tmpPath
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Print deployment plan
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host   "║           ALZ Deployment Plan                            ║" -ForegroundColor Yellow
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host "  YAML config           : $YamlConfigPath"
Write-Host "  Primary location      : $primaryLocation"
Write-Host "  Secondary location    : $secondaryLocation"
Write-Host "  Tenant / root MG      : $RootParentManagementGroupId"
Write-Host "  Int-root MG ID        : $mgIntRootId"
Write-Host "  Platform MG ID        : $mgPlatformId"
Write-Host "  Landing Zones MG ID   : $mgLandingZones"
Write-Host "  Management sub        : $ManagementSubscriptionId"
Write-Host "  Connectivity sub      : $ConnectivitySubscriptionId"
Write-Host "  Identity sub          : $IdentitySubscriptionId"
Write-Host "  Security sub          : $SecuritySubscriptionId"
Write-Host "  Mode                  : $(if ($WhatIfPreference) { 'WHAT-IF' } else { 'DEPLOY' })"
Write-Host ""
$wavesShown = $deployments | Select-Object -ExpandProperty Wave | Sort-Object -Unique
foreach ($w in $wavesShown) {
    Write-Host "  Wave $w :" -ForegroundColor Cyan
    $deployments | Where-Object Wave -eq $w | ForEach-Object {
        Write-Host "    [$($_.Name)]  →  MG: $($_.TargetMgId)"
    }
}
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 7. Deploy each wave sequentially, deployments within a wave sequentially
# ─────────────────────────────────────────────────────────────────────────────
$errors = [System.Collections.Generic.List[string]]::new()

try {
    $waves = $deployments | Select-Object -ExpandProperty Wave | Sort-Object -Unique

    foreach ($wave in $waves) {
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
        Write-Host "  WAVE $wave" -ForegroundColor DarkCyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan

        foreach ($d in ($deployments | Where-Object Wave -eq $wave)) {

            $bicepFile = Join-Path $repoRoot "$($d.RelPath)\main.bicep"
            $paramFile = Join-Path $repoRoot "$($d.RelPath)\main.bicepparam"

            if (-not (Test-Path $bicepFile)) {
                $msg = "[$($d.Name)] Bicep file not found: $bicepFile – SKIPPING"
                Write-Warning $msg
                $errors.Add($msg)
                continue
            }
            if (-not (Test-Path $paramFile)) {
                $msg = "[$($d.Name)] Param file not found: $paramFile – SKIPPING"
                Write-Warning $msg
                $errors.Add($msg)
                continue
            }

            $deploymentName = "slz-$($d.Name)-$timestamp"
            $resolvedParam  = Resolve-BicepParam -ParamFilePath $paramFile

            Write-Host "`n  ► [$($d.Name)]" -ForegroundColor Green
            Write-Host "    Target MG  : $($d.TargetMgId)"
            Write-Host "    Deployment : $deploymentName"

            if ($WhatIfPreference) {
                az deployment mg what-if `
                    --management-group-id $d.TargetMgId `
                    --name                $deploymentName `
                    --location            $primaryLocation `
                    --template-file       $bicepFile `
                    --parameters          $resolvedParam
            }
            else {
                az deployment mg create `
                    --management-group-id $d.TargetMgId `
                    --name                $deploymentName `
                    --location            $primaryLocation `
                    --template-file       $bicepFile `
                    --parameters          $resolvedParam `
                    --output              json
            }

            if ($LASTEXITCODE -ne 0) {
                $msg = "[$($d.Name)] az deployment exited with code $LASTEXITCODE"
                if ($ContinueOnError) {
                    Write-Warning $msg
                    $errors.Add($msg)
                }
                else {
                    throw $msg
                }
            }
            else {
                Write-Host "    ✓ Succeeded" -ForegroundColor Green
            }
        }
        
        # Allow policy definitions to propagate through the MG hierarchy before next wave
        if ($wave -ne ($waves | Select-Object -Last 1)) {
            Write-Host "`n  ⏳ Waiting 120 seconds for policy definitions to replicate..." -ForegroundColor Yellow
            Start-Sleep -Seconds 120
        }
    }
}
finally {
    # Always clean up temp param files
    foreach ($f in $tempFiles) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    Write-Verbose "Cleaned up $($tempFiles.Count) temp file(s)."
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
if ($errors.Count -eq 0) {
    Write-Host "  All deployments completed successfully." -ForegroundColor Green
}
else {
    Write-Host "  Completed with $($errors.Count) error(s):" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "    • $_" -ForegroundColor Red }
    exit 1
}
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Yellow
