# SLZ Bootstrap Guide (Official Accelerator Path)

This is the **proper way** to render the Bicep accelerator templates — it uses the official [ALZ PowerShell Module](https://github.com/Azure/ALZ-PowerShell-Module) to substitute all the `{{token}}` placeholders into deployable `.bicepparam` files, the same way Microsoft's accelerator does it.

> Use this guide instead of hand-editing tokens. This is what the upstream docs assume you've run before any `az deployment mg create` command.

---

## What the bootstrap actually does

1. Reads your `inputs.yaml` (or interactive prompts) — your tenant ID, regions, subscription IDs, MG naming, etc.
2. Renders all `{{...}}` tokens in `.bicepparam` files into real values
3. Optionally provisions a CI/CD environment (GitHub Actions or Azure DevOps Pipelines) with state storage, UAMI, federated creds — skip this with the `alz_local` flavour
4. Outputs a deployable folder you commit to your repo and run `az deployment mg create` against

For SLZ on Bicep, we'll use the **`alz_local`** flavour — local rendering only, no CI/CD. You document the deploy yourself, then later you can layer GitHub Actions on top if you want.

---

## 1. Install the ALZ PowerShell module

```pwsh
# In a fresh pwsh session
Install-Module -Name ALZ -Scope CurrentUser -Force
Import-Module ALZ

# Verify
Get-Command -Module ALZ
# Look for: New-ALZEnvironment, Build-ALZDeploymentEnvFile, etc.
```

You also need:

```bash
# Terraform (used internally by the bootstrap, even for Bicep flavour)
brew install terraform
terraform -version   # ≥ 1.6

# Azure CLI signed in to the tenant where you'll deploy
az login --tenant <YOUR-TENANT-ID>
az account set --subscription <MGMT-SUB-ID>
```

---

## 2. Create your inputs file

This is the file the bootstrap uses to substitute `{{tokens}}`. Save as `~/slz-inputs.yaml`:

```yaml
# === Identity / scope ===
iac_type: "bicep"
bootstrap_module_name: "alz_local"          # local render only, no CI/CD wiring
starter_module_name: "platform_landing_zone" # which starter to render

# Where rendered output goes
output_folder_path: "./output"

# === SLZ-specific (Option 15) ===
# Tells the accelerator to layer SLZ controls on top of base ALZ
apply_alz_archetypes_via_architecture_definition: true
architecture_definition_name: "slz"          # SLZ architecture from the library

# === Library ref ===
library_ref: "platform/slz/2026.04.2"

# === Azure context ===
azure_location: "australiaeast"
starter_locations: ["australiaeast", "australiasoutheast"]
root_parent_management_group_id: "<YOUR-TENANT-ID>"   # tenant root MG = tenant ID

# === MG naming ===
management_group_id_prefix: ""
management_group_id_postfix: ""
management_group_name_prefix: ""
management_group_name_postfix: ""

management_group_int_root_id: "alz"
management_group_int_root_name: "Azure Landing Zones"
management_group_platform_id: "platform"
management_group_platform_name: "Platform"
management_group_connectivity_id: "connectivity"
management_group_connectivity_name: "Connectivity"
management_group_identity_id: "identity"
management_group_identity_name: "Identity"
management_group_security_id: "security"
management_group_security_name: "Security"
management_group_landing_zones_id: "landingzones"
management_group_landing_zones_name: "Landing Zones"
management_group_corp_id: "corp"
management_group_corp_name: "Corp"
management_group_online_id: "online"
management_group_online_name: "Online"
management_group_local_id: "local"
management_group_local_name: "Local"
management_group_decommissioned_id: "decommissioned"
management_group_decommissioned_name: "Decommissioned"
management_group_sandbox_id: "sandbox"
management_group_sandbox_name: "Sandbox"

# SLZ-only MGs
management_group_public_id: "public"
management_group_public_name: "Public"
management_group_confidential_corp_id: "confidential_corp"
management_group_confidential_corp_name: "Confidential Corp"
management_group_confidential_online_id: "confidential_online"
management_group_confidential_online_name: "Confidential Online"

# === Subscriptions ===
management_subscription_id:   "<MGMT-SUB-ID>"
connectivity_subscription_id: "<CONN-SUB-ID>"   # can equal management for testing
identity_subscription_id:     "<IDENT-SUB-ID>"  # can equal management for testing

# === Resource group naming ===
resource_group_logging_name_prefix: "rg-alz-logging"
resource_group_hub_networking_name_prefix: "rg-alz-conn"
resource_group_dns_name_prefix: "rg-alz-dns"
resource_group_private_dns_resolver_name_prefix: "rg-alz-dnspr"
resource_group_virtual_wan_name_prefix: "rg-alz-conn"

# === Networking ===
network_type: "hubNetworking"     # or "vwanConnectivity" or "none"

# === Email / contact ===
security_contact_email: "you@example.com"
```

> For a sandbox/testing tenant you can re-use the management subscription for connectivity and identity. In production, separate them.

---

## 3. Run the bootstrap

```pwsh
# Make sure you're authenticated
Connect-AzAccount -Tenant "<YOUR-TENANT-ID>"

# Render the templates
New-ALZEnvironment `
  -Output "./output" `
  -Inputs "~/slz-inputs.yaml" `
  -Iac "bicep" `
  -Bootstrap "alz_local" `
  -Verbose
```

If you skip `-Inputs`, the cmdlet prompts you interactively for each value — useful first time so you can see exactly what knobs exist.

What happens:
- Module clones the upstream Bicep accelerator + ALZ Library at the ref you specified
- Renders all `{{tokens}}` from your inputs into the staged copy
- Drops the result into `./output/`
- For `alz_local` it stops there (no Terraform, no CI/CD provisioning)

You should see a populated `./output/` tree mirroring the original repo layout but with all real values plugged in.

---

## 4. Layer in your custom MG hierarchy (Public, Confidential)

The official accelerator with `architecture_definition_name: "slz"` should already produce:
- `int-root` with `sovereign_l1_controls`
- `corp`, `online` with `sovereign_l2_controls`
- `confidential_corp`, `confidential_online` with `sovereign_l2 + sovereign_l3`
- `public` with the SLZ public archetype

If anything is missing (the upstream accelerator's SLZ support may lag library releases), copy the corresponding files from this repo on top of the rendered output:

```bash
# From this repo's root
cp -R templates/core/governance/mgmt-groups/landingzones/landingzones-public \
      ~/path/to/output/templates/core/governance/mgmt-groups/landingzones/

cp -R templates/core/governance/mgmt-groups/landingzones/landingzones-confidential-corp \
      ~/path/to/output/templates/core/governance/mgmt-groups/landingzones/

cp -R templates/core/governance/mgmt-groups/landingzones/landingzones-confidential-online \
      ~/path/to/output/templates/core/governance/mgmt-groups/landingzones/
```

Then re-run the bootstrap (`New-ALZEnvironment` is idempotent if you point at the same output folder, or use `Update-ALZEnvironment`).

---

## 5. Validate before deploy

```bash
cd ./output
find . -name "*.bicepparam" -exec grep -l "{{" {} \;
# expect: NO output. If anything prints, that file still has unresolved tokens
```

```bash
# Build each MG module to catch reference errors early
for mod in templates/core/governance/mgmt-groups/int-root \
           templates/core/governance/mgmt-groups/landingzones \
           templates/core/governance/mgmt-groups/landingzones/landingzones-* \
           templates/core/governance/mgmt-groups/platform \
           templates/core/governance/mgmt-groups/platform/platform-* \
           templates/core/governance/mgmt-groups/sandbox \
           templates/core/governance/mgmt-groups/decommissioned; do
  echo "== $mod =="
  bicep build "$mod/main.bicep" || break
done
```

---

## 6. Deploy (same as DEPLOY.md step 5)

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)

# 6.1 Intermediate root at tenant root MG
az deployment mg create \
  --management-group-id "$TENANT_ID" \
  --location australiaeast \
  --template-file output/templates/core/governance/mgmt-groups/int-root/main.bicep \
  --parameters output/templates/core/governance/mgmt-groups/int-root/main.bicepparam

# 6.2 Landing Zones parent
az deployment mg create \
  --management-group-id alz \
  --location australiaeast \
  --template-file output/templates/core/governance/mgmt-groups/landingzones/main.bicep \
  --parameters output/templates/core/governance/mgmt-groups/landingzones/main.bicepparam

# 6.3 Children
for child in public corp online confidential-corp confidential-online local; do
  az deployment mg create \
    --management-group-id landingzones \
    --location australiaeast \
    --template-file output/templates/core/governance/mgmt-groups/landingzones/landingzones-${child}/main.bicep \
    --parameters output/templates/core/governance/mgmt-groups/landingzones/landingzones-${child}/main.bicepparam &
done
wait

# 6.4 Platform sub-MGs (similar pattern under platform/)
```

---

## 7. Commit the rendered output back to your repo (optional)

If you want to keep the rendered, deployable artefacts in version control alongside the templated source:

```bash
cd ~/repos/cloudagent/slz-bicep-accelerator
mkdir -p rendered
cp -R ~/path/to/output/* rendered/
git checkout -b feat/rendered-slz
git add rendered/
git commit -m "feat: add bootstrap-rendered SLZ output for tenant <name>"
git push -u origin feat/rendered-slz
```

> Or keep `rendered/` gitignored and treat it as a build artefact — re-render whenever inputs change. That's the cleaner pattern long-term.

---

## Troubleshooting

**`Install-Module : The term 'Install-Module' is not recognized`**
You're not in PowerShell 7. Install with `brew install --cask powershell` and run `pwsh` first.

**`Connect-AzAccount` opens browser but never returns**
Use device code: `Connect-AzAccount -UseDeviceAuthentication`.

**`New-ALZEnvironment` fails on Terraform init**
Even though Bicep is your IaC, the bootstrap module uses Terraform internally to fetch the library. Make sure `terraform` is on PATH and version ≥ 1.6.

**Tokens still present after render**
Either the input value is missing in `slz-inputs.yaml` or the token uses a non-standard name. Run `New-ALZEnvironment` interactively (no `-Inputs`) to discover all required keys.

**`{{primary_location}}` specifically didn't render**
This token comes from `starter_locations[0]` not `azure_location`. Set both in `slz-inputs.yaml`.

**Architecture definition `slz` not found**
Check your library_ref points at a release that includes SLZ — `platform/slz/2026.04.2` is current. Older library versions don't have it.

---

## References

- [ALZ PowerShell Module](https://github.com/Azure/ALZ-PowerShell-Module)
- [IaC Accelerator docs](https://azure.github.io/Azure-Landing-Zones/accelerator/)
- [Phase 2 Bootstrap](https://azure.github.io/Azure-Landing-Zones/accelerator/userguide/2_bootstrap/)
- [Option 15 — SLZ controls](https://azure.github.io/Azure-Landing-Zones/accelerator/userguide/options/15-slz/)
- [Bring your own starter](https://azure.github.io/Azure-Landing-Zones/accelerator/userguide/advanced/bring_your_own_starter/) (for hosting your own customised accelerator)
