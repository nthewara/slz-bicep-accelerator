# SLZ Bicep Accelerator

A Bicep deployment scaffold for the **Azure Sovereign Landing Zone (SLZ)**, derived from the upstream [`Azure/alz-bicep-accelerator`](https://github.com/Azure/alz-bicep-accelerator) and re-pointed at the [SLZ ALZ Library](https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/slz) at release [`platform/slz/2026.04.2`](https://github.com/Azure/Azure-Landing-Zones-Library/releases/tag/platform/slz/2026.04.2).

> SLZ is officially supported on the Terraform accelerator. This repo demonstrates an equivalent Bicep path by adapting the ALZ Bicep accelerator to the SLZ archetype + management-group hierarchy.

## What this repo changes vs. upstream

| Area | Upstream (ALZ) | This repo (SLZ) |
|---|---|---|
| Library reference | `platform/alz` ref `2026.04.2` | `platform/slz` ref `2026.04.2` |
| Management groups | `int-root → platform, landingzones (corp/online/local), sandbox, decommissioned` | adds `public`, `confidential_corp`, `confidential_online` under `landingzones` |
| Archetype on `int-root` | ALZ baseline | + `sovereign_l1_controls` (region restriction) |
| Archetype on `corp` / `online` | corp/online ALZ | + `sovereign_l2_controls` (TLS/HTTPS/CMK) |
| Archetype on `confidential_corp` / `confidential_online` | _(new)_ | corp/online + `sovereign_l2_controls` + `sovereign_l3_controls` |
| Archetype on `public` | _(new)_ | SLZ `public` (`Deny-L3-IP-Routing`) |

The hierarchy mirrors the official SLZ architecture definition: <https://github.com/Azure/Azure-Landing-Zones-Library/blob/main/platform/slz/architecture_definitions/slz.alz_architecture_definition.json>.

## Repo layout (delta)

```
templates/core/governance/
├── lib/alz/                          # populated by Update-AlzLibraryReferences.ps1 from SLZ library
│   ├── sovereign_l1/                 # SLZ sovereign_l1_controls policy assignments
│   ├── sovereign_l2/                 # SLZ sovereign_l2_controls policy assignments
│   ├── sovereign_l3/                 # SLZ sovereign_l3_controls policy assignments
│   └── landingzones/
│       ├── public/                   # SLZ public archetype assignments
│       ├── confidential_corp/
│       └── confidential_online/
├── mgmt-groups/landingzones/
│   ├── landingzones-public/          # NEW - hosts SLZ public archetype
│   ├── landingzones-confidential-corp/   # NEW
│   └── landingzones-confidential-online/ # NEW
└── tooling/alz_library_metadata.json # path: platform/slz, ref: 2026.04.2
```

## Deploy flow

Follow the upstream accelerator docs (<https://aka.ms/alz/acc>) with these adjustments:

1. **Bootstrap** as normal — pick this repo as the IaC source. Use the Sovereign Landing Zone starter when prompted, or feed the values from `examples/platform-landing-zone.yaml` (already extended with `management_group_public_id`, `management_group_confidential_corp_id`, `management_group_confidential_online_id`).
2. **Pull SLZ library content** before first deploy:
   ```pwsh
   pwsh ./templates/core/governance/tooling/Update-AlzLibraryReferences.ps1
   ```
   This expects the SLZ library checked out at `templates/core/governance/lib/alz/` (clone <https://github.com/Azure/Azure-Landing-Zones-Library> at tag `platform/slz/2026.04.2` and copy `platform/slz/*` into that path, or extend the script as documented in <https://azure.github.io/Azure-Landing-Zones/bicep/howtos/modifyingpolicyassets/>).
3. **Deploy management groups** in the order: `int-root → landingzones → landingzones-public, landingzones-corp, landingzones-online, landingzones-confidential-corp, landingzones-confidential-online, landingzones-local`.
4. **Policy assignment overrides** — review `parPolicyAssignmentParameterOverrides` in each `main.bicepparam`. SLZ-specific overrides to validate:
   - `Enforce-Sov-L1-Regions` allowed-regions list (per sovereignty requirement)
   - `Enforce-Sov-L2-CMKM/CMKP` Key Vault scope
   - `Deploy-Private-DNS-Zones` (corp + confidential_corp + confidential_online)

## Customisation guides

- Adding more management groups: <https://azure.github.io/Azure-Landing-Zones/bicep/howtos/modifyingmghierarchy/#adding-new-management-groups>
- Modifying policy assets: <https://azure.github.io/Azure-Landing-Zones/bicep/howtos/modifyingpolicyassets/>

## Status

✅ Repo scaffolded
✅ MG hierarchy matches SLZ architecture definition
✅ Sovereign archetypes wired to int-root / corp / online / confidential_* / public
⚠️ `lib/alz/sovereign_l*` and `lib/alz/landingzones/{public,confidential_corp,confidential_online}` directories exist but JSON content is pulled via `Update-AlzLibraryReferences.ps1` against the SLZ library — run that step before `bicep build` / deploy
⚠️ Bootstrap starter override (templates/configuration) still TODO — the existing accelerator bootstrap targets ALZ; you'll need to either run bootstrap pointing at this repo or hand-craft `parPolicyAssignmentParameterOverrides` for the new MGs

## Upstream

Synced from `Azure/alz-bicep-accelerator` @ `7dbb8c3`. Re-sync by cherry-picking upstream commits, then re-running `Update-AlzLibraryReferences.ps1` against the desired SLZ library tag.

## License

MIT — see [LICENSE](LICENSE).
