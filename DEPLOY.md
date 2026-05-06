# SLZ Bicep Accelerator — Implementation & Publish Guide

End-to-end steps to take this repo from clone → Sovereign Landing Zone deployed in your tenant. Designed to be followed top-to-bottom.

---

## 0. Prerequisites

Install on your workstation:

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.60
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) ≥ 0.30
- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- [Git](https://git-scm.com/) and [GitHub CLI](https://cli.github.com/) (`gh`)
- An Azure tenant where you hold **Owner** at the **Tenant Root Group** (or you can elevate via `az role assignment create --scope "/" ...`)

Sign in:

```bash
az login --tenant <your-tenant-id>
az account set --subscription <management-subscription-id>
```

Elevate to manage MGs at root if needed:

```bash
az rest --method post \
  --url "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
```


```bash
az role assignment list --scope / --assignee <SERVICEPRINCIPAL OR USER OBJECTID>
```


```bash
az role assignment create --assignee <SERVICEPRINCIPAL OR USER OBJECTID> --role Owner --scope --verbose
```
---

## 1. Clone this repo

```bash
git clone https://github.com/nthewara/slz-bicep-accelerator.git
cd slz-bicep-accelerator
```

---

## 2. Pull the SLZ library content

The Bicep modules reference policy/role/archetype JSON via `loadJsonContent('../../lib/alz/...')`. You need to populate that directory from the [Azure Landing Zones Library](https://github.com/Azure/Azure-Landing-Zones-Library) at tag `platform/slz/2026.04.2`.

This is for Linux/Mac user bases. 
```bash
# from repo root
TMP=$(mktemp -d)
git clone --depth 1 --branch platform/slz/2026.04.2 \
  https://github.com/Azure/Azure-Landing-Zones-Library.git "$TMP"

# Copy SLZ library content into the bicep accelerator's lib path
mkdir -p templates/core/governance/lib/alz
cp -R "$TMP/platform/slz/"* templates/core/governance/lib/alz/

# Sanity check
ls templates/core/governance/lib/alz/
# expect: archetype_definitions/  policy_assignments/  policy_definitions/
#         policy_set_definitions/  role_definitions/  architecture_definitions/
```

This is for windows user bases. 
```powershell
# from repo root
$TMP = Join-Path $env:TEMP (New-Guid)
mkdir $TMP

git clone --depth 1 --branch platform/slz/2026.04.2 https://github.com/Azure/Azure-Landing-Zones-Library.git $TMP

# Copy SLZ library content into the bicep accelerator's lib path
mkdir -p templates/core/governance/lib/alz
Copy-Item -Path "$TMP/platform/slz/*" -Destination "templates/core/governance/lib/alz/" -Recurse

# Sanity check
ls templates/core/governance/lib/alz/
# expect: archetype_definitions/  policy_assignments/  policy_definitions/
#         policy_set_definitions/  role_definitions/  architecture_definitions/
```


### 2a. Reorganise into the directory layout the Bicep modules expect

The Bicep modules reference paths like `lib/alz/sovereign_l1/Enforce-Sov-L1-Regions.alz_policy_assignment.json` and `lib/alz/landingzones/public/Deny-L3-IP-Routing.alz_policy_assignment.json`. The SLZ library ships everything flat under `policy_assignments/`. Run this once to fan them out:

This is for Linux/Mac user bases.
```bash
cd templates/core/governance/lib/alz

# Sovereign L1
mkdir -p sovereign_l1 sovereign_l2 sovereign_l3 landingzones/public landingzones/confidential_corp landingzones/confidential_online

cp policy_assignments/Enforce-Sov-L1-Regions.alz_policy_assignment.json sovereign_l1/

cp policy_assignments/Enforce-Sov-L2-CMKM.alz_policy_assignment.json sovereign_l2/
cp policy_assignments/Enforce-Sov-L2-CMKP.alz_policy_assignment.json sovereign_l2/
cp policy_assignments/Enforce-Sov-L2-HTTPS.alz_policy_assignment.json sovereign_l2/
cp policy_assignments/Enforce-Sov-L2-TLS.alz_policy_assignment.json sovereign_l2/

cp policy_assignments/Enforce-Sov-L3-Conf.alz_policy_assignment.json sovereign_l3/

cp policy_assignments/Deny-L3-IP-Routing.alz_policy_assignment.json landingzones/public/

# Confidential corp/online inherit corp/online assignments + sovereign overlays
# (the Bicep modules already reference confidential_corp/* and confidential_online/* paths
#  for the corp baseline; copy them from corp + add overlays)
for f in Audit-PeDnsZones Deny-HybridNetworking Deny-Public-Endpoints Deny-Public-IP-On-NIC Deploy-Private-DNS-Zones; do
  cp "policy_assignments/${f}.alz_policy_assignment.json" landingzones/confidential_corp/   2>/dev/null || true
  cp "policy_assignments/${f}.alz_policy_assignment.json" landingzones/confidential_online/ 2>/dev/null || true
done

cd -
```
This is for windows user bases. 
```powershell
# Navigate to directory
cd "templates/core/governance/lib/alz"

# Sovereign directories
$dirs = @(
    "sovereign_l1",
    "sovereign_l2",
    "sovereign_l3",
    "landingzones/public",
    "landingzones/confidential_corp",
    "landingzones/confidential_online"
)

foreach ($dir in $dirs) {
    mkdir $dir -Force | Out-Null
}

# Copy individual files
Copy-Item "policy_assignments/Enforce-Sov-L1-Regions.alz_policy_assignment.json" "sovereign_l1/" -Force

Copy-Item "policy_assignments/Enforce-Sov-L2-CMKM.alz_policy_assignment.json" "sovereign_l2/" -Force
Copy-Item "policy_assignments/Enforce-Sov-L2-CMKP.alz_policy_assignment.json" "sovereign_l2/" -Force
Copy-Item "policy_assignments/Enforce-Sov-L2-HTTPS.alz_policy_assignment.json" "sovereign_l2/" -Force
Copy-Item "policy_assignments/Enforce-Sov-L2-TLS.alz_policy_assignment.json" "sovereign_l2/" -Force

Copy-Item "policy_assignments/Enforce-Sov-L3-Conf.alz_policy_assignment.json" "sovereign_l3/" -Force

Copy-Item "policy_assignments/Deny-L3-IP-Routing.alz_policy_assignment.json" "landingzones/public/" -Force
Copy-Item -Path "templates/core/governance/lib/alz/landingzones/corp/*" -Destination "templates/core/governance/lib/alz/landingzones/confidential_corp/" -Recurse

# Files to loop through
$files = @(
    "Audit-PeDnsZones",
    "Deny-HybridNetworking",
    "Deny-Public-Endpoints",
    "Deny-Public-IP-On-NIC",
    "Deploy-Private-DNS-Zones"
)

# Copy with "ignore errors" equivalent
foreach ($f in $files) {
    $src = "policy_assignments/$f.alz_policy_assignment.json"

    if (Test-Path $src) {
        Copy-Item $src "landingzones/confidential_corp/" -Force
        Copy-Item $src "landingzones/confidential_online/" -Force
    }
}
```

> If any of the corp baseline files don't exist in the SLZ library (SLZ may rename or omit a few), check `policy_assignments/` and adjust either the script above **or** the `loadJsonContent(...)` lines in `templates/core/governance/mgmt-groups/landingzones/landingzones-confidential-{corp,online}/main.bicep`.

### 2b. Run the upstream sync helper (optional)

Powershell 7.1 Required for this script to run properly. Please run below command if you using older powershell version. 

```powershell
winget install --id Microsoft.PowerShell -e
```

```bash
pwsh ./templates/core/governance/tooling/Update-AlzLibraryReferences.ps1 -WhatIf
```

This shows what it would update if you've changed paths. Drop `-WhatIf` once you're happy.

---

## 3. Customise tokens & overrides

Edit `.config/platform-landing-zone.yaml` and replace placeholders:

```yaml
starter_locations: ["australiaeast", "australiasoutheast"]

management_subscription_id:   "<sub-id>"
connectivity_subscription_id: "<sub-id>"
identity_subscription_id:     "<sub-id>"

# Already added for SLZ:
management_group_public_id:              "public"
management_group_confidential_corp_id:   "confidential_corp"
management_group_confidential_online_id: "confidential_online"
```

Then per MG, open each `templates/core/governance/mgmt-groups/**/main.bicepparam` and update `parPolicyAssignmentParameterOverrides`. Critical SLZ overrides:

| MG | Policy | What to set |
|---|---|---|
| `int-root` | `Enforce-Sov-L1-Regions` | `listOfAllowedLocations` to your sovereignty-approved regions |
| `corp`, `online`, `confidential_*` | `Enforce-Sov-L2-CMKM` / `CMKP` | Key Vault resource ID for CMK |
| `corp`, `confidential_corp` | `Deploy-Private-DNS-Zones` | Private DNS zone resource group resource IDs |
| `int-root` | `Deploy-MDFC-Config-H224` | LAW resource ID + security email |

Use the `examples/platform-landing-zone.yaml` token format `{{primary_location}}`, `{{connectivity_subscription_id}}` etc., or hardcode for a one-shot deploy.

---

## 4. Build & validate locally

```bash
# from repo root
bicep build templates/core/governance/mgmt-groups/int-root/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-public/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-corp/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-online/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-confidential-corp/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-confidential-online/main.bicep
bicep build templates/core/governance/mgmt-groups/landingzones/landingzones-local/main.bicep
```

Fix any unresolved `loadJsonContent` paths — those mean step 2a missed a file.

---

## 5. Deploy management groups (in order)

> Each module has `targetScope = 'managementGroup'`. Deploy at the **tenant root** for `int-root`, then at each MG scope thereafter.

NOTE: Before running the script update  
- \templates\core\governance\lib\alz\sovereign_l2\Enforce-Sov-L2-TLS.alz_policy_assignment.json
- templates\core\governance\lib\alz\sovereign_l2\Enforce-Sov-L2-HTTPS.alz_policy_assignment.json

And update the 

from:
```bicep
  "identity": {
    "type": "none"
  }, 
  ```
  To:
  ```bicep 
  "identity": {
    "type": "SystemAssigned"
  }
```

Also Update the \templates\core\governance\lib\alz\landingzones\public\Deny-L3-IP-Routing.alz_policy_assignment.json

```bicep 
"scope": "/providers/Microsoft.Management/managementGroups/placeholder",
"policyDefinitionId": "/providers/Microsoft.Management/managementGroups/placeholder/providers/Microsoft.Authorization/policySetDefinitions/Enforce-ALZ-Sandbox"
```

to 
```bicep
"scope": "/providers/Microsoft.Management/managementGroups/public",
"policyDefinitionId": "/providers/Microsoft.Management/managementGroups/alz/providers/Microsoft.Authorization/policySetDefinitions/Enforce-ALZ-Sandbox"
````

```bash
az login --tenant <TENTNID OR TENANTNAME>

LOC=australiaeast

# 5.1 Intermediate root
.\Deploy-IntRoot.ps1 `
-ManagementSubscriptionId    MANAGEMENTSUBSCRIPTIONID `
-ConnectivitySubscriptionId  CONNECTIVITYSUBSCRIPTIONID `
-IdentitySubscriptionId      IDENTITYSUBSCRIPTIONID `
-SecuritySubscriptionId     SECURITYSUBSCRIPTIONID -OnlyWaves 1

# 5.2 Landing Zones parent
.\Deploy-IntRoot.ps1 `
-ManagementSubscriptionId    MANAGEMENTSUBSCRIPTIONID `
-ConnectivitySubscriptionId  CONNECTIVITYSUBSCRIPTIONID `
-IdentitySubscriptionId      IDENTITYSUBSCRIPTIONID `
-SecuritySubscriptionId     SECURITYSUBSCRIPTIONID -OnlyWaves 2

.\Deploy-IntRoot.ps1 `
-ManagementSubscriptionId    MANAGEMENTSUBSCRIPTIONID `
-ConnectivitySubscriptionId  CONNECTIVITYSUBSCRIPTIONID `
-IdentitySubscriptionId      IDENTITYSUBSCRIPTIONID `
-SecuritySubscriptionId     SECURITYSUBSCRIPTIONID -OnlyWaves 3


.\Deploy-IntRoot.ps1 `
-ManagementSubscriptionId    MANAGEMENTSUBSCRIPTIONID `
-ConnectivitySubscriptionId  CONNECTIVITYSUBSCRIPTIONID `
-IdentitySubscriptionId      IDENTITYSUBSCRIPTIONID `
-SecuritySubscriptionId     SECURITYSUBSCRIPTIONID -OnlyWaves 4

# 5.3 Each child MG (run in parallel after 5.2 succeeds)
for child in public corp online confidential-corp confidential-online local; do
  az deployment mg create \
    --management-group-id landingzones \
    --location $LOC \
    --template-file templates/core/governance/mgmt-groups/landingzones/landingzones-${child}/main.bicep \
    --parameters templates/core/governance/mgmt-groups/landingzones/landingzones-${child}/main.bicepparam &
done
wait
```

Replace `<tenant-root-mg-id>` with your tenant-root management group ID (often the tenant ID itself).

> If any MG deployment fails on policy assignment role assignments with a 403, you didn't elevate at root in step 0 — re-run the elevate command and retry.

---

## 6. Deploy platform & networking (optional, follows the upstream accelerator)

These follow the same pattern — see `templates/core/logging/`, `templates/networking/hubnetworking/` (or `templates/networking/virtualwan/`), and `templates/core/governance/mgmt-groups/platform/platform-{management,connectivity,identity,security}/`.

For SLZ, network-wise you'd typically pick **hubNetworking** with private DNS zones in the connectivity subscription so `Deploy-Private-DNS-Zones` has somewhere to land its zones.

---

## 7. Verify

```bash
# MG hierarchy
az account management-group list --query "[].{name:name, displayName:displayName}" -o table

# Policy assignments per MG
for mg in alz landingzones public corp online confidential_corp confidential_online local; do
  echo "== $mg =="
  az policy assignment list --scope /providers/Microsoft.Management/managementGroups/$mg \
    --query "[].{name:name, def:policyDefinitionId}" -o tsv
done
```

Expected counts roughly:
- `alz` (int-root): 18 ALZ assignments + 1 SLZ L1
- `corp` / `online`: corp/online ALZ + 4 SLZ L2 each
- `confidential_corp` / `confidential_online`: corp baseline + 4 SLZ L2 + 1 SLZ L3
- `public`: 1 SLZ public

---

## 8. Publish your customisations back to GitHub

```bash
git checkout -b feat/<your-customisation>
git add -A
git commit -m "feat(slz): tune sovereign overrides for <region/customer>"
git push -u origin feat/<your-customisation>
gh pr create --fill
```

If you want to make the repo your team's go-to template:

```bash
gh repo edit nthewara/slz-bicep-accelerator --template
```

Then anyone can `gh repo create my-org/my-slz --template nthewara/slz-bicep-accelerator`.

---

## 9. Keeping in sync with upstream + library

When the SLZ library publishes a new release (e.g. `platform/slz/2026.05.x`):

1. Update `templates/core/governance/tooling/alz_library_metadata.json` `ref` field.
2. Re-run step 2 (clone library at the new tag, copy + reorganise).
3. Diff `policy_assignments/` for new/renamed/removed assignments — add/remove `loadJsonContent(...)` lines in the relevant `main.bicep`.
4. `bicep build ...` everything, redeploy.

When the upstream `Azure/alz-bicep-accelerator` ships changes:

```bash
git remote add upstream https://github.com/Azure/alz-bicep-accelerator.git
git fetch upstream
git checkout -b chore/upstream-sync
git merge upstream/main   # resolve any conflicts in MG files you've customised
```

---

## Reference

- SLZ library: <https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/slz>
- SLZ release `platform/slz/2026.04.2`: <https://github.com/Azure/Azure-Landing-Zones-Library/releases/tag/platform/slz/2026.04.2>
- ALZ Bicep how-tos:
  - <https://azure.github.io/Azure-Landing-Zones/bicep/howtos/modifyingmghierarchy/>
  - <https://azure.github.io/Azure-Landing-Zones/bicep/howtos/modifyingpolicyassets/>
- Upstream accelerator: <https://github.com/Azure/alz-bicep-accelerator>
